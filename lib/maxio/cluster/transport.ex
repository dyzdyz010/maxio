defmodule Maxio.Cluster.Transport do
  @moduledoc """
  跨节点分片传输契约（M7）。prod = :erpc 到每节点 Maxio.Cluster.ShardServer；
  test = 进程内多盘（Maxio.Cluster.Transport.InProcess，可注入端点宕机）。
  铁律 2：分布式后端只认本 behaviour，换传输（:erpc / gRPC / HTTP）不动后端。
  铁律 4：put_shard/get_shard 逐 (block, shard)，绝不一次传整对象/整文件。

  约定：drive_obj_dir = Path.join(drive, obj_rel)，由后端用 Topology 端点的 drive +
  Maxio.Cluster.Paths.object_rel/3 组装后传入；node 决定调哪个节点。
  节点宕机/超时/远端异常：get_shard -> nil（交 EC 重建）；put_shard/put_sidecar -> {:error, :unavailable}。
  """
  @callback put_shard(node(), String.t(), non_neg_integer(), binary(), pos_integer()) ::
              :ok | {:error, term()}
  @callback get_shard(node(), String.t(), non_neg_integer(), pos_integer()) :: binary() | nil
  @callback put_sidecar(node(), String.t(), map()) :: :ok | {:error, term()}
  @callback get_sidecar(node(), String.t()) :: {:ok, map()} | {:error, :enoent}
  @callback stat_shard(node(), String.t()) :: {:ok, non_neg_integer()} | {:error, :enoent}
  @callback delete_shard(node(), String.t()) :: :ok
  @callback heal_shard(node(), String.t(), %{non_neg_integer() => binary()}, pos_integer(), map()) ::
              {:ok, non_neg_integer()}

  # 原子提交（ROUTE B B1-2）：begin_tmp 在端点 drive_root 下建同卷 temp obj-dir；逐块 put_shard /
  # put_sidecar 写进该 tmp_dir；commit_object fsync + 数据先于元数据原子 rename 到 final。
  @callback begin_tmp(node(), String.t()) :: {:ok, String.t()} | {:error, term()}
  @callback commit_object(node(), String.t(), String.t(), keyword()) :: :ok | {:error, term()}

  # 走盘 LIST 单层目录原语（ROUTE B P3）：读单端点 drive_dir 下一层条目并标记每个子目录是否为对象。
  # 节点宕机/超时/远端异常 -> {:error, :unavailable}（铁律 3：结构化降级，绝不上抛炸列举路径）。
  @callback list_dir(node(), String.t(), keyword()) ::
              {:ok, [%{name: String.t(), object?: boolean()}]} | {:error, term()}

  @doc "当前配置的传输实现（test 经 opts[:transport] 覆盖；缺省 config :maxio, :shard_transport）。"
  @spec impl(keyword()) :: module()
  def impl(opts \\ []) do
    Keyword.get(opts, :transport) ||
      Application.get_env(:maxio, :shard_transport, Maxio.Cluster.Transport.Erpc)
  end
end

defmodule Maxio.Cluster.Transport.Erpc do
  @moduledoc """
  :erpc 分片传输（prod，M7）。把每个端点 op 作为一条 :erpc 调用到该 node 的 Maxio.Cluster.ShardServer。
  铁律 3：节点 down（{:erpc, :noconnection}）/ 超时（{:erpc, :timeout}）/ 远端异常 ->
  get_shard nil、写 {:error, :unavailable}（绝不静默成功，绝不把异常上抛炸后端）。
  本地节点（node == Node.self()）直接函数调用，跳过 :erpc（省序列化）。
  """
  @behaviour Maxio.Cluster.Transport

  alias Maxio.Cluster.ShardServer

  @timeout 5_000

  @impl true
  def put_shard(node, dir, j, shard, shard_len) do
    call(node, :put_shard, [dir, j, shard, shard_len], fn -> {:error, :unavailable} end)
  end

  @impl true
  def get_shard(node, dir, j, shard_len) do
    call(node, :get_shard, [dir, j, shard_len], fn -> nil end)
  end

  @impl true
  def put_sidecar(node, dir, meta) do
    call(node, :put_sidecar, [dir, meta], fn -> {:error, :unavailable} end)
  end

  @impl true
  def get_sidecar(node, dir) do
    call(node, :get_sidecar, [dir], fn -> {:error, :enoent} end)
  end

  @impl true
  def stat_shard(node, dir) do
    call(node, :stat_shard, [dir], fn -> {:error, :enoent} end)
  end

  @impl true
  def delete_shard(node, dir) do
    call(node, :delete_shard, [dir], fn -> :ok end)
  end

  @impl true
  def heal_shard(node, dir, block_map, shard_len, meta) do
    call(node, :heal_shard, [dir, block_map, shard_len, meta], fn -> {:ok, 0} end)
  end

  @impl true
  def begin_tmp(node, drive_root) do
    call(node, :begin_tmp, [drive_root], fn -> {:error, :unavailable} end)
  end

  @impl true
  def commit_object(node, tmp_dir, final_obj_dir, opts) do
    call(node, :commit, [tmp_dir, final_obj_dir, opts], fn -> {:error, :unavailable} end)
  end

  @impl true
  def list_dir(node, drive_dir, opts) do
    call(node, :list_dir, [drive_dir, opts], fn -> {:error, :unavailable} end)
  end

  # 本地直接调；远端 :erpc。任何宕机/超时/异常 -> on_fail 兜底（铁律 3：结构化降级，绝不上抛）。
  defp call(node, fun, args, on_fail) do
    if node == Node.self() do
      apply(ShardServer, fun, args)
    else
      try do
        :erpc.call(node, ShardServer, fun, args, @timeout)
      catch
        # 节点 down（{:erpc, :noconnection}）/超时（{:erpc, :timeout}）/远端异常均经
        # :erlang.error 抛出（class :error），远端进程退出经 class :exit；显式 throw 经 :throw。
        # 三类统一兜底为 on_fail（铁律 3：结构化降级，绝不上抛炸后端）。
        :error, _reason -> on_fail.()
        :exit, _reason -> on_fail.()
        :throw, _reason -> on_fail.()
      end
    end
  end
end
