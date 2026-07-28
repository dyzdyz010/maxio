defmodule Maxio.Storage.DistributedMutationTest do
  # 共用 InProcess 全局 ETS（:maxio_inproc_down）必须串行；无 DataCase/Repo：MutationContext
  # 直接以 struct 构造（不经 journal），对应实现计划 B4 的 Distributed 后端验收断言。
  # 1 pool / 1 set / N=6 端点（3 node 各 2 drive，同机模拟）→ write_quorum=4、
  # epoch_quorum=max(4, ⌊6/2⌋+1)=4：容忍 2 端点故障，3 端点故障必须拒绝；
  # set_down(:maxio@n0) 恰好击落 2 个 endpoint（e0/e3）。
  use ExUnit.Case, async: false

  alias Maxio.Cluster.{Paths, ShardServer, Topology, Transport.InProcess}
  alias Maxio.Storage.{Distributed, EpochStore, MutationBackup, MutationContext, ObjectEpoch}
  alias Maxio.Storage.ObjectCommit.Control

  @bucket "dist-mutation-test"
  @id_a "00000000-0000-0000-0000-00000000000a"
  @id_b "00000000-0000-0000-0000-00000000000b"

  setup do
    InProcess.setup!()
    base = Path.join(System.tmp_dir!(), "maxio_dist_mut_#{System.unique_integer([:positive])}")

    endpoints =
      for i <- 0..5 do
        {:"maxio@n#{rem(i, 3)}", Path.join(base, "n#{rem(i, 3)}_d#{div(i, 3)}")}
      end

    topology =
      Topology.parse_and_validate!(
        data_shards: 4,
        parity_shards: 2,
        block_size: 1024,
        allow_colocated_endpoints: true,
        pools: [%{id: 0, sets: [%{id: 0, endpoints: endpoints}]}]
      )

    on_exit(fn -> File.rm_rf(base) end)
    {:ok, topology: topology, endpoints: endpoints}
  end

  defp opts(ctx), do: [topology: ctx.topology, transport: InProcess]

  defp target(key, version_id \\ "null") do
    {:ok, target} = ObjectEpoch.object_target(@bucket, key, version_id)
    target
  end

  defp token(gen, id) do
    {:ok, token} = ObjectEpoch.token(gen, id)
    token
  end

  defp placement_snapshot(ctx) do
    %{
      "set_id" => 0,
      "pool_id" => 0,
      "topology_hash" => Topology.fingerprint(ctx.topology)
    }
  end

  defp build_ctx(ctx, key, gen, id, previous, version_id) do
    {:ok, final_rel} = Paths.object_rel(@bucket, key, version_id)

    %MutationContext{
      mutation_id: id,
      target: target(key, version_id),
      token: token(gen, id),
      operation: "put",
      authority_mode: "pg",
      backend: "distributed",
      final_rel: final_rel,
      bucket: @bucket,
      key: key,
      version_id: version_id,
      placement_snapshot: placement_snapshot(ctx),
      previous_epoch: previous
    }
  end

  defp epoch_payload(nil), do: nil

  defp epoch_payload(%ObjectEpoch{} = epoch) do
    {:ok, payload} = EpochStore.payload(epoch)
    payload
  end

  defp final_dir({_node, drive}, key, version_id \\ "null") do
    {:ok, rel} = Paths.object_rel(@bucket, key, version_id)
    Path.join(drive, rel)
  end

  defp backup_dir({_node, drive}, id), do: Path.join(drive, MutationBackup.relative_dir(id))

  defp epoch_path({_node, drive}, target) do
    {:ok, rel} = ObjectEpoch.relative_path(target)
    Path.join(drive, rel)
  end

  defp body(ctx, key, version_id \\ "null") do
    {:ok, stream} = Distributed.get(@bucket, key, version_id, nil, opts(ctx))
    stream |> Enum.to_list() |> IO.iodata_to_binary()
  end

  defp temp_empty?({_node, drive}) do
    case File.ls(Path.join(drive, ".tmp")) do
      {:ok, []} -> true
      {:error, :enoent} -> true
      _ -> false
    end
  end

  defp snapshot_finals(endpoints, key, version_id \\ "null") do
    Enum.map(endpoints, fn endpoint ->
      final = final_dir(endpoint, key, version_id)

      {endpoint, File.read!(Path.join(final, "part.0")),
       File.read!(Path.join(final, "meta.json"))}
    end)
  end

  defp assert_finals(snapshot, key, version_id \\ "null") do
    Enum.each(snapshot, fn {endpoint, part, meta} ->
      final = final_dir(endpoint, key, version_id)
      assert File.read!(Path.join(final, "part.0")) == part
      assert File.read!(Path.join(final, "meta.json")) == meta
    end)
  end

  # 该端点 target 的 durable epoch（per-endpoint 视角，绕过 quorum 裁决取证用；drive 是
  # 本机路径，直调 ShardServer 与 InProcess 存活状态无关）。
  defp endpoint_epoch({_node, drive}, target) do
    case ShardServer.read_epoch(drive, target) do
      {:ok, :absent} ->
        :absent

      {:ok, payload} ->
        {:ok, epoch} = payload |> Jason.encode!() |> ObjectEpoch.decode()
        epoch
    end
  end

  # 直接在指定端点 claim 一个 token（注入 successor 的 per-endpoint 手段；直调 ShardServer，
  # 不经 InProcess——op 级失联注入不影响它）。
  defp claim_on_endpoints!(endpoints, target, token) do
    {:ok, claimed} =
      ObjectEpoch.new(target, token, %{
        operation: "put",
        phase: "claimed",
        value_type: "object",
        updated_at: DateTime.utc_now()
      })

    {:ok, payload} = EpochStore.payload(claimed)

    Enum.each(endpoints, fn {_node, drive} ->
      assert {:ok, :applied} =
               ShardServer.cas_epoch(drive, %{next: payload, expect: {:claim, token}})
    end)
  end

  # 协议化 put 驱动（B5 orchestrator 的 B4 级替身；journal 不在本批范围）：
  # around_object_commit 内 claim（断言 placement_snapshot 交给调用者）→（可选 after_claim
  # 注入）→ publish.(object_mutation: ctx)，publish 结果交给 on_published（其返回值即
  # around 返回值，驱动 ObjectCommit 收口）。
  defp drive_mutation_put(ctx, key, chunks, gen, id, on_published, extra \\ []) do
    o = opts(ctx)
    version_id = Keyword.get(extra, :version_id, "null")
    after_claim = Keyword.get(extra, :after_claim, fn _mctx -> :ok end)

    {:ok, current} = Distributed.current_epoch(target(key, version_id), o)
    previous = epoch_payload(epoch_or_nil(current))
    mctx = build_ctx(ctx, key, gen, id, previous, version_id)

    around = fn _prepared, publish ->
      assert {:ok,
              %{previous: claim_previous, endpoints_ok: endpoints_ok, placement_snapshot: snap}} =
               Distributed.claim_epoch(mctx.target, mctx.token, "put", o)

      assert endpoints_ok >= 4
      assert epoch_payload(claim_previous) == previous
      assert snap == mctx.placement_snapshot

      after_claim.(mctx)
      result = publish.(version_id: version_id, object_meta: %{}, object_mutation: mctx)
      on_published.(mctx, result)
    end

    put_result =
      Distributed.put(
        @bucket,
        key,
        version_id,
        chunks,
        Keyword.put(o, :around_object_commit, around)
      )

    {mctx, put_result}
  end

  defp epoch_or_nil(:absent), do: nil
  defp epoch_or_nil(%ObjectEpoch{} = epoch), do: epoch

  defp sha256_hex(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  defp md5_hex(bytes), do: :crypto.hash(:md5, bytes) |> Base.encode16(case: :lower)

  describe "claim_epoch / current_epoch（quorum 编排）" do
    test "absent → previous=nil、endpoints_ok=6、placement_snapshot 交给调用者；每端点落盘 claimed",
         ctx do
      o = opts(ctx)
      t = target("claim-fresh")
      assert {:ok, :absent} = Distributed.current_epoch(t, o)

      assert {:ok, %{previous: nil, endpoints_ok: 6, placement_snapshot: snap}} =
               Distributed.claim_epoch(t, token(1, @id_a), "put", o)

      assert snap == placement_snapshot(ctx)

      assert {:ok, %ObjectEpoch{phase: "claimed", previous_token: nil} = epoch} =
               Distributed.current_epoch(t, o)

      assert epoch.token == token(1, @id_a)
      assert epoch.operation == "put"
      assert epoch.value_type == "object"

      # 每端点各有一份 durable epoch（per-endpoint 原语经 Transport 逐端点执行）
      Enum.each(ctx.endpoints, fn endpoint ->
        assert %ObjectEpoch{phase: "claimed"} = endpoint_epoch(endpoint, t)
      end)
    end

    @tag capture_log: true
    test "fence 全序：不更大 token 全端点拒绝 → :write_quorum；successor claim 链 previous",
         ctx do
      o = opts(ctx)
      t = target("claim-fence")
      assert {:ok, _} = Distributed.claim_epoch(t, token(1, @id_b), "put", o)

      # 同 token 重复 claim 与同 generation 更小 mutation_id 均被全端点 fence 拒绝
      assert {:error, :write_quorum} = Distributed.claim_epoch(t, token(1, @id_b), "put", o)
      assert {:error, :write_quorum} = Distributed.claim_epoch(t, token(1, @id_a), "put", o)

      assert {:ok, %{previous: %ObjectEpoch{} = previous, endpoints_ok: 6}} =
               Distributed.claim_epoch(t, token(2, @id_a), "put", o)

      assert previous.token == token(1, @id_b)

      assert {:ok, %ObjectEpoch{phase: "claimed", previous_token: prev_tok}} =
               Distributed.current_epoch(t, o)

      assert prev_tok == token(1, @id_b)
    end

    @tag capture_log: true
    test "set_read_epoch_down：2 端点读失联仍裁决；3 端点 → epoch_quorum_unavailable", ctx do
      o = opts(ctx)
      t = target("claim-read-down")
      assert {:ok, _} = Distributed.claim_epoch(t, token(1, @id_a), "put", o)

      [e0, e1, e2 | _rest] = ctx.endpoints
      {n0, d0} = e0
      {n1, d1} = e1
      InProcess.set_read_epoch_down(n0, d0)
      InProcess.set_read_epoch_down(n1, d1)

      # 可读端点 4 >= epoch_quorum：裁决通过；claim 仍全端点 CAS（读失联不影响写）
      assert {:ok, %ObjectEpoch{token: tok}} = Distributed.current_epoch(t, o)
      assert tok == token(1, @id_a)
      assert {:ok, %{endpoints_ok: 6}} = Distributed.claim_epoch(t, token(2, @id_a), "put", o)

      # 第 3 端点读失联：可读 3 < 4 → 读裁决与 claim（previous 读先行）均拒绝（不猜测）
      {n2, d2} = e2
      InProcess.set_read_epoch_down(n2, d2)
      assert {:error, :epoch_quorum_unavailable} = Distributed.current_epoch(t, o)

      assert {:error, :epoch_quorum_unavailable} =
               Distributed.claim_epoch(t, token(3, @id_a), "put", o)
    end
  end

  describe "协议化 put（publish 分支，quorum 门）" do
    # B4 断言 1（B2 断言 1+2 语义）：published 中间态五要素 + finalize 收口 + 幂等。
    test "overwrite：published 中间态 + finalize 收口 + 幂等", ctx do
      o = opts(ctx)
      {:ok, _} = Distributed.put(@bucket, "k", "null", ["old-bytes"], o)
      old = snapshot_finals(ctx.endpoints, "k")

      {mctx, put_result} =
        drive_mutation_put(ctx, "k", ["new-bytes"], 1, @id_a, fn mctx, result ->
          # publish 返回即「published 中间态」：rename 已完成、finalize 尚未发生。
          assert {:ok, %{epoch_fingerprint: fingerprint}} = result

          assert {:ok, %ObjectEpoch{phase: "published"} = epoch} =
                   Distributed.current_epoch(mctx.target, o)

          assert epoch.fingerprint == fingerprint
          assert fingerprint["etag"] == md5_hex("new-bytes")
          assert fingerprint["size"] == byte_size("new-bytes")

          # 对象级读已见新字节；每端点 final meta.json 字节与 fingerprint 精确匹配
          # （本地 Meta.encode 字节 = 各端点落盘字节），backup 含 manifest + 旧文件（逐字节）。
          assert body(ctx, "k") == "new-bytes"

          Enum.each(old, fn {endpoint, old_part, old_meta} ->
            final = final_dir(endpoint, "k")
            final_meta = File.read!(Path.join(final, "meta.json"))
            assert fingerprint["sidecar_sha256"] == sha256_hex(final_meta)

            backup = backup_dir(endpoint, @id_a)

            assert {:ok, manifest} =
                     MutationBackup.decode(File.read!(Path.join(backup, "manifest.json")))

            assert Enum.sort(MutationBackup.entry_names(manifest)) == ["meta.json", "part.0"]
            assert manifest.token == mctx.token
            assert manifest.previous_token == nil
            assert File.read!(Path.join(backup, "part.0")) == old_part
            assert File.read!(Path.join(backup, "meta.json")) == old_meta
          end)

          result
        end)

      assert {:ok, %{epoch_fingerprint: _fingerprint}} = put_result

      # put 成功收口：Control.finalize → finalize_if_current → epoch=committed、backup 消失
      assert {:ok, %ObjectEpoch{phase: "committed"}} = Distributed.current_epoch(mctx.target, o)

      Enum.each(ctx.endpoints, fn endpoint -> refute File.exists?(backup_dir(endpoint, @id_a)) end)

      assert body(ctx, "k") == "new-bytes"
      assert Enum.all?(ctx.endpoints, &temp_empty?/1)

      # 重复 finalize 幂等
      assert {:ok, :finalized} = Distributed.finalize_if_current(mctx, o)
      assert {:ok, %ObjectEpoch{phase: "committed"}} = Distributed.current_epoch(mctx.target, o)

      # committed 后 restore 被 quorum 级防线拒绝（metadata_committed 禁回滚落点）
      assert {:error, :epoch_committed} = Distributed.restore_if_current(mctx, o)
      assert body(ctx, "k") == "new-bytes"
    end

    # B4 断言 1（B2 断言 3 语义）：metadata 失败 → Control rollback → 每端点旧值逐字节恢复。
    test "metadata 失败：Control rollback → restore_if_current 每端点逐字节恢复旧值", ctx do
      o = opts(ctx)
      {:ok, _} = Distributed.put(@bucket, "k", "null", ["old-bytes"], o)
      old = snapshot_finals(ctx.endpoints, "k")

      {mctx, put_result} =
        drive_mutation_put(ctx, "k", ["new-bytes"], 1, @id_a, fn _mctx, result ->
          assert {:ok, _} = result
          {:error, :metadata_commit_failed}
        end)

      assert {:error, :metadata_commit_failed} = put_result
      assert_finals(old, "k")
      assert body(ctx, "k") == "old-bytes"

      assert {:ok, %ObjectEpoch{phase: "rolled_back"}} =
               Distributed.current_epoch(mctx.target, o)

      Enum.each(ctx.endpoints, fn endpoint -> refute File.exists?(backup_dir(endpoint, @id_a)) end)

      assert Enum.all?(ctx.endpoints, &temp_empty?/1)
    end

    test "fresh metadata 失败：exact-current quorum 删除 final 并收敛 rolled_back", ctx do
      o = opts(ctx)
      version_id = "fresh-v1"

      {mctx, put_result} =
        drive_mutation_put(
          ctx,
          "fresh",
          ["fresh-bytes"],
          1,
          @id_a,
          fn _mctx, result ->
            assert {:ok, _} = result
            {:error, :metadata_commit_failed}
          end,
          version_id: version_id
        )

      assert {:error, :metadata_commit_failed} = put_result

      assert {:ok, %ObjectEpoch{phase: "rolled_back"}} =
               Distributed.current_epoch(mctx.target, o)

      Enum.each(ctx.endpoints, fn endpoint ->
        refute File.exists?(final_dir(endpoint, "fresh", version_id))
        refute File.exists?(backup_dir(endpoint, @id_a))

        assert %ObjectEpoch{phase: "rolled_back", token: token} =
                 endpoint_epoch(endpoint, mctx.target)

        assert token == mctx.token
      end)
    end

    @tag capture_log: true
    test "fresh restore 低于 quorum：返回 partial，已授权端点删除，失败端点保留恢复证据", ctx do
      o = opts(ctx)
      [e0, e1, e2, e3, e4, e5] = ctx.endpoints

      {_mctx, put_result} =
        drive_mutation_put(
          ctx,
          "fresh-partial",
          ["fresh-bytes"],
          1,
          @id_a,
          fn mctx, result ->
            assert {:ok, _} = result

            Enum.each([e3, e4, e5], fn endpoint ->
              File.write!(Path.join(backup_dir(endpoint, @id_a), "manifest.json"), "{corrupt")
            end)

            assert {:error,
                    {:partial, %{applied: 3, superseded: 0, epoch_quorum: 4, errors: errors}}} =
                     Distributed.restore_if_current(mctx, o)

            assert length(errors) == 3

            Enum.each([e0, e1, e2], fn endpoint ->
              refute File.exists?(final_dir(endpoint, "fresh-partial"))
              refute File.exists?(backup_dir(endpoint, @id_a))
              assert %ObjectEpoch{phase: "rolled_back"} = endpoint_epoch(endpoint, mctx.target)
            end)

            Enum.each([e3, e4, e5], fn endpoint ->
              assert File.regular?(Path.join(final_dir(endpoint, "fresh-partial"), "part.0"))

              assert File.read!(Path.join(backup_dir(endpoint, @id_a), "manifest.json")) ==
                       "{corrupt"

              assert %ObjectEpoch{phase: "published"} = endpoint_epoch(endpoint, mctx.target)
            end)

            {:error, :metadata_commit_failed}
          end
        )

      assert {:error, :metadata_commit_failed} = put_result
    end

    # B4 断言 2（通过半）：set_down(:maxio@n0) 击落 2 端点（e0/e3）→ 4/6 达 quorum，
    # claim/publish/finalize 全程收口；down 端点旧值与协议根均不被触碰。
    test "set_down(:maxio@n0)：4/6 端点达 quorum 收口 committed，down 端点不被触碰", ctx do
      o = opts(ctx)
      {:ok, _} = Distributed.put(@bucket, "k", "null", ["old-bytes"], o)
      old = snapshot_finals(ctx.endpoints, "k")
      down_endpoints = Enum.filter(ctx.endpoints, fn {node, _drive} -> node == :maxio@n0 end)
      live_endpoints = ctx.endpoints -- down_endpoints
      assert length(down_endpoints) == 2

      InProcess.set_down(:maxio@n0)

      {mctx, put_result} =
        drive_mutation_put(ctx, "k", ["new-bytes"], 1, @id_a, fn _mctx, result ->
          assert {:ok, %{epoch_fingerprint: _}} = result
          result
        end)

      assert {:ok, %{epoch_fingerprint: _}} = put_result

      # 4 存活端点收口 committed；K=4 分片仍可重建新字节（n0 仍 down）
      assert {:ok, %ObjectEpoch{phase: "committed"}} = Distributed.current_epoch(mctx.target, o)
      assert body(ctx, "k") == "new-bytes"

      Enum.each(live_endpoints, fn endpoint ->
        assert %ObjectEpoch{phase: "committed"} = endpoint_epoch(endpoint, mctx.target)
        refute File.exists?(backup_dir(endpoint, @id_a))
      end)

      # down 端点：旧 final 逐字节不变、无 epoch、无 backup（未参与，收敛归 Phase 2C heal）
      Enum.each(down_endpoints, fn endpoint ->
        {_endpoint, old_part, old_meta} = Enum.find(old, fn {e, _p, _m} -> e == endpoint end)
        final = final_dir(endpoint, "k")
        assert File.read!(Path.join(final, "part.0")) == old_part
        assert File.read!(Path.join(final, "meta.json")) == old_meta
        refute File.exists?(epoch_path(endpoint, mctx.target))
        refute File.exists?(backup_dir(endpoint, @id_a))
      end)
    end

    # B4 断言 2（拒绝半，字面）：claim 后再断一整节点 → manifest 门 2/6 < epoch_quorum →
    # 在任何破坏性 IO 之前拒绝，全端点旧 final 逐字节不变。
    @tag capture_log: true
    test "claim 后再断一节点：manifest 门拒绝，零破坏性 IO", ctx do
      o = opts(ctx)
      {:ok, _} = Distributed.put(@bucket, "k", "null", ["old-bytes"], o)
      old = snapshot_finals(ctx.endpoints, "k")

      InProcess.set_down(:maxio@n0)

      {_mctx, put_result} =
        drive_mutation_put(
          ctx,
          "k",
          ["new-bytes"],
          1,
          @id_a,
          fn _mctx, result -> result end,
          after_claim: fn _mctx -> InProcess.set_down(:maxio@n1) end
        )

      assert {:error, {:mutation_backup_quorum, %{endpoints_ok: 2, epoch_quorum: 4}}} =
               put_result

      # 尚无任何破坏性 IO：全端点旧 final 逐字节不变（含 down 端点——从未被触碰）；
      # 备份从未物化（少数端点的 manifest 是非破坏性 durable 证据，保留无害）。
      assert_finals(old, "k")

      Enum.each(ctx.endpoints, fn endpoint ->
        refute File.exists?(Path.join(backup_dir(endpoint, @id_a), "part.0"))
        refute File.exists?(Path.join(backup_dir(endpoint, @id_a), "meta.json"))
      end)
    end

    # B4 断言 2（拒绝半，CAS 门）：3 端点 cas_epoch 失联 → publish CAS 门 3/6 < epoch_quorum
    # → 不进入 rename、backup 保留（中间态取证）；rollback 经 restore_if_current 收敛复旧值。
    @tag capture_log: true
    test "set_cas_epoch_down 3 端点：publish 拒绝、backup 保留、rollback 收敛复旧值", ctx do
      o = opts(ctx)
      {:ok, _} = Distributed.put(@bucket, "k", "null", ["old-bytes"], o)
      old = snapshot_finals(ctx.endpoints, "k")
      [_e0, _e1, _e2, e3, e4, e5] = ctx.endpoints

      inject = fn _mctx ->
        Enum.each([e3, e4, e5], fn {node, drive} ->
          InProcess.set_cas_epoch_down(node, drive)
        end)
      end

      {mctx, put_result} =
        drive_mutation_put(
          ctx,
          "k",
          ["new-bytes"],
          1,
          @id_a,
          fn _mctx, result ->
            assert {:error, {:epoch_publish_quorum, %{endpoints_ok: 3, epoch_quorum: 4}}} =
                     result

            # publish 拒绝的中间态：新字节未 rename 进任何 final；旧值已在 durable backup
            # （manifest + 逐字节），final 缺旧文件——backup 保留、不猜测、不破坏。
            Enum.each(old, fn {endpoint, old_part, old_meta} ->
              final = final_dir(endpoint, "k")
              backup = backup_dir(endpoint, @id_a)

              refute File.regular?(Path.join(final, "part.0"))
              refute File.regular?(Path.join(final, "meta.json"))

              assert {:ok, _manifest} =
                       MutationBackup.decode(File.read!(Path.join(backup, "manifest.json")))

              assert File.read!(Path.join(backup, "part.0")) == old_part
              assert File.read!(Path.join(backup, "meta.json")) == old_meta
            end)

            result
          end,
          after_claim: inject
        )

      assert {:error, {:epoch_publish_quorum, _evidence}} = put_result

      # ObjectCommit rollback → restore_if_current：cas 失联不影响 restore 原语，全端点
      # 按 manifest 回位旧字节、epoch=rolled_back、backup 清空。
      assert_finals(old, "k")
      assert body(ctx, "k") == "old-bytes"
      assert {:ok, %ObjectEpoch{phase: "rolled_back"}} = Distributed.current_epoch(mctx.target, o)

      Enum.each(ctx.endpoints, fn endpoint -> refute File.exists?(backup_dir(endpoint, @id_a)) end)

      assert Enum.all?(ctx.endpoints, &temp_empty?/1)
    end

    # B4 断言 3（quorum intersection，经 set_cas_epoch_down 定向注入）：A 的 claim/publish
    # 被挡在 e4/e5 → A 在 {e0..e3} 达 quorum published；B（gen+1）在 {e2..e5} 达 quorum
    # claim → A 的迟到 restore 全局裁决读到 B（交集端点 e2/e3）→ :superseded，e0/e1 上
    # A 的旧 epoch / final / backup 不被 A 的恢复动作触碰。
    @tag capture_log: true
    test "quorum intersection：A 的迟到 restore 全局裁决 :superseded，e0/e1 不被触碰", ctx do
      o = opts(ctx)
      {:ok, _} = Distributed.put(@bucket, "k", "null", ["old-bytes"], o)
      [e0, e1, e2, e3, e4, e5] = ctx.endpoints
      t = target("k")

      # e4/e5 的 epoch CAS 失联：A 的 claim/publish 恰好只在 {e0..e3} 达 quorum。
      Enum.each([e4, e5], fn {node, drive} -> InProcess.set_cas_epoch_down(node, drive) end)

      {_mctx, put_result} =
        drive_mutation_put(ctx, "k", ["a-bytes"], 1, @id_a, fn mctx_a, result ->
          assert {:ok, %{epoch_fingerprint: _}} = result

          # A published 在 {e0..e3}；e4/e5 无 epoch（claim CAS 被挡）
          Enum.each([e0, e1, e2, e3], fn endpoint ->
            assert %ObjectEpoch{phase: "published", token: tok} = endpoint_epoch(endpoint, t)
            assert tok == token(1, @id_a)
          end)

          Enum.each([e4, e5], fn endpoint -> assert endpoint_epoch(endpoint, t) == :absent end)

          # B（gen+1）在 {e2..e5} 逐端点合法 claim（per-endpoint CAS 接受严格更大 token；
          # 直调 ShardServer，不经 InProcess 失联注入），4 端点 = epoch_quorum：B 的 claim
          # quorum 与 A 的 publish quorum 交集 = {e2, e3}。
          claim_on_endpoints!([e2, e3, e4, e5], t, token(2, @id_b))

          snapshot =
            Enum.map([e0, e1], fn endpoint ->
              backup = backup_dir(endpoint, @id_a)

              %{
                endpoint: endpoint,
                epoch: File.read!(epoch_path(endpoint, t)),
                part: File.read!(Path.join(final_dir(endpoint, "k"), "part.0")),
                meta: File.read!(Path.join(final_dir(endpoint, "k"), "meta.json")),
                backup_manifest: File.read!(Path.join(backup, "manifest.json")),
                backup_part: File.read!(Path.join(backup, "part.0")),
                backup_meta: File.read!(Path.join(backup, "meta.json"))
              }
            end)

          # A 的迟到 restore：全局裁决读到交集端点上的 B → 整体 :superseded，任何端点不动
          assert {:ok, :superseded} = Distributed.restore_if_current(mctx_a, o)

          Enum.each(snapshot, fn snap ->
            backup = backup_dir(snap.endpoint, @id_a)
            final = final_dir(snap.endpoint, "k")
            assert File.read!(epoch_path(snap.endpoint, t)) == snap.epoch
            assert File.read!(Path.join(final, "part.0")) == snap.part
            assert File.read!(Path.join(final, "meta.json")) == snap.meta
            assert File.read!(Path.join(backup, "manifest.json")) == snap.backup_manifest
            assert File.read!(Path.join(backup, "part.0")) == snap.backup_part
            assert File.read!(Path.join(backup, "meta.json")) == snap.backup_meta
          end)

          # B 的 claimed epoch 不被 A 触碰
          Enum.each([e2, e3, e4, e5], fn endpoint ->
            assert %ObjectEpoch{phase: "claimed", token: tok} = endpoint_epoch(endpoint, t)
            assert tok == token(2, @id_b)
          end)

          {:error, :stale_owner}
        end)

      # A 的 Control rollback 重放同样 :superseded：e0/e1 三态仍不变
      assert {:error, :stale_owner} = put_result

      Enum.each([e0, e1], fn endpoint ->
        assert %ObjectEpoch{phase: "published", token: tok} = endpoint_epoch(endpoint, t)
        assert tok == token(1, @id_a)
        assert File.exists?(Path.join(backup_dir(endpoint, @id_a), "manifest.json"))
      end)

      Enum.each([e2, e3, e4, e5], fn endpoint ->
        assert %ObjectEpoch{token: tok} = endpoint_epoch(endpoint, t)
        assert tok == token(2, @id_b)
      end)
    end

    # B4 断言 1（B2 断言 4 语义）：A published 后 B 完整协议 put（gen+1）走完并收口，
    # A 的迟到 restore → :superseded，B 的 final/epoch 逐字节不变、A 的 backup 保留。
    test "full successor：A 的迟到 restore → :superseded，绝不触碰 B", ctx do
      o = opts(ctx)
      {:ok, _} = Distributed.put(@bucket, "k", "null", ["old-bytes"], o)

      {_mctx_a, put_result} =
        drive_mutation_put(ctx, "k", ["a-bytes"], 1, @id_a, fn mctx_a, result ->
          assert {:ok, _} = result

          # A published（未 finalize）之下，B 走完整协议 put（gen+1）并收口 committed
          {_mctx_b, b_result} =
            drive_mutation_put(ctx, "k", ["b-bytes"], 2, @id_b, fn _mctx_b, r -> r end)

          assert {:ok, _} = b_result

          assert {:ok, %ObjectEpoch{phase: "committed", token: tok_b}} =
                   Distributed.current_epoch(mctx_a.target, o)

          assert tok_b == token(2, @id_b)
          b_finals = snapshot_finals(ctx.endpoints, "k")
          assert body(ctx, "k") == "b-bytes"

          # A 的迟到 restore：只报告 superseded，B 的 final/epoch 不动，A 的 backup 保留
          assert {:ok, :superseded} = Distributed.restore_if_current(mctx_a, o)
          assert_finals(b_finals, "k")

          assert {:ok, %ObjectEpoch{phase: "committed", token: ^tok_b}} =
                   Distributed.current_epoch(mctx_a.target, o)

          Enum.each(ctx.endpoints, fn endpoint ->
            assert File.exists?(Path.join(backup_dir(endpoint, @id_a), "manifest.json"))
          end)

          {:error, :stale_owner}
        end)

      assert {:error, :stale_owner} = put_result
      assert body(ctx, "k") == "b-bytes"

      assert {:ok, %ObjectEpoch{token: tok}} = Distributed.current_epoch(target("k"), o)
      assert tok == token(2, @id_b)

      Enum.each(ctx.endpoints, fn endpoint ->
        assert File.exists?(Path.join(backup_dir(endpoint, @id_a), "manifest.json"))
      end)
    end
  end

  describe "restore_if_current / finalize_if_current（placement snapshot 防线）" do
    test "epoch 全端点 absent：restore/finalize → :epoch_missing，绝不删任何字节", ctx do
      o = opts(ctx)
      {:ok, _} = Distributed.put(@bucket, "k", "null", ["old-bytes"], o)
      old = snapshot_finals(ctx.endpoints, "k")

      mctx = build_ctx(ctx, "k", 1, @id_a, nil, "null")
      assert {:error, :epoch_missing} = Distributed.restore_if_current(mctx, o)
      assert {:error, :epoch_missing} = Distributed.finalize_if_current(mctx, o)
      assert_finals(old, "k")
    end

    # B4 断言 4：topology_hash 漂移 → {:error, {:placement_drift, evidence}}，不触任何端点。
    test "topology_hash 漂移：restore/finalize → placement_drift，不触任何端点", ctx do
      o = opts(ctx)
      {:ok, _} = Distributed.put(@bucket, "k", "null", ["old-bytes"], o)

      # 先走一遍协议 put（rollback 收敛为 rolled_back）：使全端点持有真实 epoch，
      # 漂移防线必须在读任何端点之前拒绝——epoch/final 逐字节不变即证据。
      {mctx, put_result} =
        drive_mutation_put(ctx, "k", ["new-bytes"], 1, @id_a, fn _mctx, result ->
          assert {:ok, _} = result
          {:error, :halt_before_finalize}
        end)

      assert {:error, :halt_before_finalize} = put_result

      drifted = %MutationContext{
        mctx
        | placement_snapshot: Map.put(mctx.placement_snapshot, "topology_hash", "drifted-hash")
      }

      finals = snapshot_finals(ctx.endpoints, "k")
      epochs = Enum.map(ctx.endpoints, fn e -> File.read!(epoch_path(e, mctx.target)) end)

      assert {:error, {:placement_drift, evidence}} = Distributed.restore_if_current(drifted, o)
      assert evidence.snapshot_topology_hash == "drifted-hash"
      assert evidence.current_topology_hash == Topology.fingerprint(ctx.topology)

      assert {:error, {:placement_drift, _evidence}} = Distributed.finalize_if_current(drifted, o)

      # 不触任何端点：final 与 epoch 逐字节不变
      assert_finals(finals, "k")

      assert epochs ==
               Enum.map(ctx.endpoints, fn e -> File.read!(epoch_path(e, mctx.target)) end)
    end

    test "placement_snapshot 缺失/形状非法：结构化拒绝，不退回当前 router", ctx do
      o = opts(ctx)
      mctx = build_ctx(ctx, "k", 1, @id_a, nil, "null")

      missing = %MutationContext{mctx | placement_snapshot: nil}

      assert {:error, {:invalid_placement_snapshot, nil}} =
               Distributed.restore_if_current(missing, o)

      malformed = %MutationContext{mctx | placement_snapshot: %{"set_id" => "0"}}

      assert {:error, {:invalid_placement_snapshot, _snapshot}} =
               Distributed.finalize_if_current(malformed, o)
    end
  end

  describe "非协议路径回归切片" do
    # B4 断言（切片）：无协议 opts 的 put 不落协议根、不写 epoch（全量回归由
    # distributed_test + distributed_conformance_test 把关）。
    test "非协议 put：不落 .maxio-object-mutations / .maxio-object-epochs", ctx do
      o = opts(ctx)
      {:ok, _} = Distributed.put(@bucket, "plain", "null", ["bytes-1"], o)
      # overwrite 路径（plan_distributed_backups 的 .tmp 备份）同样不触协议根
      {:ok, _} = Distributed.put(@bucket, "plain", "null", ["bytes-2"], o)

      Enum.each(ctx.endpoints, fn {_node, drive} ->
        refute File.exists?(Path.join(drive, ".maxio-object-mutations"))
        refute File.exists?(Path.join(drive, ".maxio-object-epochs"))
      end)

      assert {:ok, :absent} = Distributed.current_epoch(target("plain"), o)
      assert Enum.all?(ctx.endpoints, &temp_empty?/1)
    end

    test "object_mutation 非 MutationContext：结构化拒绝，旧 final 不动", ctx do
      o = opts(ctx)
      {:ok, _} = Distributed.put(@bucket, "k", "null", ["old-bytes"], o)
      old = snapshot_finals(ctx.endpoints, "k")

      around = fn _prepared, publish ->
        publish.(version_id: "null", object_meta: %{}, object_mutation: :bogus)
      end

      assert {:error, {:invalid_object_mutation, :bogus}} =
               Distributed.put(
                 @bucket,
                 "k",
                 "null",
                 ["new"],
                 Keyword.put(o, :around_object_commit, around)
               )

      assert_finals(old, "k")
      assert Enum.all?(ctx.endpoints, &temp_empty?/1)
    end

    # Phase 2A C1（B3 审查项 3）：commit_object_replace 非 quorum 错误的窄 case 收口。
    # 注入手段：around 内预占 Control 注册位 → 非协议 publish 的 commit_object_replace
    # 内 Control.register 必然 {:error, :already_registered}（收口前为 CaseClauseError
    # 裸崩）；:write_quorum 形状不变（上方既有 quorum 测试把关）。
    @tag capture_log: true
    test "commit_object_replace 非 quorum 错误 → 结构化 {:error, {:commit_failed, _}}，旧 final 不动",
         ctx do
      o = opts(ctx)
      {:ok, _} = Distributed.put(@bucket, "k", "null", ["old-bytes"], o)
      old = snapshot_finals(ctx.endpoints, "k")

      around = fn prepared, publish ->
        control = Map.fetch!(prepared, :object_commit_control)
        identity = Map.fetch!(prepared, :object_commit_identity)
        :ok = Control.register(control, identity, fn -> :ok end, fn -> :ok end)
        publish.(version_id: "null", object_meta: %{})
      end

      assert {:error, {:commit_failed, :already_registered}} =
               Distributed.put(
                 @bucket,
                 "k",
                 "null",
                 ["new"],
                 Keyword.put(o, :around_object_commit, around)
               )

      # 旧 final 逐字节不动、对象仍可读（错误发生在任何破坏性 rename 之前）
      assert_finals(old, "k")
      assert body(ctx, "k") == "old-bytes"
    end
  end
end
