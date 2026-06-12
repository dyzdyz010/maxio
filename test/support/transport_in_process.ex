defmodule Maxio.Cluster.Transport.InProcess do
  @moduledoc """
  In-process multi-node transport used by distributed-storage tests.

  The down-state table can mark either a whole node or one drive root on a node as
  unavailable. Drive-level faults are intentionally path-scoped so tests can model
  a single failed disk while sibling drives on the same node remain reachable.
  """
  @behaviour Maxio.Cluster.Transport

  alias Maxio.Cluster.ShardServer

  @table :maxio_inproc_down

  @doc "Ensure the down-state ETS table exists and is empty."
  def setup! do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set])
    end

    :ets.delete_all_objects(@table)
    :ok
  end

  @doc "Mark a whole node as unavailable."
  def set_down(node), do: :ets.insert(@table, {{:node, node}, true})

  @doc "Restore a whole node."
  def set_up(node), do: :ets.delete(@table, {:node, node})

  @doc "Mark one drive root on a node as unavailable."
  def set_drive_down(node, drive),
    do: :ets.insert(@table, {{:drive, node, normalize_path(drive)}, true})

  @doc "Restore one drive root on a node."
  def set_drive_up(node, drive), do: :ets.delete(@table, {:drive, node, normalize_path(drive)})

  @doc "Set an injected node-local pressure snapshot for a simulated node."
  def set_pressure_snapshot(node, snapshot),
    do: :ets.insert(@table, {{:pressure, node}, normalize_pressure_snapshot(snapshot)})

  @doc "Clear an injected node-local pressure snapshot for a simulated node."
  def clear_pressure_snapshot(node), do: :ets.delete(@table, {:pressure, node})

  @doc "Fail heal_shard for one drive while keeping probes online."
  def set_heal_shard_down(node, drive), do: set_op_down(:heal_shard, node, drive)

  @doc "Fail put_sidecar for one drive while keeping probes online."
  def set_put_sidecar_down(node, drive), do: set_op_down(:put_sidecar, node, drive)

  @doc "Fail delete_part_file for one drive while keeping probes online."
  def set_delete_part_file_down(node, drive), do: set_op_down(:delete_part_file, node, drive)

  defp set_op_down(op, node, drive),
    do: :ets.insert(@table, {{:op, op, node, normalize_path(drive)}, true})

  defp down?(node, path) do
    case :ets.whereis(@table) do
      :undefined ->
        false

      _ ->
        :ets.member(@table, {:node, node}) or drive_down?(node, path)
    end
  end

  defp drive_down?(_node, nil), do: false

  defp drive_down?(node, path) do
    normalized_path = normalize_path(path)

    @table
    |> :ets.tab2list()
    |> Enum.any?(fn
      {{:drive, ^node, drive}, true} -> under_drive?(normalized_path, drive)
      _ -> false
    end)
  end

  defp op_down?(op, node, path) do
    normalized_path = normalize_path(path)

    @table
    |> :ets.tab2list()
    |> Enum.any?(fn
      {{:op, ^op, ^node, drive}, true} -> under_drive?(normalized_path, drive)
      _ -> false
    end)
  end

  defp under_drive?(path, drive) do
    path == drive or String.starts_with?(path, drive <> "/")
  end

  defp normalize_path(path), do: path |> Path.expand() |> Path.split() |> Path.join()

  defp normalize_pressure_snapshot(snapshot) when is_map(snapshot) do
    s3 =
      non_negative_int(Map.get(snapshot, :s3_in_flight) || Map.get(snapshot, "s3_in_flight"), 0)

    storage =
      non_negative_int(Map.get(snapshot, :storage_ops) || Map.get(snapshot, "storage_ops"), 0)

    combined =
      non_negative_int(
        Map.get(snapshot, :combined) || Map.get(snapshot, "combined"),
        s3 + storage
      )

    %{
      s3_in_flight: s3,
      storage_ops: storage,
      combined: combined
    }
  end

  defp normalize_pressure_snapshot(_snapshot), do: %{s3_in_flight: 0, storage_ops: 0, combined: 0}

  defp non_negative_int(n, _default) when is_integer(n) and n >= 0, do: n
  defp non_negative_int(_n, default), do: default

  @impl true
  def put_shard(node, dir, j, shard, shard_len) do
    if down?(node, dir),
      do: {:error, :unavailable},
      else: ShardServer.put_shard(dir, j, shard, shard_len)
  end

  @impl true
  def get_shard(node, dir, j, shard_len) do
    if down?(node, dir), do: nil, else: ShardServer.get_shard(dir, j, shard_len)
  end

  @impl true
  def put_sidecar(node, dir, meta) do
    if down?(node, dir) or op_down?(:put_sidecar, node, dir),
      do: {:error, :unavailable},
      else: ShardServer.put_sidecar(dir, meta)
  end

  @impl true
  def get_sidecar(node, dir) do
    if down?(node, dir), do: {:error, :enoent}, else: ShardServer.get_sidecar(dir)
  end

  @impl true
  def stat_shard(node, dir) do
    if down?(node, dir), do: {:error, :enoent}, else: ShardServer.stat_shard(dir)
  end

  @impl true
  def stat_shard_info(node, dir) do
    if down?(node, dir), do: {:error, :enoent}, else: ShardServer.stat_shard_info(dir)
  end

  @impl true
  def delete_shard(node, dir) do
    if down?(node, dir), do: :ok, else: ShardServer.delete_shard(dir)
  end

  @impl true
  def delete_part_file(node, dir) do
    if down?(node, dir) or op_down?(:delete_part_file, node, dir),
      do: {:error, :unavailable},
      else: ShardServer.delete_part_file(dir)
  end

  @impl true
  def heal_shard(node, dir, block_map, shard_len, meta) do
    if down?(node, dir) or op_down?(:heal_shard, node, dir),
      do: {:ok, 0},
      else: ShardServer.heal_shard(dir, block_map, shard_len, meta)
  end

  @impl true
  def begin_tmp(node, drive_root) do
    if down?(node, drive_root),
      do: {:error, :unavailable},
      else: ShardServer.begin_tmp(drive_root)
  end

  @impl true
  def commit_object(node, tmp_dir, final_obj_dir, opts) do
    if down?(node, final_obj_dir) or down?(node, tmp_dir),
      do: {:error, :unavailable},
      else: ShardServer.commit(tmp_dir, final_obj_dir, opts)
  end

  @impl true
  def list_dir(node, drive_dir, opts) do
    if down?(node, drive_dir),
      do: {:error, :unavailable},
      else: ShardServer.list_dir(drive_dir, opts)
  end

  @impl true
  def probe_drive(node, drive_root) do
    if down?(node, drive_root),
      do: {:error, :unavailable},
      else: ShardServer.probe_drive(drive_root)
  end

  @impl true
  def probe_drive_identity(node, drive_root, opts \\ []) do
    if down?(node, drive_root),
      do: {:error, :unavailable},
      else: ShardServer.probe_drive_identity(drive_root, opts)
  end

  @impl true
  def drive_stats(node, drive_root, opts \\ []) do
    if down?(node, drive_root),
      do: {:error, :unavailable},
      else: ShardServer.drive_stats(drive_root, opts)
  end

  @impl true
  def pressure_snapshot(node, _opts \\ []) do
    cond do
      down?(node, nil) ->
        {:error, :unavailable}

      :ets.whereis(@table) == :undefined ->
        {:ok, Maxio.Cluster.IOPressure.local_snapshot()}

      true ->
        case :ets.lookup(@table, {:pressure, node}) do
          [{{:pressure, ^node}, snapshot}] -> {:ok, snapshot}
          _ -> {:ok, Maxio.Cluster.IOPressure.local_snapshot()}
        end
    end
  end
end
