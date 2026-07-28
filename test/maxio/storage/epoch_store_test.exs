defmodule Maxio.Storage.EpochStoreTest do
  use ExUnit.Case, async: true

  alias Maxio.Storage.{EpochStore, ObjectEpoch}

  @bucket "epoch-store-test"
  @id_1 "00000000-0000-0000-0000-000000000001"
  @id_2 "00000000-0000-0000-0000-000000000002"
  @id_3 "00000000-0000-0000-0000-000000000003"

  setup do
    dir =
      Path.join(System.tmp_dir!(), "maxio_epoch_store_#{System.unique_integer([:positive])}")

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

  defp epoch(target, gen, id, attrs \\ %{}) do
    defaults = %{
      operation: "put",
      phase: "claimed",
      value_type: "object",
      updated_at: DateTime.utc_now()
    }

    {:ok, epoch} = ObjectEpoch.new(target, token(gen, id), Map.merge(defaults, attrs))
    epoch
  end

  defp epoch_path(dir, target) do
    {:ok, rel} = ObjectEpoch.relative_path(target)
    Path.join(dir, rel)
  end

  defp fingerprint, do: ObjectEpoch.fingerprint("etag", 4, "meta")

  # 断言 1：claim fence——absent 通过；current gen=5 拒绝 gen=5（更小 mutation_id）与 gen<5；
  # 接受 {5, 更大 mutation_id} 与 gen=6（fence 全序落点）。
  test "claim fence：absent 通过，仅接受严格更大 token", %{dir: dir} do
    t = target("claim-fence")
    tok_5_2 = token(5, @id_2)

    assert {:ok, :applied} = EpochStore.cas(dir, epoch(t, 5, @id_2), {:claim, tok_5_2})

    # 同代更小 mutation_id → fenced
    assert {:error, {:fenced, ^tok_5_2}} =
             EpochStore.cas(dir, epoch(t, 5, @id_1), {:claim, token(5, @id_1)})

    # 更小 generation → fenced
    assert {:error, {:fenced, ^tok_5_2}} =
             EpochStore.cas(dir, epoch(t, 4, @id_3), {:claim, token(4, @id_3)})

    # 同 token 重复 claim → fenced（严格 :gt）
    assert {:error, {:fenced, ^tok_5_2}} =
             EpochStore.cas(dir, epoch(t, 5, @id_2), {:claim, tok_5_2})

    # {5, 更大 mutation_id} 接受
    assert {:ok, :applied} = EpochStore.cas(dir, epoch(t, 5, @id_3), {:claim, token(5, @id_3)})

    # gen=6 接受
    tok_6 = token(6, @id_1)
    assert {:ok, :applied} = EpochStore.cas(dir, epoch(t, 6, @id_1), {:claim, tok_6})
    assert {:ok, %ObjectEpoch{token: ^tok_6, phase: "claimed"}} = EpochStore.read(dir, t)
  end

  # 断言 2：{:exact,...} 遇 absent → {:error, :epoch_missing}（nil/:enoent 不授权落点）。
  test "{:exact, ...} 遇 absent → :epoch_missing 且不产生任何写入", %{dir: dir} do
    t = target("exact-absent")
    published = epoch(t, 1, @id_1, %{phase: "published", fingerprint: fingerprint()})

    assert {:error, :epoch_missing} =
             EpochStore.cas(dir, published, {:exact, token(1, @id_1), ["claimed"]})

    refute File.exists?(epoch_path(dir, t))
    assert {:ok, :absent} = EpochStore.read(dir, t)
  end

  test "exact CAS 校验 token 与 phase（fenced 携带当前 token）", %{dir: dir} do
    t = target("exact-check")
    tok = token(5, @id_2)
    assert {:ok, :applied} = EpochStore.cas(dir, epoch(t, 5, @id_2), {:claim, tok})

    # phase 不在允许集 → fenced
    published = epoch(t, 5, @id_2, %{phase: "published", fingerprint: fingerprint()})

    assert {:error, {:fenced, ^tok}} =
             EpochStore.cas(dir, published, {:exact, tok, ["published"]})

    # token 不匹配 → fenced
    other = epoch(t, 6, @id_1, %{phase: "published", fingerprint: fingerprint()})

    assert {:error, {:fenced, ^tok}} =
             EpochStore.cas(dir, other, {:exact, token(6, @id_1), ["claimed"]})

    # next.token 与 expect token 不一致 → 结构化拒绝，不触盘
    assert {:error, :expect_token_mismatch} =
             EpochStore.cas(dir, other, {:exact, tok, ["claimed"]})

    assert {:error, :invalid_expect} = EpochStore.cas(dir, published, {:exact, tok, []})

    # 合法 exact：claimed → published
    assert {:ok, :applied} = EpochStore.cas(dir, published, {:exact, tok, ["claimed"]})
    assert {:ok, %ObjectEpoch{phase: "published"}} = EpochStore.read(dir, t)
  end

  # 断言 3：并发 CAS 串行执行——最终 epoch 恰为全序最大 token，无 lost update。
  test "并发 claim 串行执行：generation 单调、无 lost update", %{dir: dir} do
    t = target("concurrent")
    n = 25

    results =
      1..n
      |> Task.async_stream(
        fn gen ->
          EpochStore.cas(dir, epoch(t, gen, @id_1), {:claim, token(gen, @id_1)})
        end,
        max_concurrency: n,
        ordered: false,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    # 每个结果要么应用、要么被更大 token fence——绝无静默丢失。
    assert Enum.all?(results, fn
             {:ok, :applied} -> true
             {:error, {:fenced, _current}} -> true
             _other -> false
           end)

    # gen=n 的 claim 必然成功（任何时刻 current < n）；若 read-validate-write 非原子，
    # 迟到的旧 claim 会覆写它——最终 token 恰为全序最大即无 lost update 的判据。
    tok_n = token(n, @id_1)
    assert {:ok, %ObjectEpoch{token: ^tok_n}} = EpochStore.read(dir, t)
  end

  # 断言 5：损坏 epoch → {:corrupt, _}，文件未被覆盖。
  test "损坏 epoch JSON → {:corrupt, _}，绝不静默覆盖", %{dir: dir} do
    t = target("corrupt")
    path = epoch_path(dir, t)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "{not json")

    assert {:error, {:corrupt, _reason}} = EpochStore.read(dir, t)

    assert {:error, {:corrupt, _reason}} =
             EpochStore.cas(dir, epoch(t, 9, @id_1), {:claim, token(9, @id_1)})

    assert File.read!(path) == "{not json"

    # 合法 JSON 但未知 format 同样按 corrupt 上报（decode 拒绝，不静默接受）。
    File.write!(path, Jason.encode!(%{"format" => "maxio/object-epoch/99"}))

    assert {:error, {:corrupt, {:unsupported_epoch_format, _}}} = EpochStore.read(dir, t)
  end

  # 断言 6：Windows 上 CAS 覆盖已存在 epoch.json 成功（rename-替换语义验证，风险 R3）。
  test "CAS 覆盖已存在 epoch.json 成功（Windows rename-替换语义）", %{dir: dir} do
    t = target("overwrite")
    path = epoch_path(dir, t)

    assert {:ok, :applied} = EpochStore.cas(dir, epoch(t, 1, @id_1), {:claim, token(1, @id_1)})
    assert File.exists?(path)
    first = File.read!(path)

    # 覆盖已存在文件：exact 推进 phase
    published = epoch(t, 1, @id_1, %{phase: "published", fingerprint: fingerprint()})

    assert {:ok, :applied} =
             EpochStore.cas(dir, published, {:exact, token(1, @id_1), ["claimed"]})

    assert File.read!(path) != first
    assert {:ok, %ObjectEpoch{phase: "published"}} = EpochStore.read(dir, t)

    # 再次覆盖：更大 token 的 claim
    assert {:ok, :applied} = EpochStore.cas(dir, epoch(t, 2, @id_2), {:claim, token(2, @id_2)})
    tok_2 = token(2, @id_2)
    assert {:ok, %ObjectEpoch{token: ^tok_2, phase: "claimed"}} = EpochStore.read(dir, t)

    # 两步替换的暂存残留不外泄
    refute File.exists?(path <> ".stale")
    refute File.exists?(path <> ".tmp")
  end

  test "read 对不存在的 target 返回显式 :absent", %{dir: dir} do
    assert {:ok, :absent} = EpochStore.read(dir, target("missing"))
  end

  # B1 遗留 2（B4 收口 erpc 暴露面）：final_rel 会成为 Path.join(drive_root, final_rel)
  # 的盘上回位落点——穿越形态结构化拒绝，与 mutation_id/manifest entry 名防线对称。
  test "restore_mutation 拒绝 final_rel 穿越形态，绝不触盘", %{dir: dir} do
    t = target("final-rel")
    tok = token(1, @id_1)
    assert {:ok, :applied} = EpochStore.cas(dir, epoch(t, 1, @id_1), {:claim, tok})
    epoch_before = File.read!(epoch_path(dir, t))

    for final_rel <- ["", "..", "../escape", "a/../b", "a//b", "a/./b", "a\\b", "/abs/path"] do
      request = %{target: t, token: tok, mutation_id: @id_1, final_rel: final_rel}

      assert {:error, {:invalid_final_rel, ^final_rel}} =
               EpochStore.restore_mutation(dir, request)
    end

    # 拒绝路径不触盘：epoch 字节不变、无任何 backup/final 目录被创建
    assert File.read!(epoch_path(dir, t)) == epoch_before
    refute File.exists?(Path.join(dir, ".maxio-object-mutations"))

    # 合法 final_rel 照常执行（claimed 无 manifest → 仅翻转 epoch + 清残留备份目录）
    assert {:ok, :restored} =
             EpochStore.restore_mutation(dir, %{
               target: t,
               token: tok,
               mutation_id: @id_1,
               final_rel: "bucket/key"
             })

    assert {:ok, %ObjectEpoch{phase: "rolled_back"}} = EpochStore.read(dir, t)
  end
end
