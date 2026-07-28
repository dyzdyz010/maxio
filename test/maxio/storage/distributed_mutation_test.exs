defmodule Maxio.Storage.DistributedMutationTest do
  # 共用 InProcess 全局 ETS（:maxio_inproc_down）必须串行；无 DataCase/Repo：MutationContext
  # 直接以 struct 构造（不经 journal），对应实现计划 B4 的 Distributed 后端验收断言。
  # 1 pool / 1 set / N=6 端点（3 node 各 2 drive，同机模拟）→ write_quorum=4、
  # epoch_quorum=max(4, ⌊6/2⌋+1)=4：容忍 2 端点故障，3 端点故障必须拒绝；
  # set_down(:maxio@n0) 恰好击落 2 个 endpoint（e0/e3）。
  use ExUnit.Case, async: false

  alias Maxio.Cluster.{Paths, Placement, ShardServer, Topology, Transport.InProcess}
  alias Maxio.Storage.{Distributed, EpochStore, MutationBackup, MutationContext, ObjectEpoch}
  alias Maxio.Storage.ObjectCommit.Control
  alias Maxio.Storage.PublishedProof
  alias Maxio.Test.TransportProofRecorder, as: Recorder

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

      assert {:ok, %{epoch_fingerprint: fingerprint}} = put_result

      # put 成功收口：Control.finalize → finalize_if_current → epoch=committed、backup 消失
      assert {:ok, %ObjectEpoch{phase: "committed"}} = Distributed.current_epoch(mctx.target, o)

      Enum.each(ctx.endpoints, fn endpoint -> refute File.exists?(backup_dir(endpoint, @id_a)) end)

      assert body(ctx, "k") == "new-bytes"
      assert Enum.all?(ctx.endpoints, &temp_empty?/1)

      # 重复 finalize 幂等（proof-aware：committed 重放必须先复验才收敛）
      proof_ctx = %MutationContext{mctx | published_fingerprint: fingerprint}

      assert {:ok, {:finalized, %{"status" => "finalized", "verified" => 6, "finalized" => 6}}} =
               Distributed.finalize_if_current(proof_ctx, o)

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

      # proof-aware finalize：该 ctx 没有 published fingerprint —— 非法 request 在读取
      # epoch 之前就 fail closed 成 non-owned corrupt（因此不是 orphan）；owned corrupt
      # 才参与全局 integrity 选择，故外层落 fallback unavailable。绝不删任何字节。
      assert {:error,
              {:published_proof_failed, :unavailable,
               %{
                 "mode" => "finalize",
                 "verified" => 0,
                 "finalized" => 0,
                 "orphaned" => 0,
                 "debt" => 6,
                 "degraded" => details
               }}} = Distributed.finalize_if_current(mctx, o)

      assert Enum.all?(details, &(&1["class"] == "corrupt" and &1["owned"] == false))
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

      # proof-aware finalize 的漂移出口是 canonical、脱敏、零端点 RPC 的 aggregate
      # placement drift（绝不回传 node/drive/hash 明细）。
      assert {:error,
              {:published_proof_failed, :placement_drift,
               %{
                 "scope" => "aggregate",
                 "mode" => "finalize",
                 "class" => "placement_drift",
                 "verified" => 0,
                 "observed_owned" => 0,
                 "unavailable" => 0,
                 "finalized" => 0,
                 "orphaned" => 0
               } = drift}} = Distributed.finalize_if_current(drifted, o)

      refute inspect(drift) =~ "drifted-hash"

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

      assert {:error,
              {:published_proof_failed, :placement_drift,
               %{"scope" => "aggregate", "mode" => "finalize", "verified" => 0}}} =
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

  describe "Task 2 backend proof aggregation（RED）" do
    defp dist_published_ctx!(ctx, key) do
      {mctx, {:ok, %{epoch_fingerprint: fingerprint}}} =
        drive_mutation_put(ctx, key, ["new-bytes"], 1, @id_a, fn _mctx, result -> result end)

      %MutationContext{mctx | published_fingerprint: fingerprint}
    end

    @tag :task2_red_backend
    test "task2 red: Distributed verify_published resolves only the frozen placement snapshot",
         ctx do
      o = opts(ctx)
      :ok = Distributed.put_bucket(@bucket, o)
      proof_ctx = dist_published_ctx!(ctx, "k")

      assert function_exported?(Distributed, :verify_published, 2)

      assert {:ok,
              {:verified,
               %{
                 "scope" => "aggregate",
                 "mode" => "proof",
                 "status" => "verified",
                 "required" => 4,
                 "verified" => 6,
                 "debt" => 0,
                 "degraded" => [],
                 "omitted" => 0
               } = summary}} = Distributed.verify_published(proof_ctx, o)

      refute Enum.any?(~w(path root drive node endpoints), &Map.has_key?(summary, &1))

      refute Enum.any?(ctx.endpoints, fn {node, drive} ->
               inspect(summary) =~ drive or inspect(summary) =~ Atom.to_string(node)
             end)

      # topology hash 漂移 → canonical placement drift，绝不退回当前 router。
      drifted = %MutationContext{
        proof_ctx
        | placement_snapshot:
            Map.put(proof_ctx.placement_snapshot, "topology_hash", "drifted-hash")
      }

      assert {:error,
              {:published_proof_failed, :placement_drift,
               %{
                 "scope" => "aggregate",
                 "mode" => "proof",
                 "status" => "failed",
                 "class" => "placement_drift",
                 "verified" => 0,
                 "observed_owned" => 0,
                 "unavailable" => 0
               } = drift}} = Distributed.verify_published(drifted, o)

      refute inspect(drift) =~ "drifted-hash"

      # placement snapshot 缺失同样在任何 RPC 之前失败关闭。
      missing = %MutationContext{proof_ctx | placement_snapshot: nil}

      assert {:error, {:published_proof_failed, :placement_drift, %{"verified" => 0}}} =
               Distributed.verify_published(missing, o)
    end

    @tag :task2_red_backend
    test "task2 red: every Distributed failure path stays bound to its captured ordinal", ctx do
      o = opts(ctx)
      :ok = Distributed.put_bucket(@bucket, o)
      proof_ctx = dist_published_ctx!(ctx, "k")

      {down_node, down_drive} = Enum.at(ctx.endpoints, 5)

      # down 状态存活于 setup 创建、随测试进程消亡的 ETS 表；无需（也不能）在 on_exit
      # 里回滚——那时表已随属主进程销毁。
      InProcess.set_drive_down(down_node, down_drive)

      assert {:ok,
              {:degraded,
               %{
                 "scope" => "aggregate",
                 "status" => "degraded",
                 "required" => 4,
                 "verified" => 5,
                 "unavailable" => 1,
                 "debt" => 1,
                 "degraded" => [detail]
               }}} = Distributed.verify_published(proof_ctx, o)

      # 结果按捕获的 expected ordinal 归位，而不是完成顺序 / node / drive。
      assert detail["endpoint"] == "ordinal:5"
      assert detail["class"] == "unavailable"
      assert detail["owned"] == false
      refute Enum.any?(~w(path drive node), &Map.has_key?(detail, &1))
      refute inspect(detail) =~ down_drive
    end

    @tag :task2_red_backend
    test "task2 red: Distributed finalize returns the proof-aware union with orphan hints", ctx do
      o = opts(ctx)
      :ok = Distributed.put_bucket(@bucket, o)

      terminal_ctx = dist_published_ctx!(ctx, "k-terminal")

      assert {:ok,
              {:finalized,
               %{
                 "scope" => "aggregate",
                 "mode" => "finalize",
                 "status" => "finalized",
                 "required" => 4,
                 "verified" => 6,
                 "finalized" => 6,
                 "debt" => 0,
                 "orphaned" => 0
               }}} = Distributed.finalize_if_current(terminal_ctx, o)

      orphan_ctx = dist_published_ctx!(ctx, "k-orphan")
      orphan_endpoint = Enum.at(ctx.endpoints, 5)
      File.rm_rf!(epoch_path(orphan_endpoint, orphan_ctx.target))

      assert {:ok,
              {:finalized,
               %{
                 "status" => "finalized",
                 "verified" => 5,
                 "finalized" => 5,
                 "debt" => 0,
                 "orphaned" => 1,
                 "orphan_hints" => [hint]
               }}} = Distributed.finalize_if_current(orphan_ctx, o)

      assert hint["endpoint"] == "ordinal:5"
      assert hint["orphan_reason"] == "epoch_absent"
      # manifest-only 残留绝不被 orphan 授权删除。
      assert File.exists?(Path.join(final_dir(orphan_endpoint, "k-orphan"), "part.0"))
    end

    @tag :task2_red_backend
    test "task2 control: frozen placement guards already reject drift before endpoint IO", ctx do
      o = opts(ctx)
      mctx = build_ctx(ctx, "k", 1, @id_a, nil, "null")

      drifted = %MutationContext{
        mctx
        | placement_snapshot: Map.put(mctx.placement_snapshot, "topology_hash", "drifted-hash")
      }

      assert {:error, {:placement_drift, evidence}} = Distributed.restore_if_current(drifted, o)
      assert evidence.snapshot_topology_hash == "drifted-hash"

      missing = %MutationContext{mctx | placement_snapshot: nil}

      assert {:error, {:invalid_placement_snapshot, nil}} =
               Distributed.restore_if_current(missing, o)
    end
  end

  describe "Task 2 G3 Distributed 冻结 placement 与捕获 ordinal（RED）" do
    setup do
      start_supervised!(Recorder)
      :ok
    end

    defp recorder_opts(ctx), do: [topology: ctx.topology, transport: Recorder]

    # 直接构造一个 set 0 含重复 {node, drive} 的 topology map（绕过 parse 校验），并让
    # snapshot 携带它的精确 fingerprint：hash 一致，唯一的漂移事实就是重复端点身份。
    defp duplicated_topology(ctx) do
      endpoints = ctx.topology.sets[0].endpoints
      duplicated = List.replace_at(endpoints, 5, Enum.at(endpoints, 4))
      put_in(ctx.topology, [:sets, 0, :endpoints], duplicated)
    end

    defp snapshot_for(topology, set_id \\ 0) do
      %{"set_id" => set_id, "pool_id" => 0, "topology_hash" => Topology.fingerprint(topology)}
    end

    defp force_claimed_endpoint!({_node, drive}, mctx) do
      {:ok, claimed} =
        ObjectEpoch.new(mctx.target, mctx.token, %{
          operation: "put",
          phase: "claimed",
          value_type: "object",
          updated_at: DateTime.utc_now()
        })

      assert {:ok, :applied} =
               EpochStore.cas(drive, claimed, {:exact, mctx.token, ["published", "committed"]})
    end

    defp heal_endpoint_final!(source, target, key) do
      source_dir = final_dir(source, key)
      target_dir = final_dir(target, key)
      File.mkdir_p!(target_dir)

      Enum.each(["meta.json", "part.0"], fn name ->
        File.write!(Path.join(target_dir, name), File.read!(Path.join(source_dir, name)))
      end)
    end

    defp break_endpoint_meta!(endpoint, key) do
      meta = Path.join(final_dir(endpoint, key), "meta.json")
      File.write!(meta, File.read!(meta) <> "\n")
    end

    @tag :task2_red_backend
    test "task2 g3: 重复 {node, drive} 身份与未知 set 都在零 RPC 下折叠为 canonical drift",
         ctx do
      o = opts(ctx)
      :ok = Distributed.put_bucket(@bucket, o)
      proof_ctx = dist_published_ctx!(ctx, "k")

      dup_topology = duplicated_topology(ctx)
      dup_ctx = %MutationContext{proof_ctx | placement_snapshot: snapshot_for(dup_topology)}
      dup_opts = [topology: dup_topology, transport: Recorder]

      Recorder.reset_calls()

      assert {:error,
              {:published_proof_failed, :placement_drift,
               %{
                 "scope" => "aggregate",
                 "mode" => "proof",
                 "status" => "failed",
                 "class" => "placement_drift",
                 "verified" => 0,
                 "observed_owned" => 0,
                 "unavailable" => 0,
                 "degraded" => [witness]
               }}} = Distributed.verify_published(dup_ctx, dup_opts)

      assert Recorder.call_count() == 0
      assert witness["owned"] == false
      # shard 域身份：绝不使用 FS 专属的 "local"。
      assert witness["endpoint"] == "ordinal:0"

      refute Enum.any?(ctx.endpoints, fn {node, drive} ->
               inspect(witness) =~ drive or inspect(witness) =~ Atom.to_string(node)
             end)

      # 冻结 snapshot 指向捕获 topology 中不存在的 set：结构化漂移，绝不回退当前 router。
      unknown_ctx = %MutationContext{
        proof_ctx
        | placement_snapshot: snapshot_for(ctx.topology, 7)
      }

      Recorder.reset_calls()

      assert {:error, {:published_proof_failed, :placement_drift, %{"verified" => 0}}} =
               Distributed.verify_published(unknown_ctx, recorder_opts(ctx))

      assert Recorder.call_count() == 0

      # finalize 侧同样零 RPC：每端点 epoch 逐字段不变。
      Recorder.reset_calls()
      before = Enum.map(ctx.endpoints, &endpoint_epoch(&1, proof_ctx.target))

      assert {:error, {:published_proof_failed, :placement_drift, %{"finalized" => 0}}} =
               Distributed.finalize_if_current(unknown_ctx, recorder_opts(ctx))

      assert Recorder.call_count() == 0
      assert Enum.map(ctx.endpoints, &endpoint_epoch(&1, proof_ctx.target)) == before
    end

    @tag :task2_red_backend
    test "task2 g3: 伪造 endpoint 信封交公共 classifier 判 drift，畸形返回/异常仍绑捕获 ordinal",
         ctx do
      o = opts(ctx)
      :ok = Distributed.put_bucket(@bucket, o)
      proof_ctx = dist_published_ctx!(ctx, "k")

      # 1) 响应 identity 与捕获 ordinal 不符：结构漂移，绝不静默去重或接受自报身份。
      {:ok, {:verified, forged_identity}} =
        PublishedProof.verified("ordinal:0", %{layout: "shard:0"})

      Recorder.script(3, {:return, {:ok, {:verified, forged_identity}}})

      assert {:error, {:published_proof_failed, :placement_drift, %{"verified" => 0}}} =
               Distributed.verify_published(proof_ctx, recorder_opts(ctx))

      # 2) aggregate 重入：endpoint wire 绝不能自报聚合计数。
      {:ok, {:verified, aggregate}} =
        PublishedProof.classify(1, [{"local", PublishedProof.verified("local", %{layout: "fs"})}])

      Recorder.script(3, {:return, {:ok, {:verified, aggregate}}})

      assert {:error, {:published_proof_failed, :placement_drift, %{"verified" => 0}}} =
               Distributed.verify_published(proof_ctx, recorder_opts(ctx))

      # 3) 完全畸形的外层返回 → 该捕获 ordinal 的 canonical unavailable（raw term 不外泄）。
      Recorder.script(3, {:return, {:ok, :finalized}})

      assert {:ok, {:degraded, %{"verified" => 5, "unavailable" => 1, "degraded" => [detail]}}} =
               Distributed.verify_published(proof_ctx, recorder_opts(ctx))

      assert detail["endpoint"] == "ordinal:3"
      assert detail["class"] == "unavailable"
      refute inspect(detail) =~ "finalized"

      # 4) RPC 超时 / call-time raise / exit / throw：同样只绑捕获 ordinal，raw reason 不外泄。
      Recorder.script(3, :delegate)

      for action <- [{:return, {:error, :timeout}}, :raise, :exit, :throw] do
        Recorder.script(2, action)

        assert {:ok, {:degraded, %{"verified" => 5, "unavailable" => 1, "degraded" => [d]}}} =
                 Distributed.verify_published(proof_ctx, recorder_opts(ctx))

        assert d["endpoint"] == "ordinal:2"
        assert d["class"] == "unavailable"
        assert d["owned"] == false
      end

      # 控制组：无脚本时六个端点全部 verified，证明上面每一条都是脚本注入的结果。
      Recorder.script(2, :delegate)

      assert {:ok, {:verified, %{"verified" => 6, "debt" => 0}}} =
               Distributed.verify_published(proof_ctx, o)
    end

    @tag :task2_red_backend
    test "task2 g3: Distributed 精确 quorum、低于 quorum 与 successor 的确定性全局顺序", ctx do
      o = opts(ctx)
      :ok = Distributed.put_bucket(@bucket, o)

      exact_ctx = dist_published_ctx!(ctx, "k-exact")
      Enum.each([4, 5], &break_endpoint_meta!(Enum.at(ctx.endpoints, &1), "k-exact"))

      assert {:ok,
              {:degraded, %{"required" => 4, "verified" => 4, "debt" => 2, "degraded" => details}}} =
               Distributed.verify_published(exact_ctx, o)

      assert Enum.map(details, & &1["endpoint"]) |> Enum.sort() == ["ordinal:4", "ordinal:5"]

      below_ctx = dist_published_ctx!(ctx, "k-below")
      Enum.each([3, 4, 5], &break_endpoint_meta!(Enum.at(ctx.endpoints, &1), "k-below"))

      assert {:error,
              {:published_proof_failed, :mismatch,
               %{"scope" => "aggregate", "status" => "failed", "verified" => 3}}} =
               Distributed.verify_published(below_ctx, o)

      # successor 优先于任何少数派降级。
      successor_ctx = dist_published_ctx!(ctx, "k-successor")
      break_endpoint_meta!(Enum.at(ctx.endpoints, 4), "k-successor")

      claim_on_endpoints!(
        [Enum.at(ctx.endpoints, 5)],
        successor_ctx.target,
        token(2, @id_b)
      )

      assert {:ok,
              {:superseded,
               %{
                 "scope" => "aggregate",
                 "status" => "superseded",
                 "verified" => 0,
                 "observed_owned" => 0,
                 "unavailable" => 0
               }}} = Distributed.verify_published(successor_ctx, o)
    end

    @tag :task2_red_backend
    test "task2 g3: Distributed finalize —— claimed 债务、heal 收敛与 orphan-only 不投票", ctx do
      o = opts(ctx)
      :ok = Distributed.put_bucket(@bucket, o)

      debt_ctx = dist_published_ctx!(ctx, "k-claimed")
      claimed_endpoint = Enum.at(ctx.endpoints, 5)
      break_endpoint_meta!(claimed_endpoint, "k-claimed")
      force_claimed_endpoint!(claimed_endpoint, debt_ctx)

      assert {:ok,
              {:cleanup_pending,
               %{
                 "scope" => "aggregate",
                 "mode" => "finalize",
                 "status" => "cleanup_pending",
                 "verified" => 5,
                 "finalized" => 5,
                 "orphaned" => 0,
                 "degraded" => [debt_detail]
               }}} = Distributed.finalize_if_current(debt_ctx, o)

      assert debt_detail["endpoint"] == "ordinal:5"
      assert debt_detail["owned"] == true

      assert %ObjectEpoch{phase: "claimed", fingerprint: nil} =
               endpoint_epoch(claimed_endpoint, debt_ctx.target)

      assert File.exists?(Path.join(final_dir(claimed_endpoint, "k-claimed"), "part.0"))

      heal_endpoint_final!(Enum.at(ctx.endpoints, 0), claimed_endpoint, "k-claimed")

      assert {:ok, {:finalized, %{"verified" => 6, "finalized" => 6, "debt" => 0}}} =
               Distributed.finalize_if_current(debt_ctx, o)

      assert %ObjectEpoch{phase: "committed", fingerprint: fingerprint} =
               endpoint_epoch(claimed_endpoint, debt_ctx.target)

      assert fingerprint == debt_ctx.published_fingerprint

      # orphan-only：全部端点 epoch 缺失 → 不投票、不计 debt，整体 unavailable failure。
      orphan_ctx = dist_published_ctx!(ctx, "k-orphan-only")
      Enum.each(ctx.endpoints, &File.rm_rf!(epoch_path(&1, orphan_ctx.target)))

      assert {:error,
              {:published_proof_failed, :unavailable,
               %{"mode" => "finalize", "verified" => 0, "finalized" => 0, "orphaned" => 6}}} =
               Distributed.finalize_if_current(orphan_ctx, o)

      Enum.each(ctx.endpoints, fn endpoint ->
        assert File.exists?(Path.join(final_dir(endpoint, "k-orphan-only"), "part.0"))
      end)
    end

    # 在受监督进程里按序执行若干步；每步结果以 `{:step, label, result}` 回传，并在收到
    # `{:ack, label}` 前不前进——这让「每步之后单独取证」成为确定性屏障（无 sleep/轮询）。
    # worker 死亡绝不能连坐这个 runner。
    defp run_steps!(id, steps) do
      owner = self()

      runner =
        start_supervised!(
          {Task,
           fn ->
             receive do
               {:go, ^owner} -> :ok
             end

             Enum.each(steps, fn {label, fun} ->
               send(owner, {:step, label, fun.()})

               receive do
                 {:ack, ^label} -> :ok
               after
                 5_000 -> :ok
               end
             end)
           end},
          id: id
        )

      {runner, Process.monitor(runner)}
    end

    defp run_aggregate!(id, fun) do
      {runner, ref} = run_steps!(id, [{:aggregate, fun}])
      send(runner, {:go, self()})
      {runner, ref}
    end

    # worker 与 caller 之间是 nolink，但它必然 link 到 call-scoped `Task.Supervisor`；
    # 因此 worker 的 links 就是识别该 scoped supervisor 的唯一稳定入口（无生产全局状态）。
    # 该 supervisor 必须**不是** runner 本身（那正是被禁止的 linked fan-out 形态），
    # 且其 parent 必须是发起本次调用的 runner——即「每次调用一个」的作用域边界。
    defp scoped_supervisor!(worker, runner) do
      assert {:links, links} = Process.info(worker, :links)
      assert [supervisor] = Enum.filter(links, &is_pid/1)
      refute supervisor == runner

      assert {:dictionary, dictionary} = Process.info(supervisor, :dictionary)
      assert [^runner | _] = Keyword.fetch!(dictionary, :"$ancestors")

      supervisor
    end

    @tag :task2_red_backend
    test "task2 g3: proof worker 被 kill —— runner 存活，归位为该捕获 ordinal 的 unavailable",
         ctx do
      o = opts(ctx)
      :ok = Distributed.put_bucket(@bucket, o)
      proof_ctx = dist_published_ctx!(ctx, "k")

      # 真正的 `Process.exit(self(), :kill)`：`Transport.guarded_call/1` 捕获不到，
      # 只能由 scoped nolink fan-out 的 `{:exit, _}` 分支收敛。
      Recorder.script(2, :kill)

      {runner, ref} =
        run_aggregate!(:proof_kill_runner, fn ->
          Distributed.verify_published(proof_ctx, recorder_opts(ctx))
        end)

      assert_receive {:step, :aggregate,
                      {:ok,
                       {:degraded,
                        %{
                          "required" => 4,
                          "verified" => 5,
                          "unavailable" => 1,
                          "debt" => 1,
                          "degraded" => [detail]
                        } = summary}}}

      assert detail["endpoint"] == "ordinal:2"
      assert detail["class"] == "unavailable"
      assert detail["owned"] == false
      refute inspect(summary) =~ "killed"

      refute Enum.any?(ctx.endpoints, fn {node, drive} ->
               inspect(summary) =~ drive or inspect(summary) =~ Atom.to_string(node)
             end)

      send(runner, {:ack, :aggregate})
      assert_receive {:DOWN, ^ref, :process, ^runner, :normal}
    end

    @tag :task2_red_backend
    test "task2 g3: finalize worker 被 kill —— runner 存活，债务归位到该捕获 ordinal", ctx do
      o = opts(ctx)
      :ok = Distributed.put_bucket(@bucket, o)
      proof_ctx = dist_published_ctx!(ctx, "k")

      Recorder.script(2, :kill)

      {runner, ref} =
        run_aggregate!(:finalize_kill_runner, fn ->
          Distributed.finalize_if_current(proof_ctx, recorder_opts(ctx))
        end)

      assert_receive {:step, :aggregate,
                      {:ok,
                       {:cleanup_pending,
                        %{
                          "mode" => "finalize",
                          "required" => 4,
                          "verified" => 5,
                          "finalized" => 5,
                          "unavailable" => 1,
                          "degraded" => [detail]
                        } = summary}}}

      assert detail["endpoint"] == "ordinal:2"
      assert detail["class"] == "unavailable"
      refute inspect(summary) =~ "killed"

      send(runner, {:ack, :aggregate})
      assert_receive {:DOWN, ^ref, :process, ^runner, :normal}
    end

    # caller 被强杀时 scoped supervisor 随之终止属预期路径，OTP 会记一条 terminating 日志。
    @tag :task2_red_backend
    @tag capture_log: true
    test "task2 g3: caller 死亡时 scoped supervisor 连带清理被阻塞的 worker", ctx do
      o = opts(ctx)
      :ok = Distributed.put_bucket(@bucket, o)
      proof_ctx = dist_published_ctx!(ctx, "k")

      gate = make_ref()
      Recorder.script(1, {:gate, self(), gate, :delegate})

      {runner, runner_ref} =
        run_aggregate!(:caller_death_runner, fn ->
          Distributed.verify_published(proof_ctx, recorder_opts(ctx))
        end)

      assert_receive {:entered, ^gate, 1, worker}
      worker_ref = Process.monitor(worker)
      supervisor = scoped_supervisor!(worker, runner)
      supervisor_ref = Process.monitor(supervisor)

      # 杀掉请求 caller；**绝不**释放 gate，也不 sleep/轮询。
      Process.exit(runner, :kill)

      assert_receive {:DOWN, ^runner_ref, :process, ^runner, :killed}
      assert_receive {:DOWN, ^supervisor_ref, :process, ^supervisor, _reason}
      assert_receive {:DOWN, ^worker_ref, :process, ^worker, _reason}
    end

    @tag :task2_red_backend
    test "task2 g3: 正常完成的 fan-out 结束后 scoped supervisor 已同步停止", ctx do
      o = opts(ctx)
      :ok = Distributed.put_bucket(@bucket, o)
      proof_ctx = dist_published_ctx!(ctx, "k")

      gate = make_ref()
      Recorder.script(0, {:gate, self(), gate, :delegate})

      {runner, runner_ref} =
        run_aggregate!(:lifecycle_runner, fn ->
          Distributed.verify_published(proof_ctx, recorder_opts(ctx))
        end)

      assert_receive {:entered, ^gate, 0, worker}
      supervisor = scoped_supervisor!(worker, runner)
      supervisor_ref = Process.monitor(supervisor)

      send(worker, {:release, gate})
      assert_receive {:completed, ^gate, 0, ^worker}

      assert_receive {:step, :aggregate, {:ok, {:verified, %{"verified" => 6}}}}
      send(runner, {:ack, :aggregate})

      # `try/after` 里的同步 stop：fan-out 一结束，scoped supervisor 必然已经消失。
      assert_receive {:DOWN, ^supervisor_ref, :process, ^supervisor, _reason}
      assert_receive {:DOWN, ^runner_ref, :process, ^runner, :normal}
    end

    @tag :task2_red_backend
    test "task2 g3: 乱序完成不改变归位——高 ordinal 先完成，低 ordinal 仍带自己的 ordinal",
         ctx do
      o = opts(ctx)
      :ok = Distributed.put_bucket(@bucket, o)
      proof_ctx = dist_published_ctx!(ctx, "k")

      owner = self()
      slow = make_ref()
      fast = make_ref()

      # ordinal 1 被闸住；释放后返回完全畸形的外层返回（→ 该 ordinal 的 unavailable）。
      Recorder.script(1, {:gate, owner, slow, {:return, {:ok, :finalized}}})
      # ordinal 5 正常完成并通报——它必然早于被闸住的 ordinal 1 完成。
      Recorder.script(5, {:notify, owner, fast, :delegate})

      {runner, ref} =
        run_aggregate!(:ooo_runner, fn ->
          Distributed.verify_published(proof_ctx, recorder_opts(ctx))
        end)

      # 确定性屏障：无 sleep、无轮询。
      assert_receive {:entered, ^slow, 1, worker}
      assert_receive {:completed, ^fast, 5, _fast_worker}
      refute_received {:completed, ^slow, 1, _}

      send(worker, {:release, slow})
      assert_receive {:completed, ^slow, 1, ^worker}

      assert_receive {:step, :aggregate,
                      {:ok,
                       {:degraded, %{"verified" => 5, "unavailable" => 1, "degraded" => [detail]}}}}

      # 归位只认枚举 ordinal：完成顺序是 5 先于 1，失败标签仍是 ordinal:1。
      assert detail["endpoint"] == "ordinal:1"
      assert detail["class"] == "unavailable"

      send(runner, {:ack, :aggregate})
      assert_receive {:DOWN, ^ref, :process, ^runner, :normal}
    end

    @tag :task2_red_backend
    test "task2 g3: 默认运行时 topology 在 proof 与 finalize 各只捕获一次", ctx do
      :ok = Distributed.put_bucket(@bucket, opts(ctx))
      proof_ctx = dist_published_ctx!(ctx, "k")

      previous = :persistent_term.get({Topology, :topology}, :no_topology)
      Topology.install_runtime!(ctx.topology)

      traced = [
        {Topology, :current, 0},
        {Topology, :ec_params, 0},
        {Placement, :topology_hash_for_opts, 1},
        {Placement, :resolve, 3}
      ]

      Enum.each(traced, &:erlang.trace_pattern(&1, true, [:local]))

      on_exit(fn ->
        Enum.each(traced, &:erlang.trace_pattern(&1, false, [:local]))

        case previous do
          :no_topology -> :persistent_term.erase({Topology, :topology})
          topology -> :persistent_term.put({Topology, :topology}, topology)
        end
      end)

      # 不传 opts[:topology]：走默认运行时 topology 路径。
      runtime_opts = [transport: Recorder]

      {runner, ref} =
        run_steps!(:topology_runner, [
          {:proof, fn -> Distributed.verify_published(proof_ctx, runtime_opts) end},
          {:finalize, fn -> Distributed.finalize_if_current(proof_ctx, runtime_opts) end}
        ])

      :erlang.trace(runner, true, [:call, {:tracer, self()}])
      send(runner, {:go, self()})

      # proof 单独取证。
      assert_receive {:step, :proof, {:ok, {:verified, %{"verified" => 6}}}}
      assert_topology_reads(runner, 1)
      send(runner, {:ack, :proof})

      # finalize 单独取证。
      assert_receive {:step, :finalize, {:ok, {:finalized, %{"finalized" => 6}}}}
      assert_topology_reads(runner, 1)
      send(runner, {:ack, :finalize})

      assert_receive {:DOWN, ^ref, :process, ^runner, :normal}
    end

    # `:erlang.trace_delivered/1` 屏障：确保该 tracee 的全部 trace 消息已投递完毕，
    # 再按 MFA 计数——不靠 `after 0` 排空猜测。
    defp assert_topology_reads(runner, expected_current) do
      calls = drain_traced_calls(runner)

      assert Enum.count(calls, &match?({Topology, :current, _}, &1)) == expected_current
      assert Enum.count(calls, &match?({Topology, :ec_params, _}, &1)) == 0
      assert Enum.count(calls, &match?({Placement, :topology_hash_for_opts, _}, &1)) == 0
      assert Enum.count(calls, &match?({Placement, :resolve, _}, &1)) == 0
    end

    defp drain_traced_calls(pid) do
      delivery = :erlang.trace_delivered(pid)

      receive do
        {:trace_delivered, ^pid, ^delivery} -> :ok
      after
        5_000 -> flunk("trace messages were not delivered for #{inspect(pid)}")
      end

      collect_traced_calls(pid, [])
    end

    defp collect_traced_calls(pid, acc) do
      receive do
        {:trace, ^pid, :call, {module, fun, args}} ->
          collect_traced_calls(pid, [{module, fun, args} | acc])
      after
        0 -> Enum.reverse(acc)
      end
    end

    @tag :task2_red_backend
    test "task2 g3: 畸形显式 topology 绝不抛异常，零 RPC 折叠为脱敏 canonical drift", ctx do
      o = opts(ctx)
      :ok = Distributed.put_bucket(@bucket, o)
      proof_ctx = dist_published_ctx!(ctx, "k")

      malformed = [
        %{},
        %{sets: :bogus},
        %{sets: %{0 => %{endpoints: [{:maxio@n0, "d"}]}}, data_shards: 4},
        %{
          sets: %{0 => %{id: 0, endpoints: :not_a_list, pool_id: 0}},
          data_shards: 4,
          parity_shards: 2,
          block_size: 1024
        }
      ]

      Enum.each(malformed, fn topology ->
        broken_opts = [topology: topology, transport: Recorder]
        Recorder.reset_calls()

        assert {:error,
                {:published_proof_failed, :placement_drift,
                 %{
                   "scope" => "aggregate",
                   "mode" => "proof",
                   "status" => "failed",
                   "verified" => 0,
                   "observed_owned" => 0,
                   "unavailable" => 0,
                   "degraded" => [proof_witness]
                 }}} = Distributed.verify_published(proof_ctx, broken_opts)

        assert proof_witness["endpoint"] == "ordinal:0"
        assert proof_witness["owned"] == false
        assert Recorder.call_count() == 0

        Recorder.reset_calls()

        assert {:error,
                {:published_proof_failed, :placement_drift,
                 %{
                   "mode" => "finalize",
                   "verified" => 0,
                   "finalized" => 0,
                   "orphaned" => 0,
                   "degraded" => [finalize_witness]
                 }}} = Distributed.finalize_if_current(proof_ctx, broken_opts)

        assert finalize_witness["endpoint"] == "ordinal:0"
        assert Recorder.call_count() == 0
      end)
    end

    @tag :task2_red_backend
    test "task2 g3: Distributed Control finalize 闭包捕获带 fingerprint 的 proof 上下文", ctx do
      o = opts(ctx)
      :ok = Distributed.put_bucket(@bucket, o)
      {:ok, _} = Distributed.put(@bucket, "k", "null", ["old-bytes"], o)

      {mctx, put_result} =
        drive_mutation_put(ctx, "k", ["new-bytes"], 1, @id_a, fn _mctx, result -> result end)

      assert {:ok, %{epoch_fingerprint: fingerprint}} = put_result
      assert mctx.published_fingerprint == nil

      Enum.each(ctx.endpoints, fn endpoint ->
        assert %ObjectEpoch{phase: "committed", fingerprint: ^fingerprint} =
                 endpoint_epoch(endpoint, mctx.target)

        refute File.exists?(backup_dir(endpoint, @id_a))
      end)

      assert {:error, :epoch_committed} = Distributed.restore_if_current(mctx, o)
    end
  end
end
