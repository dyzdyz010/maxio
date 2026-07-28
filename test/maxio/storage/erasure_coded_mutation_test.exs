defmodule Maxio.Storage.ErasureCodedMutationTest do
  # 纯 tmp drives，无 DataCase/Repo：MutationContext 直接以 struct 构造（不经 journal），
  # 对应实现计划 B3 的 EC 后端验收断言。6 盘（4+2）→ write_quorum=4、
  # epoch_quorum=max(4, ⌊6/2⌋+1)=4：容忍 2 盘故障，3 盘故障必须拒绝。
  use ExUnit.Case, async: true

  alias Maxio.Cluster.{Paths, ShardServer}
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

      assert {:ok, %{epoch_fingerprint: _fingerprint}} = put_result

      # put 成功收口：Control.finalize → finalize_if_current → epoch=committed、backup 消失
      assert {:ok, %ObjectEpoch{phase: "committed"}} = ErasureCoded.current_epoch(ctx.target, o)
      Enum.each(drives, fn drive -> refute File.exists?(backup_dir(drive, @id_a)) end)
      assert body(drives, "k") == "new-bytes"
      assert Enum.all?(drives, &temp_empty?/1)

      # 重复 finalize 幂等
      assert {:ok, :finalized} = ErasureCoded.finalize_if_current(ctx, o)
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
      assert {:error, :epoch_missing} = ErasureCoded.finalize_if_current(ctx, o)
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
end
