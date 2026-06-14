defmodule Maxio.Cluster.DriveDeviceIO do
  @moduledoc """
  Fail-open OS/device-level drive IO pressure telemetry.

  `Maxio.Cluster.DriveIO` measures application-level ShardServer operations.
  This module is the separate OS/device lane for queue depth, busy time,
  throughput, and latency observations. It is read-only operational telemetry:
  unsupported platforms, parser errors, provider failures, stale cache, or
  missing topology all collapse to zero pressure and must never affect S3
  request correctness, quorum, or app boot.
  """

  use GenServer

  alias Maxio.Cluster.Topology

  @default_interval_ms 1_000
  @default_cache_max_age_ms 5_000
  @default_latency_unit_us 100_000
  @table :maxio_cluster_drive_device_io
  @summary_key :summary

  @type endpoint :: {node(), String.t()}
  @type sample :: %{
          status: :ok,
          endpoint: endpoint() | nil,
          set_id: term() | nil,
          endpoint_index: non_neg_integer() | nil,
          drive: String.t(),
          mount_root: String.t(),
          device_id: String.t(),
          device_name: String.t() | nil,
          queue_depth: non_neg_integer(),
          busy_percent_x100: non_neg_integer(),
          read_bytes_per_sec: non_neg_integer(),
          write_bytes_per_sec: non_neg_integer(),
          ops_per_sec: non_neg_integer(),
          avg_latency_us: non_neg_integer(),
          pressure: non_neg_integer(),
          source: atom(),
          observed_at_ms: integer()
        }
  @type error_sample :: %{
          status: :error,
          endpoint: endpoint() | nil,
          set_id: term() | nil,
          endpoint_index: non_neg_integer() | nil,
          drive: String.t(),
          node: node() | nil,
          reason: term(),
          observed_at_ms: integer()
        }
  @type summary :: %{
          status: :ok | :partial | :no_topology,
          topology_sets: non_neg_integer(),
          endpoints: non_neg_integer(),
          ok: non_neg_integer(),
          errors: non_neg_integer(),
          pressure: non_neg_integer(),
          max_queue_depth: non_neg_integer(),
          max_busy_percent_x100: non_neg_integer(),
          read_bytes_per_sec: non_neg_integer(),
          write_bytes_per_sec: non_neg_integer(),
          ops_per_sec: non_neg_integer(),
          avg_latency_us: non_neg_integer(),
          observed_at_ms: integer(),
          samples: [sample() | error_sample()]
        }

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    cfg = Application.get_env(:maxio, :drive_device_io, [])

    state = %{
      enabled?: Keyword.get(opts, :enabled, Keyword.get(cfg, :enabled, true)),
      interval_ms:
        positive_int(
          Keyword.get(opts, :interval_ms, Keyword.get(cfg, :interval_ms)),
          @default_interval_ms
        ),
      cache_max_age_ms:
        non_negative_int(
          Keyword.get(opts, :cache_max_age_ms, Keyword.get(cfg, :cache_max_age_ms)),
          @default_cache_max_age_ms
        ),
      provider: Keyword.get(opts, :provider, Keyword.get(cfg, :provider)),
      topology: Keyword.get(opts, :topology)
    }

    create_table()
    {:ok, maybe_schedule(state)}
  end

  @impl true
  def handle_call({:refresh_once, opts}, _from, state) do
    summary =
      opts
      |> merge_state_opts(state)
      |> sample_topology()

    {:reply, {:ok, summary}, state}
  end

  def handle_call(:reset, _from, state) do
    reset_table()
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:refresh, %{enabled?: false} = state), do: {:noreply, state}

  def handle_info(:refresh, state) do
    _ =
      state
      |> merge_state_opts([])
      |> sample_topology()

    {:noreply, maybe_schedule(state)}
  end

  @doc "Refresh local topology device IO telemetry through the registered process."
  @spec refresh_once(keyword()) :: {:ok, summary()}
  def refresh_once(opts \\ []) do
    case call_server({:refresh_once, opts}, :infinity) do
      {:ok, {:ok, summary}} -> {:ok, summary}
      {:error, _reason} -> {:ok, sample_topology(opts)}
    end
  end

  @doc "Return the cached device pressure count, or zero when unavailable/stale."
  @spec pressure_count(keyword()) :: non_neg_integer()
  def pressure_count(opts \\ []) do
    if enabled?(opts) do
      opts
      |> cached_summary()
      |> case do
        %{pressure: pressure} when is_integer(pressure) and pressure > 0 -> pressure
        _summary -> 0
      end
    else
      0
    end
  catch
    _kind, _reason -> 0
  end

  @doc "Return the fresh cached topology summary, or an empty no-topology summary."
  @spec snapshot(keyword()) :: summary()
  def snapshot(opts \\ []) do
    cached_summary(opts) || empty_summary(:no_topology, now_ms(opts))
  end

  @doc "Clear cached summaries and raw diskstat deltas."
  @spec reset() :: :ok
  def reset do
    _ = call_server(:reset)
    reset_table()
    :ok
  end

  @doc "Probe one local drive path and return a one-sample summary."
  @spec sample_local_drive(String.t(), keyword()) :: summary()
  def sample_local_drive(drive_root, opts \\ []) when is_binary(drive_root) do
    sample =
      case local(drive_root, opts) do
        {:ok, sample} -> sample
        {:error, reason} -> error_sample(nil, nil, nil, reason, now_ms(opts), drive_root)
      end

    [sample]
    |> summarize(0, now_ms(opts))
    |> maybe_cache_summary(opts)
  end

  @doc "Probe local endpoints from the configured or injected topology."
  @spec sample_topology(keyword()) :: summary()
  def sample_topology(opts \\ []) do
    observed_at_ms = now_ms(opts)

    case topology_view(opts) do
      :no_topology ->
        empty_summary(:no_topology, observed_at_ms)
        |> maybe_cache_summary(opts)

      view ->
        samples =
          for set_id <- all_set_ids(view),
              {endpoint, endpoint_index} <- endpoints(view, set_id) |> Enum.with_index(),
              local_endpoint?(endpoint) do
            sample_endpoint(endpoint, set_id, endpoint_index, opts)
          end

        samples
        |> summarize(length(all_set_ids(view)), observed_at_ms)
        |> maybe_cache_summary(opts)
    end
  end

  @doc "Return one local drive's device IO telemetry."
  @spec local(String.t(), keyword()) :: {:ok, sample()} | {:error, term()}
  def local(drive_root, opts \\ []) when is_binary(drive_root) do
    observed_at_ms = now_ms(opts)

    try do
      provider = provider(opts)

      drive_root
      |> provider.()
      |> normalize_provider_result(drive_root, observed_at_ms, opts)
    rescue
      e -> {:error, {:exception, Exception.message(e)}}
    catch
      kind, reason -> {:error, {kind, reason}}
    end
  end

  @doc "Best-effort Linux /proc provider. Non-Linux platforms fail open as unsupported."
  @spec default_provider(String.t()) :: {:ok, map()} | {:error, term()}
  def default_provider(drive_root) when is_binary(drive_root) do
    case :os.type() do
      {:unix, :linux} ->
        with {:ok, mountinfo} <- File.read("/proc/self/mountinfo"),
             {:ok, diskstats} <- File.read("/proc/diskstats"),
             {:ok, mount} <- mount_for_path(drive_root, mountinfo),
             {:ok, stats} <- diskstats_for_mount(mount, diskstats) do
          {:ok, Map.merge(stats, %{mount_root: mount.mount_root, source: :proc_diskstats})}
        end

      os_type ->
        {:error, {:unsupported_os, os_type}}
    end
  end

  defp sample_endpoint({_node, drive} = endpoint, set_id, endpoint_index, opts) do
    observed_at_ms = now_ms(opts)

    case local(drive, opts) do
      {:ok, sample} ->
        sample
        |> Map.put(:endpoint, normalize_endpoint(endpoint))
        |> Map.put(:set_id, set_id)
        |> Map.put(:endpoint_index, endpoint_index)

      {:error, reason} ->
        error_sample(endpoint, set_id, endpoint_index, reason, observed_at_ms)
    end
  end

  defp normalize_provider_result({:ok, %{} = stats}, drive_root, observed_at_ms, opts) do
    device_id = stats |> Map.get(:device_id, Path.expand(drive_root)) |> to_string()

    computed =
      if raw_counter_sample?(stats) do
        compute_raw_delta(device_id, stats, observed_at_ms)
      else
        %{}
      end

    stats = Map.merge(stats, computed)
    queue_depth = non_negative_int(Map.get(stats, :queue_depth), 0)
    busy_percent_x100 = clamp(non_negative_int(Map.get(stats, :busy_percent_x100), 0), 0, 10_000)
    avg_latency_us = non_negative_int(Map.get(stats, :avg_latency_us), 0)

    pressure =
      case Map.get(stats, :pressure) || Map.get(stats, :pressure_units) do
        n when is_integer(n) and n >= 0 ->
          n

        _other ->
          pressure_units(queue_depth, busy_percent_x100, avg_latency_us, opts)
      end

    {:ok,
     %{
       status: :ok,
       endpoint: nil,
       set_id: nil,
       endpoint_index: nil,
       drive: Path.expand(drive_root),
       mount_root: to_string(Map.get(stats, :mount_root, Path.expand(drive_root))),
       device_id: device_id,
       device_name: maybe_to_string(Map.get(stats, :device_name)),
       queue_depth: queue_depth,
       busy_percent_x100: busy_percent_x100,
       read_bytes_per_sec: non_negative_int(Map.get(stats, :read_bytes_per_sec), 0),
       write_bytes_per_sec: non_negative_int(Map.get(stats, :write_bytes_per_sec), 0),
       ops_per_sec: non_negative_int(Map.get(stats, :ops_per_sec), 0),
       avg_latency_us: avg_latency_us,
       pressure: pressure,
       source: Map.get(stats, :source, :unknown),
       observed_at_ms: observed_at_ms
     }}
  end

  defp normalize_provider_result({:error, reason}, _drive_root, _observed_at_ms, _opts),
    do: {:error, reason}

  defp normalize_provider_result(other, _drive_root, _observed_at_ms, _opts),
    do: {:error, {:invalid_provider_result, other}}

  defp raw_counter_sample?(stats) do
    Enum.any?([:sectors_read, :sectors_written, :reads_completed, :writes_completed], fn key ->
      is_integer(Map.get(stats, key))
    end)
  end

  defp compute_raw_delta(device_id, stats, observed_at_ms) do
    previous = previous_raw_sample(device_id)
    store_raw_sample(device_id, stats, observed_at_ms)

    case previous do
      nil ->
        %{}

      %{stats: previous_stats, observed_at_ms: previous_at_ms} ->
        elapsed_ms = max(observed_at_ms - previous_at_ms, 0)

        if elapsed_ms > 0 do
          sector_size = positive_int(Map.get(stats, :sector_size), 512)
          read_sectors = counter_delta(stats, previous_stats, :sectors_read)
          written_sectors = counter_delta(stats, previous_stats, :sectors_written)
          reads = counter_delta(stats, previous_stats, :reads_completed)
          writes = counter_delta(stats, previous_stats, :writes_completed)
          ops = reads + writes
          read_ms = counter_delta(stats, previous_stats, :read_time_ms)
          write_ms = counter_delta(stats, previous_stats, :write_time_ms)
          io_ms = counter_delta(stats, previous_stats, :io_time_ms)

          %{
            read_bytes_per_sec: div(read_sectors * sector_size * 1_000, elapsed_ms),
            write_bytes_per_sec: div(written_sectors * sector_size * 1_000, elapsed_ms),
            ops_per_sec: div(ops * 1_000, elapsed_ms),
            avg_latency_us: if(ops > 0, do: div((read_ms + write_ms) * 1_000, ops), else: 0),
            busy_percent_x100: min(div(io_ms * 10_000, elapsed_ms), 10_000)
          }
        else
          %{}
        end
    end
  end

  defp previous_raw_sample(device_id) do
    create_table()

    case :ets.lookup(@table, {:raw, device_id}) do
      [{{:raw, ^device_id}, stats, observed_at_ms}] ->
        %{stats: stats, observed_at_ms: observed_at_ms}

      _entry ->
        nil
    end
  end

  defp store_raw_sample(device_id, stats, observed_at_ms) do
    create_table()
    :ets.insert(@table, {{:raw, device_id}, Map.take(stats, raw_counter_keys()), observed_at_ms})
    :ok
  end

  defp raw_counter_keys do
    [
      :sectors_read,
      :sectors_written,
      :reads_completed,
      :writes_completed,
      :read_time_ms,
      :write_time_ms,
      :io_time_ms
    ]
  end

  defp counter_delta(current, previous, key) do
    current_value = non_negative_int(Map.get(current, key), 0)
    previous_value = non_negative_int(Map.get(previous, key), 0)
    max(current_value - previous_value, 0)
  end

  defp pressure_units(queue_depth, busy_percent_x100, avg_latency_us, opts) do
    latency_unit_us =
      opts
      |> Keyword.get(
        :latency_unit_us,
        Application.get_env(:maxio, :drive_device_io, [])[:latency_unit_us]
      )
      |> positive_int(@default_latency_unit_us)

    Enum.max([
      queue_depth,
      ceil_div(busy_percent_x100, 1_000),
      div(avg_latency_us, latency_unit_us)
    ])
  end

  defp summarize(samples, set_count, observed_at_ms) do
    ok_samples = Enum.filter(samples, &sample_ok?/1)
    errors = length(samples) - length(ok_samples)

    status =
      cond do
        samples == [] and set_count == 0 -> :no_topology
        errors == 0 -> :ok
        true -> :partial
      end

    %{
      status: status,
      topology_sets: set_count,
      endpoints: length(samples),
      ok: length(ok_samples),
      errors: errors,
      pressure: max_field(ok_samples, :pressure),
      max_queue_depth: max_field(ok_samples, :queue_depth),
      max_busy_percent_x100: max_field(ok_samples, :busy_percent_x100),
      read_bytes_per_sec: sum(ok_samples, :read_bytes_per_sec),
      write_bytes_per_sec: sum(ok_samples, :write_bytes_per_sec),
      ops_per_sec: sum(ok_samples, :ops_per_sec),
      avg_latency_us: avg_latency(ok_samples),
      observed_at_ms: observed_at_ms,
      samples: samples
    }
  end

  defp empty_summary(status, observed_at_ms) do
    %{
      status: status,
      topology_sets: 0,
      endpoints: 0,
      ok: 0,
      errors: 0,
      pressure: 0,
      max_queue_depth: 0,
      max_busy_percent_x100: 0,
      read_bytes_per_sec: 0,
      write_bytes_per_sec: 0,
      ops_per_sec: 0,
      avg_latency_us: 0,
      observed_at_ms: observed_at_ms,
      samples: []
    }
  end

  defp maybe_cache_summary(summary, opts) do
    if Keyword.get(opts, :cache, true) do
      create_table()
      :ets.insert(@table, {@summary_key, summary, summary.observed_at_ms})
    end

    summary
  end

  defp cached_summary(opts) do
    create_table()
    now_ms = now_ms(opts)

    cache_max_age_ms =
      non_negative_int(Keyword.get(opts, :cache_max_age_ms), configured_cache_max_age())

    case :ets.lookup(@table, @summary_key) do
      [{@summary_key, summary, observed_at_ms}]
      when is_integer(observed_at_ms) and max(now_ms - observed_at_ms, 0) <= cache_max_age_ms ->
        summary

      _entry ->
        nil
    end
  end

  defp reset_table do
    create_table()
    :ets.delete_all_objects(@table)
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

  defp provider(opts) do
    configured =
      opts
      |> Keyword.get(:provider)
      |> case do
        nil -> Application.get_env(:maxio, :drive_device_io, [])[:provider]
        provider -> provider
      end

    case configured do
      fun when is_function(fun, 1) ->
        fun

      {module, function} when is_atom(module) and is_atom(function) ->
        &apply(module, function, [&1])

      nil ->
        &default_provider/1

      other ->
        fn _drive_root -> {:error, {:invalid_provider, other}} end
    end
  end

  defp mount_for_path(drive_root, mountinfo) do
    normalized_drive = normalize_path(Path.expand(drive_root))

    mountinfo
    |> String.split("\n", trim: true)
    |> Enum.filter(&String.contains?(&1, " - "))
    |> Enum.flat_map(&parse_mountinfo_line/1)
    |> Enum.filter(fn mount ->
      mount_matches?(normalized_drive, normalize_path(mount.mount_root))
    end)
    |> Enum.max_by(fn mount -> String.length(normalize_path(mount.mount_root)) end, fn -> nil end)
    |> case do
      nil -> {:error, :mount_not_found}
      mount -> {:ok, mount}
    end
  end

  defp parse_mountinfo_line(line) do
    [left | _right] = String.split(line, " - ", parts: 2)
    fields = String.split(left)

    with major_minor when is_binary(major_minor) <- Enum.at(fields, 2),
         mount_root when is_binary(mount_root) <- Enum.at(fields, 4),
         [major, minor] <- String.split(major_minor, ":", parts: 2),
         {major, ""} <- Integer.parse(major),
         {minor, ""} <- Integer.parse(minor) do
      [%{major: major, minor: minor, mount_root: unescape_mount_path(mount_root)}]
    else
      _other -> []
    end
  end

  defp diskstats_for_mount(%{major: major, minor: minor}, diskstats) do
    diskstats
    |> String.split("\n", trim: true)
    |> Enum.find_value(fn line ->
      fields = String.split(line)

      with true <- length(fields) >= 14,
           {^major, ""} <- Integer.parse(Enum.at(fields, 0)),
           {^minor, ""} <- Integer.parse(Enum.at(fields, 1)) do
        {:ok,
         %{
           device_id: "#{major}:#{minor}",
           device_name: Enum.at(fields, 2),
           reads_completed: parse_int(Enum.at(fields, 3)),
           sectors_read: parse_int(Enum.at(fields, 5)),
           read_time_ms: parse_int(Enum.at(fields, 6)),
           writes_completed: parse_int(Enum.at(fields, 7)),
           sectors_written: parse_int(Enum.at(fields, 9)),
           write_time_ms: parse_int(Enum.at(fields, 10)),
           queue_depth: parse_int(Enum.at(fields, 11)),
           io_time_ms: parse_int(Enum.at(fields, 12)),
           weighted_io_time_ms: parse_int(Enum.at(fields, 13)),
           sector_size: 512
         }}
      else
        _other -> nil
      end
    end)
    |> case do
      nil -> {:error, :diskstats_not_found}
      result -> result
    end
  end

  defp topology_view(opts) do
    case Keyword.fetch(opts, :topology) do
      {:ok, nil} -> :no_topology
      {:ok, topology} -> {:injected, topology}
      :error -> if Topology.configured?(), do: {:configured, nil}, else: :no_topology
    end
  end

  defp all_set_ids({:configured, nil}), do: Topology.all_set_ids()
  defp all_set_ids({:injected, topology}), do: Topology.all_set_ids_from(topology)

  defp endpoints({:configured, nil}, set_id), do: Topology.endpoints(set_id)
  defp endpoints({:injected, topology}, set_id), do: Topology.endpoints_from(topology, set_id)

  defp local_endpoint?({node, _drive}), do: node == Node.self()

  defp merge_state_opts(opts, state) when is_map(state) do
    opts
    |> maybe_put(:topology, state.topology)
    |> maybe_put(:provider, state.provider)
  end

  defp merge_state_opts(state, opts) when is_map(state), do: merge_state_opts(opts, state)

  defp maybe_schedule(%{enabled?: false} = state), do: state

  defp maybe_schedule(%{interval_ms: interval_ms} = state) do
    _ = Process.send_after(self(), :refresh, interval_ms)
    state
  end

  defp enabled?(opts) do
    Keyword.get(
      opts,
      :enabled,
      Application.get_env(:maxio, :drive_device_io, [])[:enabled] != false
    )
  end

  defp configured_cache_max_age do
    @default_cache_max_age_ms
    |> then(
      &non_negative_int(Application.get_env(:maxio, :drive_device_io, [])[:cache_max_age_ms], &1)
    )
  end

  defp error_sample(endpoint, set_id, endpoint_index, reason, observed_at_ms, drive \\ nil) do
    {node, drive} =
      case endpoint do
        {node, endpoint_drive} -> {node, endpoint_drive}
        nil -> {nil, drive}
      end

    %{
      status: :error,
      endpoint: if(endpoint, do: normalize_endpoint(endpoint), else: nil),
      set_id: set_id,
      endpoint_index: endpoint_index,
      drive: if(drive, do: Path.expand(drive), else: "nil"),
      node: node,
      reason: reason,
      observed_at_ms: observed_at_ms
    }
  end

  defp sample_ok?(%{status: :ok}), do: true
  defp sample_ok?(_sample), do: false

  defp avg_latency([]), do: 0

  defp avg_latency(samples) do
    ops = sum(samples, :ops_per_sec)

    if ops > 0 do
      div(
        Enum.reduce(samples, 0, fn sample, acc ->
          acc + sample.avg_latency_us * sample.ops_per_sec
        end),
        ops
      )
    else
      max_field(samples, :avg_latency_us)
    end
  end

  defp sum(samples, key),
    do: Enum.reduce(samples, 0, fn sample, acc -> acc + Map.fetch!(sample, key) end)

  defp max_field([], _key), do: 0
  defp max_field(samples, key), do: samples |> Enum.map(&Map.fetch!(&1, key)) |> Enum.max()

  defp normalize_endpoint({node, drive}), do: {node, Path.expand(drive)}

  defp mount_matches?(normalized_drive, "/"), do: String.starts_with?(normalized_drive, "/")

  defp mount_matches?(normalized_drive, mount),
    do: normalized_drive == mount or String.starts_with?(normalized_drive, mount <> "/")

  defp normalize_path(path) do
    path
    |> String.replace("\\", "/")
    |> String.trim_trailing("/")
    |> String.downcase()
    |> case do
      "" -> "/"
      mount -> mount
    end
  end

  defp unescape_mount_path(path) do
    Regex.replace(~r/\\([0-7]{3})/, path, fn _, octal ->
      octal |> String.to_integer(8) |> List.wrap() |> to_string()
    end)
  end

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n >= 0 -> n
      _other -> 0
    end
  end

  defp parse_int(_value), do: 0

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put_new(opts, key, value)

  defp maybe_to_string(nil), do: nil
  defp maybe_to_string(value), do: to_string(value)

  defp ceil_div(0, _d), do: 0
  defp ceil_div(n, d), do: div(n + d - 1, d)

  defp positive_int(n, _default) when is_integer(n) and n > 0, do: n
  defp positive_int(_n, default), do: default

  defp non_negative_int(n, _default) when is_integer(n) and n >= 0, do: n
  defp non_negative_int(_n, default), do: default

  defp clamp(n, min, _max) when n < min, do: min
  defp clamp(n, _min, max) when n > max, do: max
  defp clamp(n, _min, _max), do: n

  defp now_ms(opts) do
    cond do
      is_integer(Keyword.get(opts, :now_ms)) -> Keyword.fetch!(opts, :now_ms)
      is_function(Keyword.get(opts, :now_fun), 0) -> opts |> Keyword.fetch!(:now_fun) |> apply([])
      true -> System.monotonic_time(:millisecond)
    end
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
end
