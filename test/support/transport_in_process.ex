defmodule Maxio.Cluster.Transport.InProcess do
  @moduledoc """
  进程内多节点分片传输（M7 test，铁律 2 测试注入）。把每个 {node, drive_obj_dir} 端点直接
  映射到本机真实路径（drive_obj_dir 本身已是绝对路径，因 test 拓扑的 drive 用临时目录），
  即「同一台机器模拟 N 节点」。可经 set_down/1 在运行中「打掉」某 node：
  其 get_shard -> nil、写/heal -> {:error, :unavailable}/{:ok,0}（模拟宕机），用于验证
  K-of-N 重建、write_quorum 失败、heal-after-return。本地 ShardServer 复用真实分片 IO 逻辑。

  状态存一个全局 ETS 表（键 = node），setup!/0 清空。因 @table 全局，含 set_down 的测试须 async: false。
  """
  @behaviour Maxio.Cluster.Transport

  alias Maxio.Cluster.ShardServer

  @table :maxio_inproc_down

  @doc "确保 down 集合表存在并清空（测试 setup 调用一次）。"
  def setup! do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set])
    end

    :ets.delete_all_objects(@table)
    :ok
  end

  @doc "打掉某 node（其端点后续读 nil、写失败）。"
  def set_down(node), do: :ets.insert(@table, {node, true})

  @doc "恢复某 node。"
  def set_up(node), do: :ets.delete(@table, node)

  defp down?(node) do
    case :ets.whereis(@table) do
      :undefined -> false
      _ -> :ets.member(@table, node)
    end
  end

  @impl true
  def put_shard(node, dir, j, shard, shard_len) do
    if down?(node),
      do: {:error, :unavailable},
      else: ShardServer.put_shard(dir, j, shard, shard_len)
  end

  @impl true
  def get_shard(node, dir, j, shard_len) do
    if down?(node), do: nil, else: ShardServer.get_shard(dir, j, shard_len)
  end

  @impl true
  def put_sidecar(node, dir, meta) do
    if down?(node), do: {:error, :unavailable}, else: ShardServer.put_sidecar(dir, meta)
  end

  @impl true
  def get_sidecar(node, dir) do
    if down?(node), do: {:error, :enoent}, else: ShardServer.get_sidecar(dir)
  end

  @impl true
  def stat_shard(node, dir) do
    if down?(node), do: {:error, :enoent}, else: ShardServer.stat_shard(dir)
  end

  @impl true
  def delete_shard(node, dir) do
    if down?(node), do: :ok, else: ShardServer.delete_shard(dir)
  end

  @impl true
  def heal_shard(node, dir, block_map, shard_len, meta) do
    if down?(node), do: {:ok, 0}, else: ShardServer.heal_shard(dir, block_map, shard_len, meta)
  end

  @impl true
  def begin_tmp(node, drive_root) do
    if down?(node), do: {:error, :unavailable}, else: ShardServer.begin_tmp(drive_root)
  end

  @impl true
  def commit_object(node, tmp_dir, final_obj_dir, opts) do
    if down?(node),
      do: {:error, :unavailable},
      else: ShardServer.commit(tmp_dir, final_obj_dir, opts)
  end

  @impl true
  def list_dir(node, drive_dir, opts) do
    if down?(node), do: {:error, :unavailable}, else: ShardServer.list_dir(drive_dir, opts)
  end
end
