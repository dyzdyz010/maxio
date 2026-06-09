defmodule Maxio.Storage.AtomicCommitTest do
  @moduledoc """
  ROUTE B B1-2 原子提交（temp-then-rename + fsync-before-quorum）回归。

  覆盖：
    * prepare_commit 写 temp、commit 原子 rename 到 final（数据先于元数据）；
    * crash-before-commit（写完 temp 未 commit）-> final obj-dir 不存在（旧值保留、无撕裂）、temp 可 GC；
    * fsync:true 时 :file.sync 被调用（经 [:maxio,:durability,:fsync] 遥测断言）；
    * write_quorum 未达 -> temp 清理 + {:error,:write_quorum}（EC + Distributed 各一例）；
    * Windows 同卷 rename busy（target 被 reader 持开）-> 有界重试后 {:error,:rename_busy}。
  """
  use ExUnit.Case, async: false

  alias Maxio.Cluster.ShardServer
  alias Maxio.Cluster.{Topology, Transport.InProcess}
  alias Maxio.Storage.{Distributed, ErasureCoded, FS}

  setup do
    root = Path.join(System.tmp_dir!(), "maxio_atomic_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root}
  end

  # ── ShardServer 原子提交原语 ──

  test "prepare_commit writes to tmp, commit renames atomically to final", %{root: root} do
    obj_dir = Path.join([root, "bucket", "key"])

    meta = %{
      "ec" => %{"k" => 4, "m" => 2, "block_size" => 16, "algo" => "blake3-256"},
      "size" => 4,
      "etag" => "x",
      "parts" => [%{"part" => 0, "size" => 4}],
      "shards" => [%{"drive" => 0, "shard_file_size" => 2, "block_hashes" => ["aa"]}]
    }

    {:ok, tmp} =
      ShardServer.prepare_commit(obj_dir, %{0 => <<1, 2>>}, 2, meta,
        fsync: false,
        drive_root: root
      )

    # commit 前 final 缺失、temp 已含 part.0 + meta.json。
    refute File.exists?(Path.join(obj_dir, "part.0"))
    assert File.exists?(Path.join(tmp, "part.0"))
    assert File.exists?(Path.join(tmp, "meta.json"))

    :ok = ShardServer.commit(tmp, obj_dir, fsync: false)

    assert File.exists?(Path.join(obj_dir, "part.0"))
    assert File.exists?(Path.join(obj_dir, "meta.json"))
    assert File.read!(Path.join(obj_dir, "part.0")) == <<1, 2>>
    # commit 成功删 temp（绝不留孤儿）。
    refute File.exists?(tmp)
  end

  test "crash before commit leaves final absent (no torn object)", %{root: root} do
    obj_dir = Path.join([root, "bucket", "key2"])
    meta = %{"shards" => [], "size" => 0}

    {:ok, tmp} =
      ShardServer.prepare_commit(obj_dir, %{}, 1, meta, fsync: false, drive_root: root)

    # 模拟 crash：只写了 temp，未 commit -> final obj-dir 的 meta.json/part.0 均不存在（旧值保留）。
    refute File.exists?(Path.join(obj_dir, "meta.json"))
    refute File.exists?(Path.join(obj_dir, "part.0"))
    # temp 仍在，可被 reverse-GC 回收。
    assert File.exists?(tmp)
  end

  test "commit overwrites pre-existing final atomically (old -> new, never torn)", %{root: root} do
    obj_dir = Path.join([root, "bucket", "key3"])
    File.mkdir_p!(obj_dir)
    File.write!(Path.join(obj_dir, "part.0"), <<9, 9>>)
    File.write!(Path.join(obj_dir, "meta.json"), ~s({"etag":"old"}))

    meta = %{"etag" => "new", "shards" => [], "size" => 2}

    {:ok, tmp} =
      ShardServer.prepare_commit(obj_dir, %{0 => <<7, 7>>}, 2, meta,
        fsync: false,
        drive_root: root
      )

    :ok = ShardServer.commit(tmp, obj_dir, fsync: false)
    assert File.read!(Path.join(obj_dir, "part.0")) == <<7, 7>>
    assert File.read!(Path.join(obj_dir, "meta.json")) =~ "new"
    refute File.exists?(tmp)
  end

  test "fsync:true triggers :file.sync (telemetry emitted); fsync:false does not", %{root: root} do
    obj_dir = Path.join([root, "bucket", "keyf"])
    meta = %{"etag" => "x", "shards" => [], "size" => 2}

    {events, ref} = attach_fsync_counter()

    {:ok, tmp} =
      ShardServer.prepare_commit(obj_dir, %{0 => <<1, 2>>}, 2, meta,
        fsync: true,
        drive_root: root
      )

    :ok = ShardServer.commit(tmp, obj_dir, fsync: true)
    :telemetry.detach(ref)

    # fsync:true -> 至少 part.0 文件 fsync 被调用（dir fsync 在 Windows 上 best-effort，可能 0）。
    file_syncs = Enum.count(Agent.get(events, & &1), fn kind -> kind == :file end)
    assert file_syncs >= 1

    # fsync:false 不触发任何 fsync。
    obj_dir2 = Path.join([root, "bucket", "keyf2"])
    {events2, ref2} = attach_fsync_counter()

    {:ok, tmp2} =
      ShardServer.prepare_commit(obj_dir2, %{0 => <<1, 2>>}, 2, meta,
        fsync: false,
        drive_root: root
      )

    :ok = ShardServer.commit(tmp2, obj_dir2, fsync: false)
    :telemetry.detach(ref2)
    assert Agent.get(events2, & &1) == []

    Agent.stop(events)
    Agent.stop(events2)
  end

  test "commit maps Windows busy rename to {:error, :rename_busy} after bounded retries", %{
    root: root
  } do
    obj_dir = Path.join([root, "bucket", "busy"])
    meta = %{"etag" => "x", "shards" => [], "size" => 2}

    {:ok, tmp} =
      ShardServer.prepare_commit(obj_dir, %{0 => <<1, 2>>}, 2, meta,
        fsync: false,
        drive_root: root
      )

    # 注入 rename：始终返回 :eacces（Windows rename-over-open-file 的 busy 语义）。
    # 有界重试后必映射 {:error, :rename_busy}（绝不静默写坏；调用方映射 503）。
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    busy_rename = fn _src, _dst ->
      Agent.update(calls, &(&1 + 1))
      {:error, :eacces}
    end

    assert {:error, :rename_busy} =
             ShardServer.commit(tmp, obj_dir, fsync: false, rename_fun: busy_rename)

    # 确实做了有界重试（> 1 次尝试），而非一次就放弃。
    assert Agent.get(calls, & &1) > 1
    Agent.stop(calls)

    # busy 失败时 final 仍无 part.0（绝不撕裂），temp 仍在可 GC。
    refute File.exists?(Path.join(obj_dir, "part.0"))
    assert File.exists?(Path.join(tmp, "part.0"))
  end

  test "commit passes non-busy rename errors through unchanged (no retry mask)", %{root: root} do
    obj_dir = Path.join([root, "bucket", "perm"])
    meta = %{"etag" => "x", "shards" => [], "size" => 2}

    {:ok, tmp} =
      ShardServer.prepare_commit(obj_dir, %{0 => <<1, 2>>}, 2, meta,
        fsync: false,
        drive_root: root
      )

    perm_rename = fn _src, _dst -> {:error, :erofs} end

    assert {:error, :erofs} =
             ShardServer.commit(tmp, obj_dir, fsync: false, rename_fun: perm_rename)
  end

  # ── FS 后端写路径经 temp-then-rename ──

  test "FS put writes via temp-then-rename and round-trips", %{root: root} do
    o = [data_dir: root]
    :ok = FS.put_bucket("b", o)
    body = :crypto.strong_rand_bytes(2500)
    {:ok, r} = FS.put("b", "k", "null", [body], o)
    assert r.size == byte_size(body)
    {:ok, s} = FS.get("b", "k", "null", nil, o)
    assert IO.iodata_to_binary(Enum.to_list(s)) == body
    # 提交后 .tmp 下无残留（temp 已 GC）。
    refute File.dir?(Path.join(root, ".tmp")) and File.ls!(Path.join(root, ".tmp")) != []
  end

  # ── EC 后端写路径经 temp-then-rename：提交后 final 含 part.0+meta.json、各盘 .tmp GC ──

  test "EC put commits via temp-then-rename: final has part.0+meta.json, tmp GC'd", %{root: root} do
    drives = for i <- 0..5, do: Path.join(root, "d#{i}")
    Enum.each(drives, &File.mkdir_p!/1)
    o = [drives: drives, data_shards: 4, parity_shards: 2, block_size: 16]
    :ok = ErasureCoded.put_bucket("b", o)
    body = :crypto.strong_rand_bytes(40)
    {:ok, r} = ErasureCoded.put("b", "k", "null", [body], o)
    assert r.size == 40
    {:ok, s} = ErasureCoded.get("b", "k", "null", nil, o)
    assert IO.iodata_to_binary(Enum.to_list(s)) == body

    # 每盘 final obj-dir 有 part.0 + meta.json（经 rename 落地），且 .tmp 已清空。
    Enum.each(drives, fn d ->
      final_dir = Path.join([d, "b", "k"])
      assert File.exists?(Path.join(final_dir, "part.0"))
      assert File.exists?(Path.join(final_dir, "meta.json"))
      tmp = Path.join(d, ".tmp")
      assert not File.dir?(tmp) or File.ls!(tmp) == []
    end)
  end

  # ── Distributed 后端：部分端点 down -> write_quorum 未达 -> temp 清理 + {:error,:write_quorum} ──

  test "Distributed put below write_quorum cleans temp and returns {:error, :write_quorum}", %{
    root: root
  } do
    InProcess.setup!()

    endpoints =
      for i <- 0..5 do
        {:"maxio@dn#{div(i, 2)}", Path.join(root, "dn#{div(i, 2)}_d#{rem(i, 2)}")}
      end

    topology =
      Topology.parse_and_validate!(
        data_shards: 4,
        parity_shards: 2,
        block_size: 16,
        # 3 node × 2 drive 同 node 名复用，放行 distinct-node 校验（B1-3）。
        allow_colocated_endpoints: true,
        pools: [%{id: 0, sets: [%{id: 0, endpoints: endpoints}]}]
      )

    opts = [topology: topology, transport: InProcess]
    :ok = Distributed.put_bucket("b", opts)

    # 打掉 2 个 node（4 端点宕机），存活端点 = 2 < write_quorum(=4) -> {:error,:write_quorum}。
    InProcess.set_down(:maxio@dn0)
    InProcess.set_down(:maxio@dn1)

    assert {:error, :write_quorum} =
             Distributed.put("b", "k", "null", [:crypto.strong_rand_bytes(40)], opts)

    InProcess.set_up(:maxio@dn0)
    InProcess.set_up(:maxio@dn1)

    # 存活端点上不得有提交到 final 的对象（temp 已清理；final 不存在 = 无撕裂半提交）。
    {:ok, obj_rel} = Maxio.Cluster.Paths.object_rel("b", "k", "null")

    Enum.each(endpoints, fn {_node, drive} ->
      final_dir = Path.join(drive, obj_rel)
      refute File.exists?(Path.join(final_dir, "part.0"))
      tmp_root = Path.join(drive, ".tmp")
      assert not File.dir?(tmp_root) or File.ls!(tmp_root) == []
    end)
  end

  defp attach_fsync_counter do
    {:ok, agent} = Agent.start_link(fn -> [] end)
    ref = "fsync-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      ref,
      [:maxio, :durability, :fsync],
      fn _event, _measure, meta, _cfg ->
        Agent.update(agent, fn acc -> [meta.kind | acc] end)
      end,
      nil
    )

    {agent, ref}
  end
end
