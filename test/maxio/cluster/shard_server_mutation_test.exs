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
    %{target: t, rel: rel, token: tok, final_dir: final_dir} =
      published_overwrite!(dir, "restore-committed")

    assert {:ok, :finalized} =
             ShardServer.finalize_mutation(dir, %{target: t, token: tok, mutation_id: @id_a})

    assert {:error, :epoch_committed} =
             ShardServer.restore_mutation(dir, %{
               target: t,
               token: tok,
               mutation_id: @id_a,
               final_rel: rel
             })

    assert File.read!(Path.join(final_dir, "part.0")) == "new-part"
    assert {:ok, %{"phase" => "committed"}} = ShardServer.read_epoch(dir, t)
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

  test "finalize：published → committed + backup 清空；幂等；claimed 拒绝", %{dir: dir} do
    %{target: t, token: tok, backup_dir: backup_dir} =
      published_overwrite!(dir, "finalize-happy")

    request = %{target: t, token: tok, mutation_id: @id_a}

    assert {:ok, :finalized} = ShardServer.finalize_mutation(dir, request)
    assert {:ok, %{"phase" => "committed"}} = ShardServer.read_epoch(dir, t)
    refute File.exists?(backup_dir)

    # 幂等重放
    assert {:ok, :finalized} = ShardServer.finalize_mutation(dir, request)

    # claimed 阶段的 finalize 拒绝（phase ∈ published/committed 之外）
    t2 = target("finalize-claimed")
    tok2 = claim!(dir, t2, 1, @id_b)

    assert {:error, {:unexpected_epoch_phase, "claimed"}} =
             ShardServer.finalize_mutation(dir, %{target: t2, token: tok2, mutation_id: @id_b})
  end

  test "finalize：successor 已建立 → :superseded", %{dir: dir} do
    %{target: t, token: tok_a} = published_overwrite!(dir, "finalize-superseded")
    _tok_b = claim!(dir, t, 2, @id_b)

    assert {:ok, :superseded} =
             ShardServer.finalize_mutation(dir, %{target: t, token: tok_a, mutation_id: @id_a})

    assert {:ok, %{"phase" => "claimed", "token" => %{"generation" => 2}}} =
             ShardServer.read_epoch(dir, t)
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

    assert {:error, :mutation_id_mismatch} =
             ShardServer.finalize_mutation(dir, %{target: t, token: tok, mutation_id: @id_b})
  end

  test "list_dir 跳过 .maxio-object-epochs / .maxio-object-mutations 内部根", %{dir: dir} do
    for root <- [".maxio-object-epochs", ".maxio-object-mutations", "bucket-a"] do
      File.mkdir_p!(Path.join(dir, root))
    end

    assert {:ok, entries} = ShardServer.list_dir(dir)
    assert Enum.map(entries, & &1.name) == ["bucket-a"]
  end
end
