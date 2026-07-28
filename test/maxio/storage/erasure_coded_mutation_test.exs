defmodule Maxio.Storage.ErasureCodedMutationTest do
  # 纯 tmp drives，无 DataCase/Repo：MutationContext 直接以 struct 构造（不经 journal），
  # 对应实现计划 B3 的 EC 后端验收断言。6 盘（4+2）→ write_quorum=4、
  # epoch_quorum=max(4, ⌊6/2⌋+1)=4：容忍 2 盘故障，3 盘故障必须拒绝。
  #
  # async: false —— Task 2 G3 的「重复 drive 预检零端点 I/O」用节点级全局
  # `Maxio.Cluster.DriveIO` 累计计数器取证，必须独占运行才不被并发测试污染。
  use ExUnit.Case, async: false

  alias Maxio.Cluster.{DriveIO, Paths, ShardServer}
  alias Maxio.Storage.{EpochStore, ErasureCoded, MutationBackup, MutationContext, ObjectEpoch}
  alias Maxio.Storage.ObjectCommit.Control

  @bucket "ec-mutation-test"
  @id_a "00000000-0000-0000-0000-00000000000a"
  @id_b "00000000-0000-0000-0000-00000000000b"
  # 同 generation 下 @id_a < @id_x < （gen+1 的）@id_b：交集测试的中间 token。
  @id_x "00000000-0000-0000-0000-00000000000e"

  setup do
    base = Path.join(System.tmp_dir!(), "maxio_ec_mutation_#{System.unique_integer([:positive])}")
    drives = for i <- 0..5, do: Path.join(base, "d#{i}")
    Enum.each(drives, &File.mkdir_p!/1)
    on_exit(fn -> File.rm_rf(base) end)
    {:ok, drives: drives}
  end

  defp opts(drives), do: [drives: drives, data_shards: 4, parity_shards: 2, block_size: 1024]

  defp target(key, version_id \\ "null") do
    {:ok, target} = ObjectEpoch.object_target(@bucket, key, version_id)
    target
  end

  defp token(gen, id) do
    {:ok, token} = ObjectEpoch.token(gen, id)
    token
  end

  defp build_ctx(key, gen, id, previous, version_id) do
    {:ok, final_rel} = Paths.object_rel(@bucket, key, version_id)

    %MutationContext{
      mutation_id: id,
      target: target(key, version_id),
      token: token(gen, id),
      operation: "put",
      authority_mode: "pg",
      backend: "erasure_coded",
      final_rel: final_rel,
      bucket: @bucket,
      key: key,
      version_id: version_id,
      previous_epoch: previous
    }
  end

  defp epoch_payload(nil), do: nil

  defp epoch_payload(%ObjectEpoch{} = epoch) do
    {:ok, payload} = EpochStore.payload(epoch)
    payload
  end

  defp final_dir(drive, key, version_id \\ "null") do
    {:ok, rel} = Paths.object_rel(@bucket, key, version_id)
    Path.join(drive, rel)
  end

  defp backup_dir(drive, id), do: Path.join(drive, MutationBackup.relative_dir(id))

  defp epoch_path(drive, target) do
    {:ok, rel} = ObjectEpoch.relative_path(target)
    Path.join(drive, rel)
  end

  defp body(drives, key, version_id \\ "null") do
    {:ok, stream} = ErasureCoded.get(@bucket, key, version_id, nil, opts(drives))
    stream |> Enum.to_list() |> IO.iodata_to_binary()
  end

  defp temp_empty?(drive) do
    case File.ls(Path.join(drive, ".tmp")) do
      {:ok, []} -> true
      {:error, :enoent} -> true
      _ -> false
    end
  end

  defp snapshot_finals(drives, key, version_id \\ "null") do
    Enum.map(drives, fn drive ->
      final = final_dir(drive, key, version_id)

      {drive, File.read!(Path.join(final, "part.0")), File.read!(Path.join(final, "meta.json"))}
    end)
  end

  defp assert_finals(snapshot, key, version_id \\ "null") do
    Enum.each(snapshot, fn {drive, part, meta} ->
      final = final_dir(drive, key, version_id)
      assert File.read!(Path.join(final, "part.0")) == part
      assert File.read!(Path.join(final, "meta.json")) == meta
    end)
  end

  # 该盘 target 的 durable epoch（per-endpoint 视角，绕过 quorum 裁决取证用）。
  defp drive_epoch(drive, target) do
    case ShardServer.read_epoch(drive, target) do
      {:ok, :absent} ->
        :absent

      {:ok, payload} ->
        {:ok, epoch} = payload |> Jason.encode!() |> ObjectEpoch.decode()
        epoch
    end
  end

  # 直接在指定盘 claim 一个 token（注入 fence / successor 的 per-endpoint 手段）。
  defp claim_on_drives!(drives, target, token) do
    {:ok, claimed} =
      ObjectEpoch.new(target, token, %{
        operation: "put",
        phase: "claimed",
        value_type: "object",
        updated_at: DateTime.utc_now()
      })

    {:ok, payload} = EpochStore.payload(claimed)

    Enum.each(drives, fn drive ->
      assert {:ok, :applied} =
               ShardServer.cas_epoch(drive, %{next: payload, expect: {:claim, token}})
    end)
  end

  # 注入盘级 epoch CAS 失败：直接写坏该盘 epoch.json（EpochStore 读到 corrupt 结构化拒绝，
  # 绝不覆盖——不引入 successor token，避免污染全局裁决）。
  defp corrupt_epoch!(drive, target) do
    path = epoch_path(drive, target)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "{corrupt")
  end

  # 协议化 put 驱动（B5 orchestrator 的 B3 级替身；journal 不在本批范围）：
  # around_object_commit 内 claim →（可选 after_claim 注入）→ publish.(object_mutation: ctx)，
  # publish 结果交给 on_published（其返回值即 around 返回值，驱动 ObjectCommit 收口）。
  defp drive_mutation_put(drives, key, chunks, gen, id, on_published, extra \\ []) do
    o = opts(drives)
    version_id = Keyword.get(extra, :version_id, "null")
    after_claim = Keyword.get(extra, :after_claim, fn _ctx -> :ok end)

    {:ok, current} = ErasureCoded.current_epoch(target(key, version_id), o)
    previous = epoch_payload(epoch_or_nil(current))
    ctx = build_ctx(key, gen, id, previous, version_id)

    around = fn _prepared, publish ->
      assert {:ok, %{previous: claim_previous, endpoints_ok: endpoints_ok}} =
               ErasureCoded.claim_epoch(ctx.target, ctx.token, "put", o)

      assert endpoints_ok >= 4
      assert epoch_payload(claim_previous) == previous

      after_claim.(ctx)
      result = publish.(version_id: version_id, object_meta: %{}, object_mutation: ctx)
      on_published.(ctx, result)
    end

    put_result =
      ErasureCoded.put(
        @bucket,
        key,
        version_id,
        chunks,
        Keyword.put(o, :around_object_commit, around)
      )

    {ctx, put_result}
  end

  defp epoch_or_nil(:absent), do: nil
  defp epoch_or_nil(%ObjectEpoch{} = epoch), do: epoch

  defp sha256_hex(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  defp md5_hex(bytes), do: :crypto.hash(:md5, bytes) |> Base.encode16(case: :lower)

  describe "claim_epoch / current_epoch（quorum 编排）" do
    test "absent → previous=nil、endpoints_ok=6；claim 恒写 phase=claimed 且每盘落盘",
         %{drives: drives} do
      o = opts(drives)
      t = target("claim-fresh")
      assert {:ok, :absent} = ErasureCoded.current_epoch(t, o)

      assert {:ok, %{previous: nil, endpoints_ok: 6}} =
               ErasureCoded.claim_epoch(t, token(1, @id_a), "put", o)

      assert {:ok, %ObjectEpoch{phase: "claimed", previous_token: nil} = epoch} =
               ErasureCoded.current_epoch(t, o)

      assert epoch.token == token(1, @id_a)
      assert epoch.operation == "put"
      assert epoch.value_type == "object"

      # 每盘各有一份 durable epoch（per-endpoint 原语逐盘直调）
      Enum.each(drives, fn drive ->
        assert %ObjectEpoch{phase: "claimed"} = drive_epoch(drive, t)
      end)
    end

    @tag capture_log: true
    test "fence 全序：不更大 token 全盘拒绝 → :write_quorum；successor claim 链 previous",
         %{drives: drives} do
      o = opts(drives)
      t = target("claim-fence")
      assert {:ok, _} = ErasureCoded.claim_epoch(t, token(1, @id_b), "put", o)

      # 同 token 重复 claim 与同 generation 更小 mutation_id 均被全盘 fence 拒绝
      assert {:error, :write_quorum} = ErasureCoded.claim_epoch(t, token(1, @id_b), "put", o)
      assert {:error, :write_quorum} = ErasureCoded.claim_epoch(t, token(1, @id_a), "put", o)

      assert {:ok, %{previous: %ObjectEpoch{} = previous, endpoints_ok: 6}} =
               ErasureCoded.claim_epoch(t, token(2, @id_a), "put", o)

      assert previous.token == token(1, @id_b)

      assert {:ok, %ObjectEpoch{phase: "claimed", previous_token: prev_tok}} =
               ErasureCoded.current_epoch(t, o)

      assert prev_tok == token(1, @id_b)
    end

    @tag capture_log: true
    test "2 盘损坏仍可裁决且 claim 达 quorum；3 盘损坏 → epoch_quorum_unavailable",
         %{drives: drives} do
      o = opts(drives)
      t = target("claim-corrupt")
      assert {:ok, _} = ErasureCoded.claim_epoch(t, token(1, @id_a), "put", o)

      [d0, d1, d2 | _rest] = drives
      corrupt_epoch!(d0, t)
      corrupt_epoch!(d1, t)

      # 可读盘 4 >= epoch_quorum：裁决通过；claim oks=4 恰达 quorum，损坏盘绝不被覆盖
      assert {:ok, %ObjectEpoch{token: tok}} = ErasureCoded.current_epoch(t, o)
      assert tok == token(1, @id_a)

      assert {:ok, %{endpoints_ok: 4}} = ErasureCoded.claim_epoch(t, token(2, @id_a), "put", o)
      assert File.read!(epoch_path(d0, t)) == "{corrupt"
      assert File.read!(epoch_path(d1, t)) == "{corrupt"

      # 第 3 盘损坏：可读盘 3 < 4 → 读裁决与 claim 均拒绝（不猜测）
      corrupt_epoch!(d2, t)
      assert {:error, :epoch_quorum_unavailable} = ErasureCoded.current_epoch(t, o)

      assert {:error, :epoch_quorum_unavailable} =
               ErasureCoded.claim_epoch(t, token(3, @id_a), "put", o)
    end
  end

  describe "协议化 put（publish 分支，quorum 门）" do
    # B3 断言 1（B2 断言 1+2 语义）：published 中间态五要素 + finalize 收口 + 幂等。
    test "overwrite：published 中间态 + finalize 收口 + 幂等", %{drives: drives} do
      o = opts(drives)
      :ok = ErasureCoded.put_bucket(@bucket, o)
      {:ok, _} = ErasureCoded.put(@bucket, "k", "null", ["old-bytes"], o)
      old = snapshot_finals(drives, "k")

      {ctx, put_result} =
        drive_mutation_put(drives, "k", ["new-bytes"], 1, @id_a, fn ctx, result ->
          # publish 返回即「published 中间态」：rename 已完成、finalize 尚未发生。
          assert {:ok, %{epoch_fingerprint: fingerprint}} = result

          assert {:ok, %ObjectEpoch{phase: "published"} = epoch} =
                   ErasureCoded.current_epoch(ctx.target, o)

          assert epoch.fingerprint == fingerprint
          assert fingerprint["etag"] == md5_hex("new-bytes")
          assert fingerprint["size"] == byte_size("new-bytes")

          # 对象级读已见新字节；每盘 final meta.json 字节与 fingerprint 精确匹配，
          # backup 含 manifest + 旧 part.0/meta.json（逐字节）。
          assert body(drives, "k") == "new-bytes"

          Enum.each(old, fn {drive, old_part, old_meta} ->
            final = final_dir(drive, "k")
            final_meta = File.read!(Path.join(final, "meta.json"))
            assert fingerprint["sidecar_sha256"] == sha256_hex(final_meta)

            backup = backup_dir(drive, @id_a)

            assert {:ok, manifest} =
                     MutationBackup.decode(File.read!(Path.join(backup, "manifest.json")))

            assert Enum.sort(MutationBackup.entry_names(manifest)) == ["meta.json", "part.0"]
            assert manifest.token == ctx.token
            assert manifest.previous_token == nil
            assert File.read!(Path.join(backup, "part.0")) == old_part
            assert File.read!(Path.join(backup, "meta.json")) == old_meta
          end)

          result
        end)

      assert {:ok, %{epoch_fingerprint: fingerprint}} = put_result

      # put 成功收口：Control.finalize → finalize_if_current → epoch=committed、backup 消失
      assert {:ok, %ObjectEpoch{phase: "committed"}} = ErasureCoded.current_epoch(ctx.target, o)
      Enum.each(drives, fn drive -> refute File.exists?(backup_dir(drive, @id_a)) end)
      assert body(drives, "k") == "new-bytes"
      assert Enum.all?(drives, &temp_empty?/1)

      # 重复 finalize 幂等（proof-aware：committed 重放必须先复验才收敛）
      proof_ctx = %MutationContext{ctx | published_fingerprint: fingerprint}

      assert {:ok, {:finalized, %{"status" => "finalized", "verified" => 6, "finalized" => 6}}} =
               ErasureCoded.finalize_if_current(proof_ctx, o)

      assert {:ok, %ObjectEpoch{phase: "committed"}} = ErasureCoded.current_epoch(ctx.target, o)

      # committed 后 restore 被 quorum 级防线拒绝（metadata_committed 禁回滚落点）
      assert {:error, :epoch_committed} = ErasureCoded.restore_if_current(ctx, o)
      assert body(drives, "k") == "new-bytes"
    end

    # B3 断言 1（B2 断言 3 语义）：metadata 失败 → Control rollback → 每盘旧值逐字节恢复。
    test "metadata 失败：Control rollback → restore_if_current 每盘逐字节恢复旧值",
         %{drives: drives} do
      o = opts(drives)
      :ok = ErasureCoded.put_bucket(@bucket, o)
      {:ok, _} = ErasureCoded.put(@bucket, "k", "null", ["old-bytes"], o)
      old = snapshot_finals(drives, "k")

      {ctx, put_result} =
        drive_mutation_put(drives, "k", ["new-bytes"], 1, @id_a, fn _ctx, result ->
          assert {:ok, _} = result
          {:error, :metadata_commit_failed}
        end)

      assert {:error, :metadata_commit_failed} = put_result
      assert_finals(old, "k")
      assert body(drives, "k") == "old-bytes"

      assert {:ok, %ObjectEpoch{phase: "rolled_back"}} =
               ErasureCoded.current_epoch(ctx.target, o)

      Enum.each(drives, fn drive -> refute File.exists?(backup_dir(drive, @id_a)) end)
      assert Enum.all?(drives, &temp_empty?/1)
    end

    test "fresh metadata 失败：exact-current quorum 删除 final 并收敛 rolled_back",
         %{drives: drives} do
      o = opts(drives)
      :ok = ErasureCoded.put_bucket(@bucket, o)
      version_id = "fresh-v1"

      {ctx, put_result} =
        drive_mutation_put(
          drives,
          "fresh",
          ["fresh-bytes"],
          1,
          @id_a,
          fn _ctx, result ->
            assert {:ok, _} = result
            {:error, :metadata_commit_failed}
          end,
          version_id: version_id
        )

      assert {:error, :metadata_commit_failed} = put_result

      assert {:ok, %ObjectEpoch{phase: "rolled_back"}} =
               ErasureCoded.current_epoch(ctx.target, o)

      Enum.each(drives, fn drive ->
        refute File.exists?(final_dir(drive, "fresh", version_id))
        refute File.exists?(backup_dir(drive, @id_a))
        assert %ObjectEpoch{phase: "rolled_back", token: token} = drive_epoch(drive, ctx.target)
        assert token == ctx.token
      end)
    end

    @tag capture_log: true
    test "fresh restore 低于 quorum：返回 partial，已授权盘删除，失败盘保留恢复证据",
         %{drives: drives} do
      o = opts(drives)
      :ok = ErasureCoded.put_bucket(@bucket, o)
      [d0, d1, d2, d3, d4, d5] = drives

      {_ctx, put_result} =
        drive_mutation_put(drives, "fresh-partial", ["fresh-bytes"], 1, @id_a, fn ctx, result ->
          assert {:ok, _} = result

          Enum.each([d3, d4, d5], fn drive ->
            File.write!(Path.join(backup_dir(drive, @id_a), "manifest.json"), "{corrupt")
          end)

          assert {:error,
                  {:partial, %{applied: 3, superseded: 0, epoch_quorum: 4, errors: errors}}} =
                   ErasureCoded.restore_if_current(ctx, o)

          assert length(errors) == 3

          Enum.each([d0, d1, d2], fn drive ->
            refute File.exists?(final_dir(drive, "fresh-partial"))
            refute File.exists?(backup_dir(drive, @id_a))
            assert %ObjectEpoch{phase: "rolled_back"} = drive_epoch(drive, ctx.target)
          end)

          Enum.each([d3, d4, d5], fn drive ->
            assert File.regular?(Path.join(final_dir(drive, "fresh-partial"), "part.0"))
            assert File.read!(Path.join(backup_dir(drive, @id_a), "manifest.json")) == "{corrupt"
            assert %ObjectEpoch{phase: "published"} = drive_epoch(drive, ctx.target)
          end)

          {:error, :metadata_commit_failed}
        end)

      assert {:error, :metadata_commit_failed} = put_result
    end

    # B3 断言 2（通过半）：2 盘 epoch CAS 失败 → oks=4 >= epoch_quorum，publish/finalize
    # 照常收口；损坏盘的 epoch 与 backup 原样保留（不猜测、不破坏）。
    @tag capture_log: true
    test "publish CAS 2 盘失败：quorum 通过，finalize 不触损坏盘", %{drives: drives} do
      o = opts(drives)
      :ok = ErasureCoded.put_bucket(@bucket, o)
      {:ok, _} = ErasureCoded.put(@bucket, "k", "null", ["old-bytes"], o)
      [_d0, _d1, _d2, _d3, d4, d5] = drives

      inject = fn ctx ->
        corrupt_epoch!(d4, ctx.target)
        corrupt_epoch!(d5, ctx.target)
      end

      {ctx, put_result} =
        drive_mutation_put(
          drives,
          "k",
          ["new-bytes"],
          1,
          @id_a,
          fn _ctx, result ->
            assert {:ok, %{epoch_fingerprint: _}} = result
            result
          end,
          after_claim: inject
        )

      assert {:ok, %{epoch_fingerprint: _}} = put_result

      # 4 健康盘收口 committed；K=4 分片仍可重建新字节
      assert {:ok, %ObjectEpoch{phase: "committed"}} = ErasureCoded.current_epoch(ctx.target, o)
      assert body(drives, "k") == "new-bytes"

      # 损坏盘：epoch 字节原样（绝不覆盖）、backup + manifest 保留（finalize 拒绝损坏盘）
      Enum.each([d4, d5], fn drive ->
        assert File.read!(epoch_path(drive, ctx.target)) == "{corrupt"
        assert File.exists?(Path.join(backup_dir(drive, @id_a), "manifest.json"))
        assert File.exists?(Path.join(backup_dir(drive, @id_a), "part.0"))
      end)

      # 健康盘 backup 已被 finalize 丢弃
      Enum.each(Enum.take(drives, 4), fn drive ->
        refute File.exists?(backup_dir(drive, @id_a))
      end)

      # committed 后 restore 仍被拒绝
      assert {:error, :epoch_committed} = ErasureCoded.restore_if_current(ctx, o)
    end

    # B3 断言 2（拒绝半）：3 盘 epoch CAS 失败 → oks=3 < epoch_quorum → publish 拒绝、
    # 新字节绝不 rename 进 final、每盘 backup + manifest 保留（quorum 不足不破坏落点）。
    @tag capture_log: true
    test "publish CAS 3 盘失败：publish 拒绝、final 未 rename、backup 保留", %{drives: drives} do
      o = opts(drives)
      :ok = ErasureCoded.put_bucket(@bucket, o)
      {:ok, _} = ErasureCoded.put(@bucket, "k", "null", ["old-bytes"], o)
      old = snapshot_finals(drives, "k")
      [_d0, _d1, _d2, d3, d4, d5] = drives

      inject = fn ctx ->
        corrupt_epoch!(d3, ctx.target)
        corrupt_epoch!(d4, ctx.target)
        corrupt_epoch!(d5, ctx.target)
      end

      {ctx, put_result} =
        drive_mutation_put(
          drives,
          "k",
          ["new-bytes"],
          1,
          @id_a,
          fn _ctx, result -> result end,
          after_claim: inject
        )

      assert {:error, {:epoch_publish_quorum, %{endpoints_ok: 3, epoch_quorum: 4}}} = put_result

      Enum.each(old, fn {drive, old_part, old_meta} ->
        final = final_dir(drive, "k")
        backup = backup_dir(drive, @id_a)

        # 新字节未 rename 进 final（旧值已在 durable backup，收敛交给 recovery）
        refute File.regular?(Path.join(final, "part.0"))
        refute File.regular?(Path.join(final, "meta.json"))

        assert {:ok, _manifest} =
                 MutationBackup.decode(File.read!(Path.join(backup, "manifest.json")))

        assert File.read!(Path.join(backup, "part.0")) == old_part
        assert File.read!(Path.join(backup, "meta.json")) == old_meta
      end)

      # 3 盘损坏 → 全局裁决不可用：Control rollback 的 restore 不猜测、不破坏
      assert {:error, :epoch_quorum_unavailable} = ErasureCoded.restore_if_current(ctx, o)
      assert Enum.all?(drives, &temp_empty?/1)
    end

    # B3 断言 3（本批核心，quorum intersection）：A 在 {d0..d3} 达 quorum published；
    # B claim 在 {d2..d5} 达 quorum → A 的 restore 全局裁决读到 B（交集盘 d2/d3）→
    # :superseded，d0/d1 上 A 的旧 epoch / final / backup 不被 A 的恢复动作触碰。
    @tag capture_log: true
    test "quorum intersection：A 的迟到 restore 全局裁决 :superseded，d0/d1 不被触碰",
         %{drives: drives} do
      o = opts(drives)
      :ok = ErasureCoded.put_bucket(@bucket, o)
      {:ok, _} = ErasureCoded.put(@bucket, "k", "null", ["old-bytes"], o)
      [d0, d1, d2, d3, d4, d5] = drives
      t = target("k")

      # 先把中间 token X（gen 同 A、mutation_id 更大）钉在 d4/d5：A 的 claim/publish 在
      # 这两盘被 fence，A 恰好只在 {d0..d3} 达 quorum。
      claim_on_drives!([d4, d5], t, token(1, @id_x))

      {_ctx, put_result} =
        drive_mutation_put(drives, "k", ["a-bytes"], 1, @id_a, fn ctx_a, result ->
          assert {:ok, %{epoch_fingerprint: _}} = result

          # A published 在 {d0..d3}；d4/d5 仍是 X 的 claimed
          Enum.each([d0, d1, d2, d3], fn drive ->
            assert %ObjectEpoch{phase: "published", token: tok} = drive_epoch(drive, t)
            assert tok == token(1, @id_a)
          end)

          # B（gen+1）在 {d2..d5} 逐盘合法 claim（per-endpoint CAS 接受严格更大 token），
          # 4 盘 = epoch_quorum：B 的 claim quorum 与 A 的 publish quorum 交集 = {d2,d3}。
          claim_on_drives!([d2, d3, d4, d5], t, token(2, @id_b))

          snapshot =
            Enum.map([d0, d1], fn drive ->
              backup = backup_dir(drive, @id_a)

              %{
                drive: drive,
                epoch: File.read!(epoch_path(drive, t)),
                part: File.read!(Path.join(final_dir(drive, "k"), "part.0")),
                meta: File.read!(Path.join(final_dir(drive, "k"), "meta.json")),
                backup_manifest: File.read!(Path.join(backup, "manifest.json")),
                backup_part: File.read!(Path.join(backup, "part.0")),
                backup_meta: File.read!(Path.join(backup, "meta.json"))
              }
            end)

          # A 的迟到 restore：全局裁决读到交集盘上的 B → 整体 :superseded，任何盘不动
          assert {:ok, :superseded} = ErasureCoded.restore_if_current(ctx_a, o)

          Enum.each(snapshot, fn snap ->
            backup = backup_dir(snap.drive, @id_a)
            assert File.read!(epoch_path(snap.drive, t)) == snap.epoch
            assert File.read!(Path.join(final_dir(snap.drive, "k"), "part.0")) == snap.part
            assert File.read!(Path.join(final_dir(snap.drive, "k"), "meta.json")) == snap.meta
            assert File.read!(Path.join(backup, "manifest.json")) == snap.backup_manifest
            assert File.read!(Path.join(backup, "part.0")) == snap.backup_part
            assert File.read!(Path.join(backup, "meta.json")) == snap.backup_meta
          end)

          # B 的 claimed epoch 不被 A 触碰
          Enum.each([d2, d3, d4, d5], fn drive ->
            assert %ObjectEpoch{phase: "claimed", token: tok} = drive_epoch(drive, t)
            assert tok == token(2, @id_b)
          end)

          {:error, :stale_owner}
        end)

      # A 的 Control rollback 重放同样 :superseded：d0/d1 三态仍不变
      assert {:error, :stale_owner} = put_result

      Enum.each([d0, d1], fn drive ->
        assert %ObjectEpoch{phase: "published", token: tok} = drive_epoch(drive, t)
        assert tok == token(1, @id_a)
        assert File.exists?(Path.join(backup_dir(drive, @id_a), "manifest.json"))
      end)

      Enum.each([d2, d3, d4, d5], fn drive ->
        assert %ObjectEpoch{token: tok} = drive_epoch(drive, t)
        assert tok == token(2, @id_b)
      end)
    end

    # B3 断言 1（B2 断言 4 语义）：A published 后 B 完整协议 put（gen+1）走完并收口，
    # A 的迟到 restore → :superseded，B 的 final/epoch 逐字节不变、A 的 backup 保留。
    test "full successor：A 的迟到 restore → :superseded，绝不触碰 B", %{drives: drives} do
      o = opts(drives)
      :ok = ErasureCoded.put_bucket(@bucket, o)
      {:ok, _} = ErasureCoded.put(@bucket, "k", "null", ["old-bytes"], o)

      {_ctx_a, put_result} =
        drive_mutation_put(drives, "k", ["a-bytes"], 1, @id_a, fn ctx_a, result ->
          assert {:ok, _} = result

          # A published（未 finalize）之下，B 走完整协议 put（gen+1）并收口 committed
          {_ctx_b, b_result} =
            drive_mutation_put(drives, "k", ["b-bytes"], 2, @id_b, fn _ctx_b, r -> r end)

          assert {:ok, _} = b_result

          assert {:ok, %ObjectEpoch{phase: "committed", token: tok_b}} =
                   ErasureCoded.current_epoch(ctx_a.target, o)

          assert tok_b == token(2, @id_b)
          b_finals = snapshot_finals(drives, "k")
          assert body(drives, "k") == "b-bytes"

          # A 的迟到 restore：只报告 superseded，B 的 final/epoch 不动，A 的 backup 保留
          assert {:ok, :superseded} = ErasureCoded.restore_if_current(ctx_a, o)
          assert_finals(b_finals, "k")

          assert {:ok, %ObjectEpoch{phase: "committed", token: ^tok_b}} =
                   ErasureCoded.current_epoch(ctx_a.target, o)

          Enum.each(drives, fn drive ->
            assert File.exists?(Path.join(backup_dir(drive, @id_a), "manifest.json"))
          end)

          {:error, :stale_owner}
        end)

      assert {:error, :stale_owner} = put_result
      assert body(drives, "k") == "b-bytes"

      assert {:ok, %ObjectEpoch{token: tok}} = ErasureCoded.current_epoch(target("k"), o)
      assert tok == token(2, @id_b)

      Enum.each(drives, fn drive ->
        assert File.exists?(Path.join(backup_dir(drive, @id_a), "manifest.json"))
      end)
    end
  end

  describe "restore_if_current / finalize_if_current（全局裁决防线）" do
    test "epoch 全盘 absent：restore → :epoch_missing，绝不删任何字节", %{drives: drives} do
      o = opts(drives)
      :ok = ErasureCoded.put_bucket(@bucket, o)
      {:ok, _} = ErasureCoded.put(@bucket, "k", "null", ["old-bytes"], o)
      old = snapshot_finals(drives, "k")

      ctx = build_ctx("k", 1, @id_a, nil, "null")
      assert {:error, :epoch_missing} = ErasureCoded.restore_if_current(ctx, o)

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
               }}} = ErasureCoded.finalize_if_current(ctx, o)

      assert Enum.all?(details, &(&1["class"] == "corrupt" and &1["owned"] == false))
      assert_finals(old, "k")
    end
  end

  describe "非协议路径回归切片" do
    # B3 断言 4（切片）：无协议 opts 的 put 不落协议根、不写 epoch（全量回归由
    # erasure_coded_test + erasure_coded_conformance_test 把关）。
    test "非协议 put：不落 .maxio-object-mutations / .maxio-object-epochs", %{drives: drives} do
      o = opts(drives)
      :ok = ErasureCoded.put_bucket(@bucket, o)
      {:ok, _} = ErasureCoded.put(@bucket, "plain", "null", ["bytes-1"], o)
      # overwrite 路径（plan_object_backups 的 .tmp 备份）同样不触协议根
      {:ok, _} = ErasureCoded.put(@bucket, "plain", "null", ["bytes-2"], o)

      Enum.each(drives, fn drive ->
        refute File.exists?(Path.join(drive, ".maxio-object-mutations"))
        refute File.exists?(Path.join(drive, ".maxio-object-epochs"))
      end)

      assert {:ok, :absent} = ErasureCoded.current_epoch(target("plain"), o)
      assert Enum.all?(drives, &temp_empty?/1)
    end

    test "object_mutation 非 MutationContext：结构化拒绝，旧 final 不动", %{drives: drives} do
      o = opts(drives)
      :ok = ErasureCoded.put_bucket(@bucket, o)
      {:ok, _} = ErasureCoded.put(@bucket, "k", "null", ["old-bytes"], o)
      old = snapshot_finals(drives, "k")

      around = fn _prepared, publish ->
        publish.(version_id: "null", object_meta: %{}, object_mutation: :bogus)
      end

      assert {:error, {:invalid_object_mutation, :bogus}} =
               ErasureCoded.put(
                 @bucket,
                 "k",
                 "null",
                 ["new"],
                 Keyword.put(o, :around_object_commit, around)
               )

      assert_finals(old, "k")
      assert Enum.all?(drives, &temp_empty?/1)
    end

    # Phase 2A C1（B3 审查项 3）：commit_object_replace 非 quorum 错误的窄 case 收口。
    # 注入手段：around 内预占 Control 注册位 → 非协议 publish 的 commit_object_replace
    # 内 Control.register 必然 {:error, :already_registered}（收口前为 CaseClauseError
    # 裸崩）；:write_quorum 形状不变（上方既有 quorum 测试把关）。
    @tag capture_log: true
    test "commit_object_replace 非 quorum 错误 → 结构化 {:error, {:commit_failed, _}}，旧 final 不动",
         %{drives: drives} do
      o = opts(drives)
      :ok = ErasureCoded.put_bucket(@bucket, o)
      {:ok, _} = ErasureCoded.put(@bucket, "k", "null", ["old-bytes"], o)
      old = snapshot_finals(drives, "k")

      around = fn prepared, publish ->
        control = Map.fetch!(prepared, :object_commit_control)
        identity = Map.fetch!(prepared, :object_commit_identity)
        :ok = Control.register(control, identity, fn -> :ok end, fn -> :ok end)
        publish.(version_id: "null", object_meta: %{})
      end

      assert {:error, {:commit_failed, :already_registered}} =
               ErasureCoded.put(
                 @bucket,
                 "k",
                 "null",
                 ["new"],
                 Keyword.put(o, :around_object_commit, around)
               )

      # 旧 final 逐字节不动、对象仍可读（错误发生在任何破坏性 rename 之前）
      assert_finals(old, "k")
      assert body(drives, "k") == "old-bytes"
    end
  end

  describe "Task 2 backend proof aggregation（RED）" do
    # 6 盘 4+2 → epoch_quorum = 4。
    defp ec_published_ctx!(drives, key) do
      {ctx, {:ok, %{epoch_fingerprint: fingerprint}}} =
        drive_mutation_put(drives, key, ["new-bytes"], 1, @id_a, fn _ctx, result -> result end)

      %MutationContext{ctx | published_fingerprint: fingerprint}
    end

    defp ec_break_meta!(drive, key) do
      meta = Path.join(final_dir(drive, key), "meta.json")
      File.write!(meta, File.read!(meta) <> "\n")
    end

    @tag :task2_red_backend
    test "task2 red: EC verify_published reaches exact quorum over immutable drive ordinals",
         %{drives: drives} do
      o = opts(drives)
      :ok = ErasureCoded.put_bucket(@bucket, o)
      proof_ctx = ec_published_ctx!(drives, "k")

      assert function_exported?(ErasureCoded, :verify_published, 2)

      assert {:ok,
              {:verified,
               %{
                 "scope" => "aggregate",
                 "mode" => "proof",
                 "status" => "verified",
                 "required" => 4,
                 "verified" => 6,
                 "observed_owned" => 6,
                 "unavailable" => 0,
                 "debt" => 0,
                 "degraded" => [],
                 "omitted" => 0
               } = summary}} = ErasureCoded.verify_published(proof_ctx, o)

      refute Enum.any?(~w(path root drive node), &Map.has_key?(summary, &1))
      refute Enum.any?(drives, &(inspect(summary) =~ &1))
    end

    @tag :task2_red_backend
    test "task2 red: EC minority failure degrades while below-quorum failure is global",
         %{drives: drives} do
      o = opts(drives)
      :ok = ErasureCoded.put_bucket(@bucket, o)

      degraded_ctx = ec_published_ctx!(drives, "k-degraded")
      ec_break_meta!(Enum.at(drives, 5), "k-degraded")

      assert {:ok,
              {:degraded,
               %{
                 "scope" => "aggregate",
                 "status" => "degraded",
                 "required" => 4,
                 "verified" => 5,
                 "debt" => 1,
                 "degraded" => [detail]
               }}} = ErasureCoded.verify_published(degraded_ctx, o)

      # 少数派证据只暴露冻结 ordinal，不含 node/drive/路径。
      assert detail["endpoint"] == "ordinal:5"
      assert detail["class"] == "mismatch"
      refute Enum.any?(~w(path drive node), &Map.has_key?(detail, &1))

      failed_ctx = ec_published_ctx!(drives, "k-below")
      Enum.each([3, 4, 5], &ec_break_meta!(Enum.at(drives, &1), "k-below"))

      assert {:error,
              {:published_proof_failed, :mismatch,
               %{"scope" => "aggregate", "status" => "failed", "verified" => 3, "required" => 4}}} =
               ErasureCoded.verify_published(failed_ctx, o)
    end

    @tag :task2_red_backend
    test "task2 red: EC successor outranks minority degradation", %{drives: drives} do
      o = opts(drives)
      :ok = ErasureCoded.put_bucket(@bucket, o)
      proof_ctx = ec_published_ctx!(drives, "k")

      ec_break_meta!(Enum.at(drives, 4), "k")
      claim_on_drives!([Enum.at(drives, 5)], proof_ctx.target, token(2, @id_b))

      assert {:ok,
              {:superseded,
               %{
                 "scope" => "aggregate",
                 "mode" => "proof",
                 "status" => "superseded",
                 "verified" => 0,
                 "observed_owned" => 0,
                 "unavailable" => 0
               }}} = ErasureCoded.verify_published(proof_ctx, o)
    end

    @tag :task2_red_backend
    test "task2 red: EC finalize distinguishes finalized, cleanup debt and orphan hints",
         %{drives: drives} do
      o = opts(drives)
      :ok = ErasureCoded.put_bucket(@bucket, o)

      terminal_ctx = ec_published_ctx!(drives, "k-terminal")

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
               }}} = ErasureCoded.finalize_if_current(terminal_ctx, o)

      # 少数派仍未证明/清理 → proof quorum 已过但保留 durable cleanup debt。
      debt_ctx = ec_published_ctx!(drives, "k-debt")
      ec_break_meta!(Enum.at(drives, 5), "k-debt")

      assert {:ok,
              {:cleanup_pending,
               %{"scope" => "aggregate", "status" => "cleanup_pending", "verified" => 5}} =
                {_outcome, cleanup}} = ErasureCoded.finalize_if_current(debt_ctx, o)

      assert cleanup["debt"] >= 1

      # 该端点的 backup/manifest 残留绝不被删除。
      assert File.exists?(Path.join(final_dir(Enum.at(drives, 5), "k-debt"), "meta.json"))

      # epoch absent 的端点只产生有界 orphan hint，不投票、不计 debt、不授权删除。
      orphan_ctx = ec_published_ctx!(drives, "k-orphan")
      orphan_drive = Enum.at(drives, 5)
      File.rm_rf!(epoch_path(orphan_drive, orphan_ctx.target))

      assert {:ok,
              {:finalized,
               %{
                 "status" => "finalized",
                 "verified" => 5,
                 "finalized" => 5,
                 "debt" => 0,
                 "orphaned" => 1,
                 "orphan_hints" => [hint],
                 "orphan_omitted" => 0
               }}} = ErasureCoded.finalize_if_current(orphan_ctx, o)

      assert hint["status"] == "orphan"
      assert hint["orphan_reason"] == "epoch_absent"
      assert hint["endpoint"] == "ordinal:5"
      assert File.exists?(Path.join(final_dir(orphan_drive, "k-orphan"), "part.0"))
    end

    @tag :task2_red_backend
    test "task2 control: EC publish writes a quorum of epochs and per-drive backups", %{
      drives: drives
    } do
      o = opts(drives)
      :ok = ErasureCoded.put_bucket(@bucket, o)
      {:ok, _} = ErasureCoded.put(@bucket, "k", "null", ["old-bytes"], o)

      {ctx, put_result} =
        drive_mutation_put(drives, "k", ["new-bytes"], 1, @id_a, fn _ctx, result ->
          assert {:ok, %{epoch_fingerprint: fingerprint}} = result
          assert is_map(fingerprint)
          result
        end)

      assert {:ok, %{epoch_fingerprint: _fingerprint}} = put_result

      committed =
        Enum.count(drives, fn drive ->
          match?(%ObjectEpoch{phase: "committed"}, drive_epoch(drive, ctx.target))
        end)

      assert committed >= 4
    end
  end

  describe "Task 2 G3 EC 聚合接线（RED）" do
    # 冻结 drive 向量的重复项：置换 d5 为 d4，长度仍为 K+M（Config 校验通过），但两个
    # ordinal 指向同一物理 drive。缺少 preflight 时两个 ordinal 都会各自 verified，
    # 冒充 6/4 quorum；正确实现必须在任何端点 IO 之前折叠为 canonical placement drift。
    defp duplicate_drive_opts(drives) do
      opts(List.replace_at(drives, 5, Enum.at(drives, 4)))
    end

    # 把某盘的同 token epoch 强制回退为 claimed（finalize-only repair 的入口条件）。
    defp force_claimed_epoch!(drive, ctx) do
      {:ok, claimed} =
        ObjectEpoch.new(ctx.target, ctx.token, %{
          operation: "put",
          phase: "claimed",
          value_type: "object",
          updated_at: DateTime.utc_now()
        })

      assert {:ok, :applied} =
               EpochStore.cas(drive, claimed, {:exact, ctx.token, ["published", "committed"]})
    end

    defp heal_final_from!(source_drive, target_drive, key) do
      source = final_dir(source_drive, key)
      target = final_dir(target_drive, key)
      File.mkdir_p!(target)

      Enum.each(["meta.json", "part.0"], fn name ->
        File.write!(Path.join(target, name), File.read!(Path.join(source, name)))
      end)
    end

    @tag :task2_red_backend
    test "task2 g3: EC 重复 drive term 在任何端点 IO 之前折叠为 canonical placement drift",
         %{drives: drives} do
      o = opts(drives)
      :ok = ErasureCoded.put_bucket(@bucket, o)
      proof_ctx = ec_published_ctx!(drives, "k")
      dup = duplicate_drive_opts(drives)

      # 直接零 I/O 取证：`ShardServer.verify_mutation/finalize_mutation` 分别经
      # `DriveIO.track(:read | :write, ...)`，故 read_ops/write_ops 是端点原语是否被调用的
      # 直接证据（proof 只读、committed finalize 幂等，epoch 前后快照不是有效 oracle）。
      on_exit(&DriveIO.reset/0)

      # 正向校准：先证明健康路径确实各留下 6 次可计数的端点操作，
      # 否则「重复预检 0 次」可能只是计数器本身没在工作。
      DriveIO.reset()
      assert {:ok, {:verified, %{"verified" => 6}}} = ErasureCoded.verify_published(proof_ctx, o)
      assert DriveIO.snapshot().read_ops == 6

      DriveIO.reset()

      assert {:ok, {:finalized, %{"finalized" => 6}}} =
               ErasureCoded.finalize_if_current(proof_ctx, o)

      assert DriveIO.snapshot().write_ops == 6

      DriveIO.reset()

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
               }}} = ErasureCoded.verify_published(proof_ctx, dup)

      proof_io = DriveIO.snapshot()
      assert proof_io.read_ops == 0
      assert proof_io.write_ops == 0
      assert proof_io.completed_ops == 0

      # 有界脱敏 witness：shard 域身份（绝不用 FS 专属的 "local"）、非 owned、
      # 且不含任何 drive/node/路径。
      assert witness["endpoint"] == "ordinal:0"
      assert witness["owned"] == false
      assert witness["class"] == "placement_drift"
      assert witness["scope"] == "endpoint"
      refute Enum.any?(drives, &(inspect(witness) =~ &1))

      DriveIO.reset()

      assert {:error,
              {:published_proof_failed, :placement_drift,
               %{"finalized" => 0, "degraded" => [finalize_witness]}}} =
               ErasureCoded.finalize_if_current(proof_ctx, dup)

      finalize_io = DriveIO.snapshot()
      assert finalize_io.read_ops == 0
      assert finalize_io.write_ops == 0
      assert finalize_io.completed_ops == 0
      assert finalize_witness["endpoint"] == "ordinal:0"
      assert finalize_witness["owned"] == false
    end

    @tag :task2_red_backend
    test "task2 g3: EC 少数派 unavailable 按冻结 ordinal 归位且不泄漏路径/原始原因",
         %{drives: drives} do
      o = opts(drives)
      :ok = ErasureCoded.put_bucket(@bucket, o)
      proof_ctx = ec_published_ctx!(drives, "k")

      # 确定性的真实 unavailable（不是 mismatch）：把该盘的 epoch 文件替换成目录，
      # epoch 读取返回 :eisdir/:eacces 等瞬时 IO 失败 → D6 分类为 :unavailable。
      down_drive = Enum.at(drives, 5)
      epoch_file = epoch_path(down_drive, proof_ctx.target)
      File.rm_rf!(epoch_file)
      File.mkdir_p!(epoch_file)

      assert {:ok,
              {:degraded,
               %{
                 "scope" => "aggregate",
                 "mode" => "proof",
                 "status" => "degraded",
                 "required" => 4,
                 "verified" => 5,
                 "unavailable" => 1,
                 "debt" => 1,
                 "degraded" => [detail]
               }}} = ErasureCoded.verify_published(proof_ctx, o)

      assert detail["endpoint"] == "ordinal:5"
      assert detail["class"] == "unavailable"
      assert detail["owned"] == false
      assert detail["code"] == "epoch_unavailable"
      refute Enum.any?(~w(path drive node), &Map.has_key?(detail, &1))
      refute inspect(detail) =~ down_drive
      refute inspect(detail) =~ "eisdir"
      refute inspect(detail) =~ "eacces"
    end

    @tag :task2_red_backend
    test "task2 g3: EC 恰好 quorum 的少数派 mismatch 按冻结 ordinal 归位",
         %{drives: drives} do
      o = opts(drives)
      :ok = ErasureCoded.put_bucket(@bucket, o)
      proof_ctx = ec_published_ctx!(drives, "k")

      # 恰好 4/6 verified（epoch_quorum=4）：仍是 degraded success，两条有界证据。
      Enum.each([4, 5], &ec_break_meta!(Enum.at(drives, &1), "k"))

      assert {:ok,
              {:degraded,
               %{
                 "status" => "degraded",
                 "required" => 4,
                 "verified" => 4,
                 "observed_owned" => 6,
                 "debt" => 2,
                 "degraded" => details
               }}} = ErasureCoded.verify_published(proof_ctx, o)

      assert Enum.map(details, & &1["endpoint"]) |> Enum.sort() == ["ordinal:4", "ordinal:5"]
      assert Enum.all?(details, &(&1["class"] == "mismatch"))
      refute Enum.any?(drives, &(inspect(details) =~ &1))
    end

    @tag :task2_red_backend
    test "task2 g3: EC finalize —— 同 token claimed 债务、healthy quorum 不足与精确 heal 收敛",
         %{drives: drives} do
      o = opts(drives)
      :ok = ErasureCoded.put_bucket(@bucket, o)

      debt_ctx = ec_published_ctx!(drives, "k-claimed")
      claimed_drive = Enum.at(drives, 5)
      ec_break_meta!(claimed_drive, "k-claimed")
      force_claimed_epoch!(claimed_drive, debt_ctx)

      # proof quorum 已过（5 verified >= 4），但 same-token claimed 未通过端点 proof：
      # 它是 owned 的真实 proof error，只能作为 durable cleanup 债务保留。
      assert {:ok,
              {:cleanup_pending,
               %{
                 "scope" => "aggregate",
                 "mode" => "finalize",
                 "status" => "cleanup_pending",
                 "required" => 4,
                 "verified" => 5,
                 "finalized" => 5,
                 "orphaned" => 0,
                 "degraded" => [debt_detail]
               }}} = ErasureCoded.finalize_if_current(debt_ctx, o)

      assert debt_detail["endpoint"] == "ordinal:5"
      assert debt_detail["owned"] == true
      assert debt_detail["status"] == "failed"
      # 未通过 proof 的 claimed 端点：epoch 与 final 字节一律不动。
      assert %ObjectEpoch{phase: "claimed", fingerprint: nil} =
               drive_epoch(claimed_drive, debt_ctx.target)

      assert File.exists?(Path.join(final_dir(claimed_drive, "k-claimed"), "part.0"))

      # heal 写回精确 final 后重试：claimed repair 收敛为带 fingerprint 的 committed。
      heal_final_from!(Enum.at(drives, 0), claimed_drive, "k-claimed")

      assert {:ok,
              {:finalized,
               %{"status" => "finalized", "verified" => 6, "finalized" => 6, "debt" => 0}}} =
               ErasureCoded.finalize_if_current(debt_ctx, o)

      assert %ObjectEpoch{phase: "committed", fingerprint: fingerprint} =
               drive_epoch(claimed_drive, debt_ctx.target)

      assert fingerprint == debt_ctx.published_fingerprint

      # healthy proof 不足 quorum：整体是 proof failure，绝不降级成「只是清理失败」，
      # 且失败调用绝不破坏任何端点字节。
      failed_ctx = ec_published_ctx!(drives, "k-below")
      Enum.each([3, 4, 5], &ec_break_meta!(Enum.at(drives, &1), "k-below"))

      assert {:error,
              {:published_proof_failed, :mismatch,
               %{"scope" => "aggregate", "mode" => "finalize", "verified" => 3}}} =
               ErasureCoded.finalize_if_current(failed_ctx, o)

      Enum.each(drives, fn drive ->
        assert File.exists?(Path.join(final_dir(drive, "k-below"), "part.0"))
      end)
    end

    @tag :task2_red_backend
    test "task2 g3: EC orphan-only 不投票，finalized quorum 在合法 orphan 证据下仍是终态",
         %{drives: drives} do
      o = opts(drives)
      :ok = ErasureCoded.put_bucket(@bucket, o)

      orphan_only_ctx = ec_published_ctx!(drives, "k-orphan-only")
      Enum.each(drives, &File.rm_rf!(epoch_path(&1, orphan_only_ctx.target)))

      assert {:error,
              {:published_proof_failed, :unavailable,
               %{
                 "scope" => "aggregate",
                 "mode" => "finalize",
                 "status" => "failed",
                 "verified" => 0,
                 "finalized" => 0,
                 "orphaned" => 6
               }}} = ErasureCoded.finalize_if_current(orphan_only_ctx, o)

      # 非破坏性：orphan 从不授权删除 manifest-only 残留。
      Enum.each(drives, fn drive ->
        assert File.exists?(Path.join(final_dir(drive, "k-orphan-only"), "part.0"))
      end)
    end

    @tag :task2_red_backend
    test "task2 g3: EC Control finalize 闭包捕获带 published fingerprint 的 proof 上下文",
         %{drives: drives} do
      o = opts(drives)
      :ok = ErasureCoded.put_bucket(@bucket, o)
      {:ok, _} = ErasureCoded.put(@bucket, "k", "null", ["old-bytes"], o)

      {ctx, put_result} =
        drive_mutation_put(drives, "k", ["new-bytes"], 1, @id_a, fn _ctx, result -> result end)

      assert {:ok, %{epoch_fingerprint: fingerprint}} = put_result

      # publish 阶段注册的 ctx 本身没有 fingerprint；只有 finalize 闭包捕获了
      # proof_ctx（携 published fingerprint）时，Control.finalize 才可能取证通过并收口。
      assert ctx.published_fingerprint == nil

      Enum.each(drives, fn drive ->
        assert %ObjectEpoch{phase: "committed", fingerprint: ^fingerprint} =
                 drive_epoch(drive, ctx.target)

        refute File.exists?(backup_dir(drive, @id_a))
      end)

      # restore 闭包捕获的是原始 ctx：committed 之后仍由既有 quorum 防线拒绝回滚。
      assert {:error, :epoch_committed} = ErasureCoded.restore_if_current(ctx, o)
    end
  end
end
