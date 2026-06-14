defmodule Maxio.Cluster.PressureAggregator do
  @moduledoc """
  Fail-open cached cluster pressure aggregation.

  Scrubber and fresh-drive pacing call `count/2` frequently, so that path only
  reads node-local counters plus this process' cached peer snapshots. Remote
  polling happens in the background or through explicit `refresh_once/1` calls.
  """

  use GenServer

  alias Maxio.Cluster.{IOPressure, Topology, Transport}

  @default_interval_ms 1_000
  @default_peer_timeout_ms 50
  @default_cache_max_age_ms 5_000
  @table :maxio_cluster_pressure_snapshots
  @cache_max_age_key {:config, :cache_max_age_ms}

  @type snapshot :: %{
          s3_in_flight: non_neg_integer(),
          storage_ops: non_neg_integer(),
          combined: non_neg_integer(),
          drive_device_io: non_neg_integer()
        }

  @doc false
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    if name do
      GenServer.start_link(__MODULE__, opts, name: name)
    else
      GenServer.start_link(__MODULE__, opts)
    end
  end

  @doc "Return local pressure plus fresh cached peer pressure for `source`."
  @spec count(IOPressure.local_source(), keyword()) :: non_neg_integer()
  def count(source, opts \\ []) do
    source = IOPressure.normalize_local_source(source)
    local = IOPressure.local_count(source)
    local + peer_count(source, opts)
  end

  @doc "Refresh peer snapshots synchronously. Intended for tests and operator probes."
  @spec refresh_once(keyword()) :: {:ok, %{node() => snapshot()}}
  def refresh_once(opts \\ []) do
    case call_server({:refresh_once, opts}, :infinity) do
      {:ok, snapshots} -> {:ok, snapshots}
      {:error, _reason} -> {:ok, %{}}
    end
  end

  @doc "Return cached peer snapshots."
  @spec snapshot(keyword()) :: %{node() => snapshot()}
  def snapshot(opts \\ []) do
    case call_server({:snapshot, opts}) do
      {:ok, snapshots} -> snapshots
      {:error, _reason} -> %{}
    end
  end

  @doc false
  @spec reset() :: :ok
  def reset do
    _ = call_server(:reset)
    :ok
  end

  @impl true
  def init(opts) do
    cfg = Application.get_env(:maxio, :io_pressure, [])

    state = %{
      enabled?: Keyword.get(opts, :enabled, Keyword.get(cfg, :enabled, true)),
      interval_ms:
        positive_int(
          Keyword.get(opts, :interval_ms, Keyword.get(cfg, :interval_ms)),
          @default_interval_ms
        ),
      peer_timeout_ms:
        positive_int(
          Keyword.get(opts, :peer_timeout_ms, Keyword.get(cfg, :peer_timeout_ms)),
          @default_peer_timeout_ms
        ),
      cache_max_age_ms:
        non_negative_int(
          Keyword.get(opts, :cache_max_age_ms, Keyword.get(cfg, :cache_max_age_ms)),
          @default_cache_max_age_ms
        ),
      transport: Keyword.get(opts, :transport) || Transport.impl(opts),
      topology: Keyword.get(opts, :topology),
      snapshots: %{},
      timer_ref: nil
    }

    create_table()
    store_cache_max_age(state.cache_max_age_ms)

    {:ok, maybe_schedule(state)}
  end

  @impl true
  def handle_call({:count, source, opts}, _from, state) do
    now_ms = now_ms(opts)

    cache_max_age_ms =
      non_negative_int(Keyword.get(opts, :cache_max_age_ms), state.cache_max_age_ms)

    {:reply, cached_count(state.snapshots, source, now_ms, cache_max_age_ms), state}
  end

  def handle_call({:refresh_once, opts}, _from, state) do
    {snapshots, state} = refresh_peer_snapshots(state, opts)
    {:reply, snapshots, state}
  end

  def handle_call({:snapshot, opts}, _from, state) do
    now_ms = now_ms(opts)

    cache_max_age_ms =
      non_negative_int(Keyword.get(opts, :cache_max_age_ms), state.cache_max_age_ms)

    {:reply, fresh_snapshots(state.snapshots, now_ms, cache_max_age_ms), state}
  end

  def handle_call(:reset, _from, state) do
    reset_table(state.cache_max_age_ms)
    {:reply, :ok, %{state | snapshots: %{}}}
  end

  @impl true
  def handle_info(:refresh, state) do
    {_snapshots, state} = refresh_peer_snapshots(state, [])
    {:noreply, maybe_schedule(%{state | timer_ref: nil})}
  end

  defp refresh_peer_snapshots(state, opts) do
    now_ms = now_ms(opts)
    transport = Keyword.get(opts, :transport) || state.transport
    timeout_ms = positive_int(Keyword.get(opts, :peer_timeout_ms), state.peer_timeout_ms)

    snapshots =
      opts
      |> peer_nodes(state)
      |> Enum.reduce(state.snapshots, fn node, acc ->
        case pressure_snapshot(transport, node, timeout_ms) do
          {:ok, snapshot} ->
            snapshot = normalize_snapshot(snapshot)
            put_snapshot(node, snapshot, now_ms)
            Map.put(acc, node, %{snapshot: snapshot, observed_at_ms: now_ms})

          {:error, _reason} ->
            delete_snapshot(node)
            Map.delete(acc, node)
        end
      end)

    fresh = fresh_snapshots(snapshots, now_ms, state.cache_max_age_ms)
    {fresh, %{state | snapshots: snapshots}}
  end

  defp pressure_snapshot(transport, node, timeout_ms) do
    try do
      transport.pressure_snapshot(node, timeout_ms: timeout_ms)
    rescue
      e -> {:error, {:exception, Exception.message(e)}}
    catch
      kind, reason -> {:error, {kind, reason}}
    end
  end

  defp cached_count(snapshots, source, now_ms, cache_max_age_ms) do
    snapshots
    |> fresh_snapshots(now_ms, cache_max_age_ms)
    |> Map.values()
    |> Enum.reduce(0, fn snapshot, acc -> acc + Map.get(snapshot, source, 0) end)
  end

  defp peer_count(source, opts) do
    now_ms = now_ms(opts)

    cache_max_age_ms =
      non_negative_int(Keyword.get(opts, :cache_max_age_ms), table_cache_max_age())

    cached_count(table_snapshots(), source, now_ms, cache_max_age_ms)
  catch
    _kind, _reason -> 0
  end

  defp fresh_snapshots(snapshots, now_ms, cache_max_age_ms) do
    snapshots
    |> Enum.filter(fn {_node, %{observed_at_ms: observed_at_ms}} ->
      max(now_ms - observed_at_ms, 0) <= cache_max_age_ms
    end)
    |> Map.new(fn {node, %{snapshot: snapshot}} -> {node, snapshot} end)
  end

  defp normalize_snapshot(snapshot) when is_map(snapshot) do
    s3 =
      non_negative_int(Map.get(snapshot, :s3_in_flight) || Map.get(snapshot, "s3_in_flight"), 0)

    storage =
      non_negative_int(Map.get(snapshot, :storage_ops) || Map.get(snapshot, "storage_ops"), 0)

    combined =
      non_negative_int(
        Map.get(snapshot, :combined) || Map.get(snapshot, "combined"),
        s3 + storage
      )

    drive_device_io =
      non_negative_int(
        Map.get(snapshot, :drive_device_io) || Map.get(snapshot, "drive_device_io"),
        0
      )

    %{
      s3_in_flight: s3,
      storage_ops: storage,
      combined: combined,
      drive_device_io: drive_device_io
    }
  end

  defp normalize_snapshot(_snapshot),
    do: %{s3_in_flight: 0, storage_ops: 0, combined: 0, drive_device_io: 0}

  defp peer_nodes(opts, state) do
    opts
    |> Keyword.get(:nodes, nodes_from_topology(Keyword.get(opts, :topology, state.topology)))
    |> Enum.uniq()
    |> Enum.reject(&(&1 == Node.self()))
  end

  defp nodes_from_topology(nil) do
    if Topology.configured?() do
      Topology.all_set_ids()
      |> Enum.flat_map(&Topology.endpoints/1)
      |> Enum.map(fn {node, _drive} -> node end)
    else
      Maxio.Cluster.nodes()
    end
  end

  defp nodes_from_topology(topology) do
    topology
    |> Topology.all_set_ids_from()
    |> Enum.flat_map(&Topology.endpoints_from(topology, &1))
    |> Enum.map(fn {node, _drive} -> node end)
  end

  defp maybe_schedule(%{enabled?: false} = state), do: state

  defp maybe_schedule(%{interval_ms: interval_ms} = state) do
    %{state | timer_ref: Process.send_after(self(), :refresh, interval_ms)}
  end

  defp create_table do
    try do
      :ets.new(@table, [
        :named_table,
        :public,
        :set,
        read_concurrency: true,
        write_concurrency: true
      ])
    rescue
      ArgumentError -> :ets.whereis(@table)
    end
  end

  defp reset_table(cache_max_age_ms) do
    create_table()
    :ets.delete_all_objects(@table)
    store_cache_max_age(cache_max_age_ms)
  end

  defp store_cache_max_age(cache_max_age_ms) do
    :ets.insert(@table, {@cache_max_age_key, cache_max_age_ms})
  end

  defp put_snapshot(node, snapshot, observed_at_ms) do
    create_table()
    :ets.insert(@table, {{:node, node}, snapshot, observed_at_ms})
  end

  defp delete_snapshot(node) do
    if :ets.whereis(@table) != :undefined do
      :ets.delete(@table, {:node, node})
    end
  end

  defp table_snapshots do
    case :ets.whereis(@table) do
      :undefined ->
        %{}

      _tid ->
        @table
        |> :ets.tab2list()
        |> Enum.reduce(%{}, fn
          {{:node, node}, snapshot, observed_at_ms}, acc ->
            Map.put(acc, node, %{snapshot: snapshot, observed_at_ms: observed_at_ms})

          _entry, acc ->
            acc
        end)
    end
  end

  defp table_cache_max_age do
    case :ets.whereis(@table) do
      :undefined ->
        configured_cache_max_age()

      _tid ->
        case :ets.lookup(@table, @cache_max_age_key) do
          [{@cache_max_age_key, cache_max_age_ms}] -> cache_max_age_ms
          _ -> configured_cache_max_age()
        end
    end
  end

  defp configured_cache_max_age do
    cfg = Application.get_env(:maxio, :io_pressure, [])
    non_negative_int(Keyword.get(cfg, :cache_max_age_ms), @default_cache_max_age_ms)
  end

  defp call_server(message, timeout \\ 5_000) do
    case Process.whereis(__MODULE__) do
      nil ->
        {:error, :unavailable}

      pid ->
        try do
          {:ok, GenServer.call(pid, message, timeout)}
        catch
          :exit, reason -> {:error, reason}
        end
    end
  end

  defp now_ms(opts), do: Keyword.get(opts, :now_ms, System.monotonic_time(:millisecond))

  defp positive_int(n, _default) when is_integer(n) and n > 0, do: n
  defp positive_int(_n, default), do: default

  defp non_negative_int(n, _default) when is_integer(n) and n >= 0, do: n
  defp non_negative_int(_n, default), do: default
end
