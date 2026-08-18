defmodule Maxio.Cluster.ShardServerMutationTest do
  use ExUnit.Case, async: true

  alias Maxio.Cluster.{Paths, ShardServer}
  alias Maxio.Storage.{EpochStore, MutationBackup, ObjectEpoch}

  @bucket "shard-mutation-test"
  @id_a "00000000-0000-0000-0000-00000000000a"
  @id_b "00000000-0000-0000-0000-00000000000b"

  setup do
    dir =
      Path.join(System.tmp_dir!(), "maxio_shard_mutation_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  defp target(key) do
    {:ok, target} = ObjectEpoch.object_target(@bucket, key, "null")
    target
  end

  defp token(gen, id) do
    {:ok, token} = ObjectEpoch.token(gen, id)
    token
  end

  defp payload(epoch) do
    {:ok, payload} = EpochStore.payload(epoch)
    payload
  end

  defp final_rel(key) do
    {:ok, rel} = Paths.object_rel(@bucket, key, "null")
    rel
  end

  defp write_final!(dir, rel, files) do
    final_dir = Path.join(dir, rel)
    File.mkdir_p!(final_dir)
    Enum.each(files, fn {name, bytes} -> File.write!(Path.join(final_dir, name), bytes) end)
  end

  defp claim!(dir, target, gen, id) do
    tok = token(gen, id)

    {:ok, epoch} =
      ObjectEpoch.new(target, tok, %{
        operation: "put",
        phase: "claimed",
        value_type: "object",
        updated_at: DateTime.utc_now()
      })

    assert {:ok, :applied} =
             ShardServer.cas_epoch(dir, %{next: payload(epoch), expect: {:claim, tok}})

    tok
  end

  defp publish!(dir, target, gen, id, fingerprint) do
    tok = token(gen, id)

    {:ok, epoch} =
      ObjectEpoch.new(target, tok, %{
        operation: "put",
        phase: "published",
        value_type: "object",
        fingerprint: fingerprint,
        updated_at: DateTime.utc_now()
      })

    assert {:ok, :applied} =
             ShardServer.cas_epoch(dir, %{
               next: payload(epoch),
               expect: {:exact, tok, ["claimed"]}
             })

    tok
  end

  # 模拟 B2 publish 前的备份物化：manifest 落盘 + 旧 final 文件 rename 进 backup 目录。
  defp materialize_backup!(dir, target, tok, mutation_id, rel, names) do
    backup_dir = Path.join(dir, MutationBackup.relative_dir(mutation_id))
    File.mkdir_p!(backup_dir)

    {:ok, manifest} = MutationBackup.manifest(target, tok, nil, Enum.map(names, &%{"name" => &1}))
    {:ok, manifest_bytes} = MutationBackup.encode(manifest)
    File.write!(Path.join(backup_dir, MutationBackup.manifest_name()), manifest_bytes)

    final_dir = Path.join(dir, rel)

    Enum.each(names, fn name ->
      :ok = :file.rename(Path.join(final_dir, name), Path.join(backup_dir, name))
    end)

    backup_dir
  end

  # 合法 maxio/2 sidecar：proof-aware finalize 必须能在其上重新取证。
  defp proof_sidecar(etag, part) do
    Jason.encode!(%{
      "format" => "maxio/2",
      "etag" => etag,
      "size" => byte_size(part),
      "sha256" => String.duplicate("a", 64),
      "versions" => [%{"version_id" => "null", "type" => "object"}]
    })
  end

  # 与 published_overwrite!/2 同构，但 final 是合法 maxio/2 sidecar，并返回完整六字段
  # proof request，供 proof-aware finalize 使用。
  defp proof_overwrite!(dir, key, opts \\ []) do
    id = Keyword.get(opts, :id, @id_a)
    t = target(key)
    rel = final_rel(key)
    part = "new-part"
    etag = "etag-#{key}"
    raw_meta = proof_sidecar(etag, part)
    fingerprint = ObjectEpoch.fingerprint(etag, byte_size(part), raw_meta)

    write_final!(dir, rel, %{"part.0" => "old-part", "meta.json" => "old-meta"})
    tok = claim!(dir, t, 1, id)
    backup_dir = materialize_backup!(dir, t, tok, id, rel, ["part.0", "meta.json"])

    if Keyword.get(opts, :write_final, true) do
      write_final!(dir, rel, %{"part.0" => part, "meta.json" => raw_meta})
    end

    tok =
      if Keyword.get(opts, :publish, true),
        do: publish!(dir, t, 1, id, fingerprint),
        else: tok

    %{
      target: t,
      rel: rel,
      token: tok,
      part: part,
      fingerprint: fingerprint,
      backup_dir: backup_dir,
      final_dir: Path.join(dir, rel),
      request: %{
        target: t,
        token: tok,
        mutation_id: id,
        final_rel: rel,
        expected_fingerprint: fingerprint,
        layout: %{kind: "fs"}
      }
    }
  end

  # 完整铺一个「旧对象 → claim → 备份物化 → 新值提交 → published」的端点现场。
  defp published_overwrite!(dir, key) do
    t = target(key)
    rel = final_rel(key)
    write_final!(dir, rel, %{"part.0" => "old-part", "meta.json" => "old-meta"})

    tok = claim!(dir, t, 1, @id_a)
    backup_dir = materialize_backup!(dir, t, tok, @id_a, rel, ["part.0", "meta.json"])
    write_final!(dir, rel, %{"part.0" => "new-part", "meta.json" => "new-meta"})
    publish!(dir, t, 1, @id_a, ObjectEpoch.fingerprint("etag-new", 8, "new-meta"))

    %{target: t, rel: rel, token: tok, backup_dir: backup_dir, final_dir: Path.join(dir, rel)}
  end

  test "read_epoch：absent 显式区分；claim 后返回纯数据 payload", %{dir: dir} do
    t = target("read")
    assert {:ok, :absent} = ShardServer.read_epoch(dir, t)

    claim!(dir, t, 1, @id_a)

    assert {:ok, %{"phase" => "claimed", "token" => %{"generation" => 1}} = read} =
             ShardServer.read_epoch(dir, t)

    assert read["format"] == "maxio/object-epoch/1"
  end

  test "verify_mutation：ShardServer 暴露有界 endpoint proof", %{dir: dir} do
    key = "verify-endpoint"
    t = target(key)
    rel = final_rel(key)

    raw_meta =
      Jason.encode!(%{
        "format" => "maxio/2",
        "etag" => "etag-proof",
        "size" => 5,
        "sha256" => String.duplicate("a", 64),
        "versions" => [%{"version_id" => "null", "type" => "object"}]
      })

    fingerprint = ObjectEpoch.fingerprint("etag-proof", 5, raw_meta)
    _claimed = claim!(dir, t, 1, @id_a)
    tok = publish!(dir, t, 1, @id_a, fingerprint)
    write_final!(dir, rel, %{"part.0" => "proof", "meta.json" => raw_meta})

    assert {:ok,
            {:verified,
             %{
               "scope" => "endpoint",
               "endpoint" => "local",
               "status" => "verified",
               "owned" => true
             }}} =
             ShardServer.verify_mutation(dir, %{
               target: t,
               token: tok,
               mutation_id: @id_a,
               final_rel: rel,
               expected_fingerprint: fingerprint,
               layout: %{kind: "fs"}
             })
  end

  test "cas_epoch 拒绝坏 payload（decode 全量重验）", %{dir: dir} do
    assert {:error, {:invalid_epoch_payload, _}} =
             ShardServer.cas_epoch(dir, %{
               next: %{"format" => "nope"},
               expect: {:claim, token(1, @id_a)}
             })

    assert {:error, {:invalid_epoch_request, _}} = ShardServer.cas_epoch(dir, %{bogus: true})
  end

  test "restore：claimed 无 backup → 仅转 epoch，final 不触碰；幂等", %{dir: dir} do
    key = "restore-claimed"
    t = target(key)
    rel = final_rel(key)
    write_final!(dir, rel, %{"part.0" => "legacy-bytes"})

    tok = claim!(dir, t, 1, @id_a)
    request = %{target: t, token: tok, mutation_id: @id_a, final_rel: rel}

    assert {:ok, :restored} = ShardServer.restore_mutation(dir, request)
    assert {:ok, %{"phase" => "rolled_back"}} = ShardServer.read_epoch(dir, t)
    assert File.read!(Path.join([dir, rel, "part.0"])) == "legacy-bytes"

    # 幂等重放
    assert {:ok, :restored} = ShardServer.restore_mutation(dir, request)
  end

  # B1 断言 4（restore 主线）：published 的 restore 逐字节恢复旧文件、epoch=rolled_back、
  # backup 清空。
  test "restore：published + manifest → 旧 part.0/meta.json 逐字节恢复、backup 清空", %{dir: dir} do
    %{target: t, rel: rel, token: tok, backup_dir: backup_dir, final_dir: final_dir} =
      published_overwrite!(dir, "restore-published")

    request = %{target: t, token: tok, mutation_id: @id_a, final_rel: rel}

    assert {:ok, :restored} = ShardServer.restore_mutation(dir, request)
    assert File.read!(Path.join(final_dir, "part.0")) == "old-part"
    assert File.read!(Path.join(final_dir, "meta.json")) == "old-meta"
    refute File.exists?(backup_dir)
    assert {:ok, %{"phase" => "rolled_back"}} = ShardServer.read_epoch(dir, t)

    # 幂等重放（backup 已清空）
    assert {:ok, :restored} = ShardServer.restore_mutation(dir, request)
  end

  test "restore：published fresh manifest → final 物理不存在、epoch rolled_back、backup 清空", %{
    dir: dir
  } do
    key = "restore-published-fresh"
    t = target(key)
    rel = final_rel(key)
    tok = claim!(dir, t, 1, @id_a)
    backup_dir = materialize_backup!(dir, t, tok, @id_a, rel, [])
    final_dir = Path.join(dir, rel)

    write_final!(dir, rel, %{"part.0" => "fresh-part", "meta.json" => "fresh-meta"})
    publish!(dir, t, 1, @id_a, ObjectEpoch.fingerprint("etag-fresh", 10, "fresh-meta"))

    assert {:ok, manifest} =
             MutationBackup.decode(
               File.read!(Path.join(backup_dir, MutationBackup.manifest_name()))
             )

    assert MutationBackup.entry_names(manifest) == []
    assert manifest.previous_token == nil

    assert {:ok, :restored} =
             ShardServer.restore_mutation(dir, %{
               target: t,
               token: tok,
               mutation_id: @id_a,
               final_rel: rel
             })

    refute File.exists?(final_dir)
    assert {:ok, %{"phase" => "rolled_back"}} = ShardServer.read_epoch(dir, t)
    refute File.exists?(backup_dir)
  end

  # B1 断言 4：successor token → :superseded 且 final/backup 均未变。
  test "restore：successor 已建立 → :superseded，final/backup 均不动", %{dir: dir} do
    %{target: t, rel: rel, token: tok_a, backup_dir: backup_dir, final_dir: final_dir} =
      published_overwrite!(dir, "restore-superseded")

    tok_b = claim!(dir, t, 2, @id_b)

    assert {:ok, :superseded} =
             ShardServer.restore_mutation(dir, %{
               target: t,
               token: tok_a,
               mutation_id: @id_a,
               final_rel: rel
             })

    # A 的已发布字节与 A 的 backup 全部原样；epoch 仍是 B 的 claim。
    assert File.read!(Path.join(final_dir, "part.0")) == "new-part"
    assert File.read!(Path.join(final_dir, "meta.json")) == "new-meta"
    assert File.exists?(Path.join(backup_dir, MutationBackup.manifest_name()))
    assert File.read!(Path.join(backup_dir, "part.0")) == "old-part"

    assert {:ok, %{"phase" => "claimed", "token" => read_tok}} = ShardServer.read_epoch(dir, t)
    assert read_tok == tok_b
  end

  # B1 断言 4：committed phase → 拒绝（metadata_committed 禁回滚的端点级防线）。
  test "restore：committed epoch 即使 token 匹配也拒绝", %{dir: dir} do
    site = proof_overwrite!(dir, "restore-committed")

    assert {:ok,
            {:finalized,
             %{
               "scope" => "endpoint",
               "mode" => "finalize",
               "status" => "finalized",
               "owned" => true,
               "proof_passed" => true,
               "finalized" => true
             }}} = ShardServer.finalize_mutation(dir, site.request)

    assert {:error, :epoch_committed} =
             ShardServer.restore_mutation(dir, %{
               target: site.target,
               token: site.token,
               mutation_id: @id_a,
               final_rel: site.rel
             })

    assert File.read!(Path.join(site.final_dir, "part.0")) == site.part
    assert {:ok, %{"phase" => "committed"}} = ShardServer.read_epoch(dir, site.target)
  end

  test "restore：epoch absent → :epoch_missing，绝不删/恢复任何字节", %{dir: dir} do
    key = "restore-missing"
    t = target(key)
    rel = final_rel(key)
    write_final!(dir, rel, %{"part.0" => "current-bytes"})

    tok = token(1, @id_a)
    backup_dir = Path.join(dir, MutationBackup.relative_dir(@id_a))
    File.mkdir_p!(backup_dir)
    {:ok, manifest} = MutationBackup.manifest(t, tok, nil, [%{"name" => "part.0"}])
    {:ok, manifest_bytes} = MutationBackup.encode(manifest)
    File.write!(Path.join(backup_dir, MutationBackup.manifest_name()), manifest_bytes)
    File.write!(Path.join(backup_dir, "part.0"), "backup-bytes")

    assert {:error, :epoch_missing} =
             ShardServer.restore_mutation(dir, %{
               target: t,
               token: tok,
               mutation_id: @id_a,
               final_rel: rel
             })

    assert File.read!(Path.join([dir, rel, "part.0"])) == "current-bytes"
    assert File.read!(Path.join(backup_dir, "part.0")) == "backup-bytes"
  end

  test "restore：published 而 manifest 缺失 → 结构化错误，epoch 不翻转", %{dir: dir} do
    key = "restore-no-manifest"
    t = target(key)
    rel = final_rel(key)
    write_final!(dir, rel, %{"part.0" => "new-part", "meta.json" => "new-meta"})

    tok = claim!(dir, t, 1, @id_a)
    publish!(dir, t, 1, @id_a, ObjectEpoch.fingerprint("etag-new", 8, "new-meta"))

    assert {:error, :backup_manifest_missing} =
             ShardServer.restore_mutation(dir, %{
               target: t,
               token: tok,
               mutation_id: @id_a,
               final_rel: rel
             })

    assert {:ok, %{"phase" => "published"}} = ShardServer.read_epoch(dir, t)
    assert File.read!(Path.join([dir, rel, "part.0"])) == "new-part"
  end

  test "finalize：published/committed replay 均重新取证；缺失 final 的同 token claimed 保持 cleanup debt",
       %{dir: dir} do
    site = proof_overwrite!(dir, "finalize-happy")

    assert {:ok, {:finalized, %{"mode" => "finalize", "finalized" => true}}} =
             ShardServer.finalize_mutation(dir, site.request)

    assert {:ok, %{"phase" => "committed"}} = ShardServer.read_epoch(dir, site.target)
    refute File.exists?(site.backup_dir)

    # committed 幂等重放同样先复验，再收敛。
    assert {:ok, {:finalized, %{"mode" => "finalize", "finalized" => true}}} =
             ShardServer.finalize_mutation(dir, site.request)

    # 同 token claimed 且 final 尚未 heal → 真实 endpoint proof failure（same-token 故
    # owned=true、proof_passed=false）；epoch 保持 claimed、backup 不删。
    claimed =
      proof_overwrite!(dir, "finalize-claimed", id: @id_b, publish: false, write_final: false)

    assert {:error,
            {:published_proof_failed, :corrupt,
             %{
               "scope" => "endpoint",
               "mode" => "finalize",
               "status" => "failed",
               "class" => "corrupt",
               "owned" => true,
               "proof_passed" => false,
               "finalized" => false
             }}} = ShardServer.finalize_mutation(dir, claimed.request)

    assert {:ok, %{"phase" => "claimed"}} = ShardServer.read_epoch(dir, claimed.target)
    assert File.dir?(claimed.backup_dir)

    # heal 写回 exact final 后重试仍必须 finalized。
    write_final!(dir, claimed.rel, %{
      "part.0" => claimed.part,
      "meta.json" => proof_sidecar("etag-finalize-claimed", claimed.part)
    })

    assert {:ok, {:finalized, %{"mode" => "finalize", "finalized" => true}}} =
             ShardServer.finalize_mutation(dir, claimed.request)

    assert {:ok, %{"phase" => "committed"}} = ShardServer.read_epoch(dir, claimed.target)
    refute File.exists?(claimed.backup_dir)
  end

  test "finalize：successor 已建立 → endpoint superseded，且在 final 探测前短路", %{dir: dir} do
    site = proof_overwrite!(dir, "finalize-superseded")
    _tok_b = claim!(dir, site.target, 2, @id_b)

    # final 整个移走：仍返回 superseded 即证明 successor 在任何 final 探测前短路。
    File.rm_rf!(site.final_dir)

    assert {:ok,
            {:superseded,
             %{
               "scope" => "endpoint",
               "mode" => "finalize",
               "status" => "superseded",
               "owned" => false,
               "class" => "fenced"
             }}} = ShardServer.finalize_mutation(dir, site.request)

    assert {:ok, %{"phase" => "claimed", "token" => %{"generation" => 2}}} =
             ShardServer.read_epoch(dir, site.target)

    # successor 的 epoch 与本 mutation 的 backup 均不被触碰。
    assert File.dir?(site.backup_dir)
  end

  test "restore/finalize 拒绝 token 与 mutation_id 不一致的请求", %{dir: dir} do
    t = target("id-mismatch")
    tok = token(1, @id_a)

    assert {:error, :mutation_id_mismatch} =
             ShardServer.restore_mutation(dir, %{
               target: t,
               token: tok,
               mutation_id: @id_b,
               final_rel: final_rel("id-mismatch")
             })

    # finalize 现在是完整六字段 proof request：token A / mutation_id B 属非法 request，
    # 必须成为有界 endpoint 失败，且不 owned、未通过 proof、未 finalize。
    assert {:error,
            {:published_proof_failed, :corrupt,
             %{
               "scope" => "endpoint",
               "mode" => "finalize",
               "status" => "failed",
               "class" => "corrupt",
               "code" => "invalid_request",
               "owned" => false,
               "proof_passed" => false,
               "finalized" => false
             }}} =
             ShardServer.finalize_mutation(dir, %{
               target: t,
               token: tok,
               mutation_id: @id_b,
               final_rel: final_rel("id-mismatch"),
               expected_fingerprint: ObjectEpoch.fingerprint("etag-x", 1, "meta-x"),
               layout: %{kind: "fs"}
             })
  end

  # --- Task 2 R1：ShardServer endpoint union RED ---

  @tag :task2_red_endpoint
  test "task2 red: ShardServer finalize_mutation exposes the proof-aware endpoint union", %{
    dir: dir
  } do
    key = "t2-shard-finalize"
    t = target(key)
    rel = final_rel(key)

    raw_meta =
      Jason.encode!(%{
        "format" => "maxio/2",
        "etag" => "etag-finalize",
        "size" => 5,
        "sha256" => String.duplicate("a", 64),
        "versions" => [%{"version_id" => "null", "type" => "object"}]
      })

    fingerprint = ObjectEpoch.fingerprint("etag-finalize", 5, raw_meta)
    _claimed = claim!(dir, t, 1, @id_a)
    backup_dir = Path.join(dir, MutationBackup.relative_dir(@id_a))
    File.mkdir_p!(backup_dir)
    write_final!(dir, rel, %{"part.0" => "proof", "meta.json" => raw_meta})
    tok = publish!(dir, t, 1, @id_a, fingerprint)

    request = %{
      target: t,
      token: tok,
      mutation_id: @id_a,
      final_rel: rel,
      expected_fingerprint: fingerprint,
      layout: %{kind: "fs"}
    }

    assert {:ok,
            {:finalized,
             %{
               "scope" => "endpoint",
               "mode" => "finalize",
               "endpoint" => "local",
               "status" => "finalized",
               "owned" => true,
               "proof_passed" => true,
               "finalized" => true
             }}} = ShardServer.finalize_mutation(dir, request)

    assert {:ok, %{"phase" => "committed"}} = ShardServer.read_epoch(dir, t)

    # 旧三字段 request 在任何 epoch/backup 变更之前失败关闭。
    obsolete_key = "t2-shard-obsolete"
    t2 = target(obsolete_key)
    _claimed2 = claim!(dir, t2, 1, @id_b)

    assert {:error,
            {:published_proof_failed, :corrupt,
             %{"scope" => "endpoint", "mode" => "finalize", "status" => "failed"}}} =
             ShardServer.finalize_mutation(dir, %{
               target: t2,
               token: token(1, @id_b),
               mutation_id: @id_b
             })

    assert {:ok, %{"phase" => "claimed"}} = ShardServer.read_epoch(dir, t2)
  end

  @tag :task2_red_endpoint
  test "task2 control: ShardServer endpoint proof stays bounded and path-free", %{dir: dir} do
    key = "t2-shard-no-leak"
    t = target(key)
    rel = final_rel(key)

    raw_meta =
      Jason.encode!(%{
        "format" => "maxio/2",
        "etag" => "etag-bounded",
        "size" => 5,
        "sha256" => String.duplicate("b", 64),
        "versions" => [%{"version_id" => "null", "type" => "object"}]
      })

    fingerprint = ObjectEpoch.fingerprint("etag-bounded", 5, raw_meta)
    _claimed = claim!(dir, t, 1, @id_a)
    tok = publish!(dir, t, 1, @id_a, fingerprint)
    write_final!(dir, rel, %{"part.0" => "proof", "meta.json" => raw_meta})

    assert {:ok, {:verified, summary}} =
             ShardServer.verify_mutation(dir, %{
               target: t,
               token: tok,
               mutation_id: @id_a,
               final_rel: rel,
               expected_fingerprint: fingerprint,
               layout: %{kind: "fs"}
             })

    refute Enum.any?(~w(path root drive node final_rel backup), &Map.has_key?(summary, &1))

    rendered = inspect(summary)
    refute rendered =~ dir
    refute rendered =~ raw_meta
  end

  test "list_dir 跳过 .maxio-object-epochs / .maxio-object-mutations 内部根", %{dir: dir} do
    for root <- [".maxio-object-epochs", ".maxio-object-mutations", "bucket-a"] do
      File.mkdir_p!(Path.join(dir, root))
    end

    assert {:ok, entries} = ShardServer.list_dir(dir)
    assert Enum.map(entries, & &1.name) == ["bucket-a"]
  end
end
