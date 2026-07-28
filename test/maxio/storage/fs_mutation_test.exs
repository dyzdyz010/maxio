defmodule Maxio.Storage.FSMutationTest do
  # 纯 tmp dir，无 DataCase/Repo：MutationContext 直接以 struct 构造（不经 journal），
  # 对应实现计划 B2 的 FS 后端验收断言 + B1 遗留项 3 中 FS 侧可构造的 crash 收敛路径。
  use ExUnit.Case, async: true

  alias Maxio.Cluster.{Paths, ShardServer}
  alias Maxio.Storage.{EpochStore, FS, MutationBackup, MutationContext, ObjectEpoch}

  @bucket "fs-mutation-test"
  @id_a "00000000-0000-0000-0000-00000000000a"
  @id_b "00000000-0000-0000-0000-00000000000b"

  setup do
    dir = Path.join(System.tmp_dir!(), "maxio_fs_mutation_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  defp opts(dir), do: [data_dir: dir]

  # .tmp 残留断言用 File.ls 判空（B2 审查项 1 / B7 收口）：Windows 下 System.tmp_dir!()
  # 的反斜杠会被 :filelib.wildcard 当转义符，Path.wildcard 恒返回 []——假覆盖。
  defp tmp_entries(dir) do
    case File.ls(Path.join(dir, ".tmp")) do
      {:ok, entries} -> entries
      {:error, :enoent} -> []
    end
  end

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
      backend: "fs",
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

  defp final_dir(dir, key, version_id \\ "null") do
    {:ok, rel} = Paths.object_rel(@bucket, key, version_id)
    Path.join(dir, rel)
  end

  defp backup_dir(dir, id), do: Path.join(dir, MutationBackup.relative_dir(id))

  defp epoch_path(dir, target) do
    {:ok, rel} = ObjectEpoch.relative_path(target)
    Path.join(dir, rel)
  end

  # 协议化 put 驱动（B5 orchestrator 的 B2 级替身；journal 不在本批范围）：
  # around_object_commit 内 claim → publish.(object_mutation: ctx)，publish 结果交给
  # on_published（其返回值即 around 返回值，驱动 ObjectCommit 的 finalize/rollback 收口）。
  defp drive_mutation_put(dir, key, chunks, gen, id, on_published, version_id \\ "null") do
    o = opts(dir)
    {:ok, current} = FS.current_epoch(target(key, version_id), o)
    previous = epoch_payload(epoch_or_nil(current))
    ctx = build_ctx(key, gen, id, previous, version_id)

    around = fn _prepared, publish ->
      assert {:ok, %{previous: claim_previous, endpoints_ok: 1}} =
               FS.claim_epoch(ctx.target, ctx.token, "put", o)

      assert epoch_payload(claim_previous) == previous

      result = publish.(version_id: version_id, object_meta: %{}, object_mutation: ctx)
      on_published.(ctx, result)
    end

    put_result =
      FS.put(@bucket, key, version_id, chunks, Keyword.put(o, :around_object_commit, around))

    {ctx, put_result}
  end

  defp epoch_or_nil(:absent), do: nil
  defp epoch_or_nil(%ObjectEpoch{} = epoch), do: epoch

  defp sha256_hex(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  defp md5_hex(bytes), do: :crypto.hash(:md5, bytes) |> Base.encode16(case: :lower)

  describe "claim_epoch / current_epoch（单 drive 薄包装）" do
    test "absent → previous=nil、endpoints_ok=1；claim 恒写 phase=claimed", %{dir: dir} do
      t = target("claim-fresh")
      assert {:ok, :absent} = FS.current_epoch(t, opts(dir))

      assert {:ok, %{previous: nil, endpoints_ok: 1}} =
               FS.claim_epoch(t, token(1, @id_a), "put", opts(dir))

      # B1 遗留确认项 4：EpochStore {:claim,...} 不约束 next.phase——后端层恒写 "claimed"。
      assert {:ok, %ObjectEpoch{phase: "claimed", previous_token: nil} = epoch} =
               FS.current_epoch(t, opts(dir))

      assert epoch.token == token(1, @id_a)
      assert epoch.operation == "put"
      assert epoch.value_type == "object"
    end

    test "fence 全序：拒绝不更大的 token；successor claim 返回 previous 并链 previous_token",
         %{dir: dir} do
      t = target("claim-fence")
      assert {:ok, _} = FS.claim_epoch(t, token(1, @id_b), "put", opts(dir))

      # 同 token 重复 claim 与同 generation 更小 mutation_id 均被 fence 拒绝
      assert {:error, {:fenced, _current}} = FS.claim_epoch(t, token(1, @id_b), "put", opts(dir))
      assert {:error, {:fenced, _current}} = FS.claim_epoch(t, token(1, @id_a), "put", opts(dir))

      assert {:ok, %{previous: %ObjectEpoch{} = previous, endpoints_ok: 1}} =
               FS.claim_epoch(t, token(2, @id_a), "put", opts(dir))

      assert previous.token == token(1, @id_b)

      assert {:ok, %ObjectEpoch{phase: "claimed", previous_token: prev_tok}} =
               FS.current_epoch(t, opts(dir))

      assert prev_tok == token(1, @id_b)
    end

    # B2 断言 6（claim 半）：legacy final（meta.json 在、无 epoch）→ previous=nil、
    # claim gen 由调用者给定成功（legacy 逻辑代际按协议记 0，next 由 orchestrator 给定）。
    test "legacy final（无 epoch）：current :absent、claim previous=nil", %{dir: dir} do
      :ok = FS.put_bucket(@bucket, opts(dir))
      {:ok, _} = FS.put(@bucket, "legacy-claim", "null", ["legacy"], opts(dir))

      t = target("legacy-claim")
      assert {:ok, :absent} = FS.current_epoch(t, opts(dir))
      assert {:ok, %{previous: nil}} = FS.claim_epoch(t, token(1, @id_a), "put", opts(dir))
      assert {:ok, %ObjectEpoch{phase: "claimed"}} = FS.current_epoch(t, opts(dir))
    end

    test "损坏 epoch → {:corrupt,...} 上报，claim 绝不覆盖", %{dir: dir} do
      t = target("corrupt-epoch")
      path = epoch_path(dir, t)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "{not json")

      assert {:error, {:corrupt, _reason}} = FS.current_epoch(t, opts(dir))
      assert {:error, {:corrupt, _reason}} = FS.claim_epoch(t, token(1, @id_a), "put", opts(dir))
      assert File.read!(path) == "{not json"
    end

    # B1 遗留项 3(b)：epoch.json 缺失 + .stale 残留（两步替换间硬崩）→ 读侧自愈回位。
    test "两步 rename 残留 .stale：读侧自愈回位，绝不判 absent", %{dir: dir} do
      t = target("stale-heal")
      assert {:ok, _} = FS.claim_epoch(t, token(1, @id_a), "put", opts(dir))

      path = epoch_path(dir, t)
      :ok = :file.rename(path, path <> ".stale")

      assert {:ok, %ObjectEpoch{phase: "claimed"}} = FS.current_epoch(t, opts(dir))
      assert File.exists?(path)
      refute File.exists?(path <> ".stale")
    end
  end

  describe "协议化 put（publish 分支）" do
    # B2 断言 1 + 2：publish 中间态五要素；put 成功收口 finalize → epoch=committed、backup 消失。
    test "overwrite：published 中间态 + finalize 收口 + 幂等", %{dir: dir} do
      o = opts(dir)
      :ok = FS.put_bucket(@bucket, o)
      {:ok, _} = FS.put(@bucket, "k", "null", ["old-bytes"], o)

      final = final_dir(dir, "k")
      old_part = File.read!(Path.join(final, "part.0"))
      old_meta = File.read!(Path.join(final, "meta.json"))
      backup = backup_dir(dir, @id_a)

      {ctx, put_result} =
        drive_mutation_put(dir, "k", ["new-bytes"], 1, @id_a, fn ctx, result ->
          # publish 返回即「published 中间态」：rename 已完成、finalize 尚未发生。
          assert {:ok, %{epoch_fingerprint: fingerprint}} = result

          assert {:ok, %ObjectEpoch{phase: "published"} = epoch} =
                   FS.current_epoch(ctx.target, o)

          assert epoch.fingerprint == fingerprint

          # fingerprint 与 final meta.json 实际落盘字节精确匹配
          final_meta = File.read!(Path.join(final, "meta.json"))
          assert fingerprint["sidecar_sha256"] == sha256_hex(final_meta)
          assert fingerprint["etag"] == md5_hex("new-bytes")
          assert fingerprint["size"] == byte_size("new-bytes")

          # final 有新字节
          assert File.read!(Path.join(final, "part.0")) == "new-bytes"

          # backup dir 含 manifest + 旧文件（逐字节）
          assert {:ok, manifest} =
                   MutationBackup.decode(File.read!(Path.join(backup, "manifest.json")))

          assert Enum.sort(MutationBackup.entry_names(manifest)) == ["meta.json", "part.0"]
          assert manifest.token == ctx.token
          assert manifest.previous_token == nil
          assert File.read!(Path.join(backup, "part.0")) == old_part
          assert File.read!(Path.join(backup, "meta.json")) == old_meta

          result
        end)

      assert {:ok, %{epoch_fingerprint: fingerprint}} = put_result

      # put 成功收口：Control.finalize → finalize_if_current → epoch=committed、backup 消失
      assert {:ok, %ObjectEpoch{phase: "committed"}} = FS.current_epoch(ctx.target, o)
      refute File.exists?(backup)
      assert File.read!(Path.join(final, "part.0")) == "new-bytes"

      # 重复 finalize 幂等（proof-aware：committed 重放必须先复验才收敛）
      proof_ctx = %MutationContext{ctx | published_fingerprint: fingerprint}

      assert {:ok, {:finalized, %{"status" => "finalized", "verified" => 1, "finalized" => 1}}} =
               FS.finalize_if_current(proof_ctx, o)

      assert {:ok, %ObjectEpoch{phase: "committed"}} = FS.current_epoch(ctx.target, o)

      # committed 后 restore 被端点级防线拒绝（metadata_committed 禁回滚落点）
      assert {:error, :epoch_committed} = FS.restore_if_current(ctx, o)
      assert File.read!(Path.join(final, "part.0")) == "new-bytes"
    end

    # B2 断言 3（Control 闭包接线）+ 断言 6（restore 半）：旧对象无 epoch（legacy 代际），
    # restore 授权只认我们 claim→publish 写下的 epoch token，不依赖 nil 授权。
    test "metadata 失败：Control rollback → restore_if_current 逐字节恢复旧值", %{dir: dir} do
      o = opts(dir)
      :ok = FS.put_bucket(@bucket, o)
      {:ok, _} = FS.put(@bucket, "k", "null", ["old-bytes"], o)

      final = final_dir(dir, "k")
      old_part = File.read!(Path.join(final, "part.0"))
      old_meta = File.read!(Path.join(final, "meta.json"))
      backup = backup_dir(dir, @id_a)

      {ctx, put_result} =
        drive_mutation_put(dir, "k", ["new-bytes"], 1, @id_a, fn _ctx, result ->
          assert {:ok, _} = result
          {:error, :metadata_commit_failed}
        end)

      assert {:error, :metadata_commit_failed} = put_result
      assert File.read!(Path.join(final, "part.0")) == old_part
      assert File.read!(Path.join(final, "meta.json")) == old_meta
      assert {:ok, %ObjectEpoch{phase: "rolled_back"}} = FS.current_epoch(ctx.target, o)
      refute File.exists?(backup)
      assert tmp_entries(dir) == []
    end

    # B2 断言 3（recovery 替身直调）：published 中间态直接 restore_if_current；
    # 随后 Control rollback 的重放走 rolled_back 幂等收敛分支，不破坏已恢复旧值。
    test "published 中间态直调 restore_if_current：恢复 + 幂等重放", %{dir: dir} do
      o = opts(dir)
      :ok = FS.put_bucket(@bucket, o)
      {:ok, _} = FS.put(@bucket, "k", "null", ["old-bytes"], o)

      final = final_dir(dir, "k")
      old_part = File.read!(Path.join(final, "part.0"))
      old_meta = File.read!(Path.join(final, "meta.json"))
      backup = backup_dir(dir, @id_a)

      {ctx, put_result} =
        drive_mutation_put(dir, "k", ["new-bytes"], 1, @id_a, fn ctx, result ->
          assert {:ok, _} = result

          assert {:ok, :restored} = FS.restore_if_current(ctx, o)
          assert File.read!(Path.join(final, "part.0")) == old_part
          assert File.read!(Path.join(final, "meta.json")) == old_meta
          assert {:ok, %ObjectEpoch{phase: "rolled_back"}} = FS.current_epoch(ctx.target, o)
          refute File.exists?(backup)

          {:error, :aborted_after_restore}
        end)

      assert {:error, :aborted_after_restore} = put_result
      # Control rollback 重放（rolled_back 幂等分支）后旧值仍在
      assert File.read!(Path.join(final, "part.0")) == old_part
      assert {:ok, %ObjectEpoch{phase: "rolled_back"}} = FS.current_epoch(ctx.target, o)
    end

    # fresh 协议 put（versioned 落点，顺带覆盖 .versions 布局 final_rel）：exact token +
    # published phase 已授权 destructive restore，且 manifest entries=[]、previous_token=nil
    # 明确证明 previous value absent，因此回滚必须恢复物理 absence。
    test "fresh versioned put 的 restore：epoch=rolled_back、backup 清空、final 物理不存在", %{dir: dir} do
      o = opts(dir)
      :ok = FS.put_bucket(@bucket, o)
      version_id = "v1-fresh"
      final = final_dir(dir, "vk", version_id)
      backup = backup_dir(dir, @id_a)

      {ctx, put_result} =
        drive_mutation_put(
          dir,
          "vk",
          ["fresh-bytes"],
          1,
          @id_a,
          fn ctx, result ->
            assert {:ok, _} = result

            # fresh put 的 manifest entries=[]、previous_token=nil
            assert {:ok, manifest} =
                     MutationBackup.decode(File.read!(Path.join(backup, "manifest.json")))

            assert MutationBackup.entry_names(manifest) == []
            assert manifest.previous_token == nil

            assert {:ok, :restored} = FS.restore_if_current(ctx, o)
            assert {:ok, %ObjectEpoch{phase: "rolled_back"}} = FS.current_epoch(ctx.target, o)
            refute File.exists?(backup)
            refute File.exists?(final)

            {:error, :rolled_back_by_test}
          end,
          version_id
        )

      assert {:error, :rolled_back_by_test} = put_result
      assert {:ok, %ObjectEpoch{phase: "rolled_back"}} = FS.current_epoch(ctx.target, o)
      refute File.exists?(final)
    end

    # B2 断言 4：successor fence——A published 后 B（gen+1）claim+publish 走完，
    # A 的迟到 restore → :superseded，B 的 final/epoch 逐字节不变、A 的 backup 保留。
    test "successor：A 的迟到 restore → :superseded，绝不触碰 B", %{dir: dir} do
      o = opts(dir)
      :ok = FS.put_bucket(@bucket, o)
      {:ok, _} = FS.put(@bucket, "k", "null", ["old-bytes"], o)
      final = final_dir(dir, "k")

      {_ctx_a, put_result} =
        drive_mutation_put(dir, "k", ["a-bytes"], 1, @id_a, fn ctx_a, result ->
          assert {:ok, _} = result

          # A published（未 finalize）之下，B 走完整协议 put（gen+1）并收口
          {_ctx_b, b_result} =
            drive_mutation_put(dir, "k", ["b-bytes"], 2, @id_b, fn _ctx_b, r -> r end)

          assert {:ok, _} = b_result

          assert {:ok, %ObjectEpoch{phase: "committed", token: tok_b}} =
                   FS.current_epoch(ctx_a.target, o)

          assert tok_b == token(2, @id_b)
          b_part = File.read!(Path.join(final, "part.0"))
          b_meta = File.read!(Path.join(final, "meta.json"))
          assert b_part == "b-bytes"

          # A 的迟到 restore：只报告 superseded，B 的 final/epoch 不动，A 的 backup 保留
          assert {:ok, :superseded} = FS.restore_if_current(ctx_a, o)
          assert File.read!(Path.join(final, "part.0")) == b_part
          assert File.read!(Path.join(final, "meta.json")) == b_meta

          assert {:ok, %ObjectEpoch{phase: "committed", token: ^tok_b}} =
                   FS.current_epoch(ctx_a.target, o)

          assert File.exists?(Path.join(backup_dir(dir, @id_a), "manifest.json"))

          {:error, :stale_owner}
        end)

      assert {:error, :stale_owner} = put_result
      # A 的 Control rollback 重放同样 superseded：B 三态不变、A 的 backup 仍保留
      assert File.read!(Path.join(final, "part.0")) == "b-bytes"
      assert {:ok, %ObjectEpoch{token: tok}} = FS.current_epoch(target("k"), o)
      assert tok == token(2, @id_b)
      assert File.exists?(Path.join(backup_dir(dir, @id_a), "manifest.json"))
    end

    # B1 遗留项 3(a)：「epoch=rolled_back + manifest 仍在 + entries 未回位」中间态
    # （上次 restore 在 rename 回 final 之前硬崩）的幂等收敛。
    test "rolled_back 中间态：restore_if_current 幂等收敛残余 backup entries", %{dir: dir} do
      o = opts(dir)
      :ok = FS.put_bucket(@bucket, o)
      {:ok, _} = FS.put(@bucket, "k", "null", ["old-bytes"], o)

      final = final_dir(dir, "k")
      old_part = File.read!(Path.join(final, "part.0"))
      old_meta = File.read!(Path.join(final, "meta.json"))
      backup = backup_dir(dir, @id_a)

      {_ctx, put_result} =
        drive_mutation_put(dir, "k", ["new-bytes"], 1, @id_a, fn ctx, result ->
          assert {:ok, _} = result

          # 手工把 epoch 翻到 rolled_back（模拟 restore 写完 epoch 后、rename 回位前硬崩）：
          # manifest + entries 滞留 backup，final 仍是新字节。
          {:ok, rolled} =
            ObjectEpoch.new(ctx.target, ctx.token, %{
              operation: "put",
              phase: "rolled_back",
              value_type: "object",
              updated_at: DateTime.utc_now()
            })

          {:ok, payload} = EpochStore.payload(rolled)

          assert {:ok, :applied} =
                   ShardServer.cas_epoch(dir, %{
                     next: payload,
                     expect: {:exact, ctx.token, ["published"]}
                   })

          assert File.read!(Path.join(final, "part.0")) == "new-bytes"
          assert File.exists?(Path.join(backup, "part.0"))

          # 幂等收敛：残余 entries 回位、backup 清空
          assert {:ok, :restored} = FS.restore_if_current(ctx, o)
          assert File.read!(Path.join(final, "part.0")) == old_part
          assert File.read!(Path.join(final, "meta.json")) == old_meta
          refute File.exists?(backup)

          {:error, :converged}
        end)

      assert {:error, :converged} = put_result
      assert File.read!(Path.join(final, "part.0")) == old_part
    end

    # B1 遗留项 3(c)：restore 读到损坏 manifest → {:corrupt, {:backup_manifest, _}}，
    # 字节/epoch 原样、backup 保留（不猜测、不破坏——B6 recovery 映射 quarantine 证据）。
    @tag capture_log: true
    test "损坏 manifest：restore 结构化拒绝，三态保留", %{dir: dir} do
      o = opts(dir)
      :ok = FS.put_bucket(@bucket, o)
      {:ok, _} = FS.put(@bucket, "k", "null", ["old-bytes"], o)

      final = final_dir(dir, "k")
      backup = backup_dir(dir, @id_a)

      {ctx, put_result} =
        drive_mutation_put(dir, "k", ["new-bytes"], 1, @id_a, fn ctx, result ->
          assert {:ok, _} = result

          File.write!(Path.join(backup, "manifest.json"), "{corrupt")

          assert {:error, {:corrupt, {:backup_manifest, _reason}}} =
                   FS.restore_if_current(ctx, o)

          assert File.read!(Path.join(final, "part.0")) == "new-bytes"
          assert {:ok, %ObjectEpoch{phase: "published"}} = FS.current_epoch(ctx.target, o)
          assert File.exists?(Path.join(backup, "part.0"))

          {:error, :quarantine_path}
        end)

      # Control rollback 重放同样 corrupt 拒绝（Control 折叠为 error 日志，不破坏现场）
      assert {:error, :quarantine_path} = put_result
      assert File.read!(Path.join(final, "part.0")) == "new-bytes"
      assert {:ok, %ObjectEpoch{phase: "published"}} = FS.current_epoch(ctx.target, o)
      assert File.exists?(Path.join(backup, "part.0"))
      assert File.read!(Path.join(backup, "manifest.json")) == "{corrupt"
    end

    # pre-B6-1 单文件布局与 manifest 契约不可表达：协议分支 fail-closed，
    # 旧文件与已 claim 的 epoch 均不动（收敛交给 journal/recovery，P7 backfill 消亡此分支）。
    test "legacy 单文件布局：协议 put fail-closed，旧字节不动", %{dir: dir} do
      o = opts(dir)
      :ok = FS.put_bucket(@bucket, o)
      legacy_path = Path.join([dir, @bucket, "legacy-k"])
      File.write!(legacy_path, "legacy-bytes")

      {ctx, put_result} =
        drive_mutation_put(dir, "legacy-k", ["new"], 1, @id_a, fn _ctx, result -> result end)

      assert {:error, :legacy_layout_conflict} = put_result
      assert File.read!(legacy_path) == "legacy-bytes"
      assert {:ok, %ObjectEpoch{phase: "claimed"}} = FS.current_epoch(ctx.target, o)
      refute File.exists?(backup_dir(dir, @id_a))
      assert tmp_entries(dir) == []
    end

    test "object_mutation 非 MutationContext：结构化拒绝，旧 final 不动", %{dir: dir} do
      o = opts(dir)
      :ok = FS.put_bucket(@bucket, o)
      {:ok, _} = FS.put(@bucket, "k", "null", ["old-bytes"], o)
      final = final_dir(dir, "k")

      around = fn _prepared, publish ->
        publish.(version_id: "null", object_meta: %{}, object_mutation: :bogus)
      end

      assert {:error, {:invalid_object_mutation, :bogus}} =
               FS.put(
                 @bucket,
                 "k",
                 "null",
                 ["new"],
                 Keyword.put(o, :around_object_commit, around)
               )

      assert File.read!(Path.join(final, "part.0")) == "old-bytes"
      assert tmp_entries(dir) == []
    end

    # B2 断言 5（切片）：无协议 opts 的 put 不落协议根、不写 epoch（全量回归由
    # fs_test + fs_conformance_test 把关）。
    test "非协议 put：不落 .maxio-object-mutations / .maxio-object-epochs", %{dir: dir} do
      o = opts(dir)
      :ok = FS.put_bucket(@bucket, o)
      {:ok, _} = FS.put(@bucket, "plain", "null", ["bytes-1"], o)
      # overwrite 路径（plan_put_backup 的 .tmp 备份）同样不触协议根
      {:ok, _} = FS.put(@bucket, "plain", "null", ["bytes-2"], o)

      refute File.exists?(Path.join(dir, ".maxio-object-mutations"))
      refute File.exists?(Path.join(dir, ".maxio-object-epochs"))
      assert {:ok, :absent} = FS.current_epoch(target("plain"), o)
      assert tmp_entries(dir) == []
    end
  end

  describe "Task 2 backend proof aggregation（RED）" do
    @tag :task2_red_backend
    test "task2 red: FS verify_published aggregates a verified 1/1 endpoint proof", %{dir: dir} do
      o = opts(dir)
      :ok = FS.put_bucket(@bucket, o)

      {ctx, {:ok, %{epoch_fingerprint: fingerprint}}} =
        drive_mutation_put(dir, "k", ["new-bytes"], 1, @id_a, fn _ctx, result -> result end)

      assert function_exported?(FS, :verify_published, 2)

      proof_ctx = %MutationContext{ctx | published_fingerprint: fingerprint}

      assert {:ok,
              {:verified,
               %{
                 "scope" => "aggregate",
                 "mode" => "proof",
                 "status" => "verified",
                 "required" => 1,
                 "verified" => 1,
                 "observed_owned" => 1,
                 "unavailable" => 0,
                 "debt" => 0,
                 "degraded" => [],
                 "omitted" => 0
               } = summary}} = FS.verify_published(proof_ctx, o)

      # 精确有界 aggregate：无路径 / node / raw sidecar 泄漏。
      refute Enum.any?(~w(path root drive node final_rel), &Map.has_key?(summary, &1))
      refute inspect(summary) =~ dir
    end

    @tag :task2_red_backend
    test "task2 red: FS verify_published maps every endpoint proof error to a bounded aggregate",
         %{dir: dir} do
      o = opts(dir)
      :ok = FS.put_bucket(@bucket, o)

      publish = fn key ->
        {ctx, {:ok, %{epoch_fingerprint: fingerprint}}} =
          drive_mutation_put(dir, key, ["new-bytes"], 1, @id_a, fn _ctx, result -> result end)

        %MutationContext{ctx | published_fingerprint: fingerprint}
      end

      mismatch_ctx = publish.("k-mismatch")
      meta = Path.join(final_dir(dir, "k-mismatch"), "meta.json")
      File.write!(meta, File.read!(meta) <> "\n")

      assert {:error,
              {:published_proof_failed, :mismatch,
               %{
                 "scope" => "aggregate",
                 "mode" => "proof",
                 "status" => "failed",
                 "verified" => 0
               }}} = FS.verify_published(mismatch_ctx, o)

      corrupt_ctx = publish.("k-corrupt")
      File.rm!(Path.join(final_dir(dir, "k-corrupt"), "part.0"))

      assert {:error,
              {:published_proof_failed, :corrupt, %{"scope" => "aggregate", "verified" => 0}}} =
               FS.verify_published(corrupt_ctx, o)

      # successor 短路为全局 superseded，绝不降级成少数 failure。
      superseded_ctx = publish.("k-superseded")
      successor = token(2, @id_b)

      {:ok, claimed} =
        ObjectEpoch.new(superseded_ctx.target, successor, %{
          operation: "put",
          phase: "claimed",
          value_type: "object",
          updated_at: DateTime.utc_now()
        })

      assert {:ok, :applied} = EpochStore.cas(dir, claimed, {:claim, successor})

      assert {:ok, {:superseded, %{"scope" => "aggregate", "status" => "superseded"}}} =
               FS.verify_published(superseded_ctx, o)

      # nil published fingerprint 必须失败关闭，不得当作「无需比较」。endpoint 事实是
      # non-owned corrupt（invalid request）；但 D5 只让 owned corrupt/mismatch 参与全局
      # integrity 选择，verified < required 时外层落 fallback unavailable。
      nil_ctx = %MutationContext{publish.("k-nil") | published_fingerprint: nil}

      assert {:error,
              {:published_proof_failed, :unavailable,
               %{
                 "scope" => "aggregate",
                 "mode" => "proof",
                 "status" => "failed",
                 "class" => "unavailable",
                 "verified" => 0,
                 "degraded" => [nil_detail]
               }}} = FS.verify_published(nil_ctx, o)

      assert nil_detail["class"] == "corrupt"
      assert nil_detail["owned"] == false
      assert nil_detail["code"] == "invalid_request"
    end

    @tag :task2_red_backend
    test "task2 red: FS finalize_if_current returns the proof-aware aggregate union", %{dir: dir} do
      o = opts(dir)
      :ok = FS.put_bucket(@bucket, o)

      {ctx, {:ok, %{epoch_fingerprint: fingerprint}}} =
        drive_mutation_put(dir, "k", ["new-bytes"], 1, @id_a, fn _ctx, result -> result end)

      proof_ctx = %MutationContext{ctx | published_fingerprint: fingerprint}

      assert {:ok,
              {:finalized,
               %{
                 "scope" => "aggregate",
                 "mode" => "finalize",
                 "status" => "finalized",
                 "required" => 1,
                 "verified" => 1,
                 "finalized" => 1,
                 "debt" => 0,
                 "orphaned" => 0
               }}} = FS.finalize_if_current(proof_ctx, o)

      # committed 幂等重放必须先复验：final 漂移后不得再宣告 finalized。
      meta = Path.join(final_dir(dir, "k"), "meta.json")
      File.write!(meta, File.read!(meta) <> "\n")

      assert {:error, {:published_proof_failed, :mismatch, %{"mode" => "finalize"}}} =
               FS.finalize_if_current(proof_ctx, o)
    end

    @tag :task2_red_backend
    test "task2 control: FS publish still yields the epoch fingerprint and backup manifest", %{
      dir: dir
    } do
      o = opts(dir)
      :ok = FS.put_bucket(@bucket, o)
      {:ok, _} = FS.put(@bucket, "k", "null", ["old-bytes"], o)

      backup = backup_dir(dir, @id_a)

      {_ctx, put_result} =
        drive_mutation_put(dir, "k", ["new-bytes"], 1, @id_a, fn _ctx, result ->
          assert {:ok, %{epoch_fingerprint: fingerprint}} = result
          assert is_map(fingerprint)

          assert {:ok, manifest} =
                   MutationBackup.decode(File.read!(Path.join(backup, "manifest.json")))

          assert Enum.sort(MutationBackup.entry_names(manifest)) == ["meta.json", "part.0"]
          result
        end)

      assert {:ok, %{epoch_fingerprint: _fingerprint}} = put_result
    end

    @tag :task2_red_backend
    test "task2 g3: FS Control finalize 闭包捕获带 published fingerprint 的 proof 上下文",
         %{dir: dir} do
      o = opts(dir)
      :ok = FS.put_bucket(@bucket, o)
      {:ok, _} = FS.put(@bucket, "k", "null", ["old-bytes"], o)

      {ctx, put_result} =
        drive_mutation_put(dir, "k", ["new-bytes"], 1, @id_a, fn _ctx, result -> result end)

      assert {:ok, %{epoch_fingerprint: fingerprint}} = put_result

      # register 时的 ctx 没有 fingerprint；只有 finalize 闭包捕获 proof_ctx 时，
      # Control.finalize 的 proof-aware finalize 才可能取证通过并写 committed + 清 backup。
      assert ctx.published_fingerprint == nil

      assert {:ok, %ObjectEpoch{phase: "committed", fingerprint: ^fingerprint}} =
               FS.current_epoch(ctx.target, o)

      refute File.exists?(backup_dir(dir, @id_a))

      # restore 闭包捕获的仍是原始 ctx：committed 之后由既有端点级防线拒绝回滚。
      assert {:error, :epoch_committed} = FS.restore_if_current(ctx, o)
    end
  end
end
