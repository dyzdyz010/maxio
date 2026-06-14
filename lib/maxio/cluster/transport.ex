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
  @callback stat_shard_info(node(), String.t()) ::
              {:ok, %{size: non_neg_integer(), mtime_ms: integer()}} | {:error, :enoent}
  @callback delete_shard(node(), String.t()) :: :ok
  @callback delete_part_file(node(), String.t()) :: :ok | {:error, term()}
  @callback quarantine_layout_roots(node(), String.t(), [String.t()], String.t(), map()) ::
              {:ok, map()} | {:error, term()}
  @callback purge_quarantine_root(node(), String.t(), String.t(), map()) ::
              {:ok, map()} | {:error, term()}
  @callback preflight_quarantine_purge_root(node(), String.t(), String.t(), map()) ::
              {:ok, map()} | {:error, term()}
  @callback heal_shard(node(), String.t(), %{non_neg_integer() => binary()}, pos_integer(), map()) ::
              {:ok, non_neg_integer()}

  # 原子提交（ROUTE B B1-2）：begin_tmp 在端点 drive_root 下建同卷 temp obj-dir；逐块 put_shard /
  # put_sidecar 写进该 tmp_dir；commit_object fsync + 数据先于元数据原子 rename 到 final。
  @callback begin_tmp(node(), String.t()) :: {:ok, String.t()} | {:error, term()}
  @callback commit_object(node(), String.t(), String.t(), keyword()) :: :ok | {:error, term()}

  # 走盘 LIST 单层目录原语（ROUTE B P3）：读单端点 drive_dir 下一层条目并标记每个子目录是否为对象。
  # opts[:include_layout_files] 为 scanner orphan-shard 取证专用；默认 false 时保持只返回目录。
  # 节点宕机/超时/远端异常 -> {:error, :unavailable}（铁律 3：结构化降级，绝不上抛炸列举路径）。
  @callback list_dir(node(), String.t(), keyword()) ::
              {:ok, [%{name: String.t(), object?: boolean()}]} | {:error, term()}
  @callback probe_drive(node(), String.t()) :: :ok | {:error, term()}
  @callback probe_drive_identity(node(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback drive_hardware_evidence(node(), String.t(), keyword()) ::
              {:ok, map()} | {:error, term()}
  @callback drive_stats(node(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback pressure_snapshot(node(), keyword()) :: {:ok, map()} | {:error, term()}

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
  @pressure_timeout 50

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
  def stat_shard_info(node, dir) do
    call(node, :stat_shard_info, [dir], fn -> {:error, :enoent} end)
  end

  @impl true
  def delete_shard(node, dir) do
    call(node, :delete_shard, [dir], fn -> :ok end)
  end

  @impl true
  def delete_part_file(node, dir) do
    call(node, :delete_part_file, [dir], fn -> {:error, :unavailable} end)
  end

  @impl true
  def quarantine_layout_roots(node, drive_root, bucket_names, quarantine_id, marker) do
    call(
      node,
      :quarantine_layout_roots,
      [drive_root, bucket_names, quarantine_id, marker],
      fn -> {:error, :unavailable} end
    )
  end

  @impl true
  def purge_quarantine_root(node, drive_root, quarantine_id, expected_marker) do
    call(
      node,
      :purge_quarantine_root,
      [drive_root, quarantine_id, expected_marker],
      fn -> {:error, :unavailable} end
    )
  end

  @impl true
  def preflight_quarantine_purge_root(node, drive_root, quarantine_id, expected_marker) do
    call(
      node,
      :preflight_quarantine_purge_root,
      [drive_root, quarantine_id, expected_marker],
      fn -> {:error, :unavailable} end
    )
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

  @impl true
  def probe_drive(node, drive_root) do
    call(node, :probe_drive, [drive_root], fn -> {:error, :unavailable} end)
  end

  @impl true
  def probe_drive_identity(node, drive_root, opts \\ []) do
    call(node, :probe_drive_identity, [drive_root, opts], fn -> {:error, :unavailable} end)
  end

  @impl true
  def drive_hardware_evidence(node, drive_root, opts \\ []) do
    call(node, :drive_hardware_evidence, [drive_root, opts], fn -> {:error, :unavailable} end)
  end

  @impl true
  def drive_stats(node, drive_root, opts \\ []) do
    call(node, :drive_stats, [drive_root, opts], fn -> {:error, :unavailable} end)
  end

  @impl true
  def pressure_snapshot(node, opts \\ []) do
    timeout = Keyword.get(opts, :timeout_ms, @pressure_timeout)

    if node == Node.self() do
      {:ok, Maxio.Cluster.IOPressure.local_snapshot()}
    else
      try do
        {:ok, :erpc.call(node, Maxio.Cluster.IOPressure, :local_snapshot, [], timeout)}
      catch
        :error, _reason -> {:error, :unavailable}
        :exit, _reason -> {:error, :unavailable}
        :throw, _reason -> {:error, :unavailable}
      end
    end
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
