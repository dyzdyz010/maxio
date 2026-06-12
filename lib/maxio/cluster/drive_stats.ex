defmodule Maxio.Cluster.DriveStats do
  @moduledoc """
  OS-backed filesystem capacity telemetry for configured drive roots.

  This module reports per configured endpoint filesystem capacity/free-space
  observations. It is read-only operator telemetry for future placement and
  rebalance work; it does not affect object routing, quorum, or write admission.
  It does not report device queue depth, SMART data, hardware identity, or
  physical throughput.
  """

  alias Maxio.Cluster.{Topology, Transport}

  @type endpoint :: {node(), String.t()}
  @type precision :: :exact | :estimated
  @type source :: atom()
  @type drive_stat :: %{
          status: :ok,
          endpoint: endpoint() | nil,
          set_id: term() | nil,
          endpoint_index: non_neg_integer() | nil,
          drive: String.t(),
          mount_root: String.t(),
          capacity_bytes: non_neg_integer(),
          free_bytes: non_neg_integer(),
          used_bytes: non_neg_integer(),
          used_percent_x100: non_neg_integer(),
          source: source(),
          precision: precision(),
          observed_at_ms: integer()
        }
  @type error_stat :: %{
          status: :error,
          endpoint: endpoint() | nil,
          set_id: term() | nil,
          endpoint_index: non_neg_integer() | nil,
          drive: String.t(),
          reason: term(),
          observed_at_ms: integer()
        }
  @type topology_summary :: %{
          status: :ok | :partial | :no_topology,
          topology_sets: non_neg_integer(),
          endpoints: non_neg_integer(),
          ok: non_neg_integer(),
          errors: non_neg_integer(),
          capacity_bytes: non_neg_integer(),
          free_bytes: non_neg_integer(),
          used_bytes: non_neg_integer(),
          min_free_bytes: non_neg_integer(),
          min_free_percent_x100: non_neg_integer(),
          samples: [drive_stat() | error_stat()]
        }

  @doc "Return filesystem capacity stats for one local drive root."
  @spec local(String.t(), keyword()) :: {:ok, drive_stat()} | {:error, term()}
  def local(drive_root, opts \\ []) when is_binary(drive_root) do
    observed_at_ms = now_ms(opts)

    try do
      provider = provider(opts)

      drive_root
      |> provider.()
      |> normalize_provider_result(drive_root, observed_at_ms)
    rescue
      e -> {:error, {:exception, Exception.message(e)}}
    catch
      kind, reason -> {:error, {kind, reason}}
    end
  end

  @doc "Return stats for one endpoint through the configured transport."
  @spec sample_endpoint(endpoint(), keyword()) :: drive_stat() | error_stat()
  def sample_endpoint({node, drive} = endpoint, opts \\ []) when is_binary(drive) do
    observed_at_ms = now_ms(opts)
    transport = Keyword.get(opts, :transport) || Transport.impl(opts)
    set_id = Keyword.get(opts, :set_id)
    endpoint_index = Keyword.get(opts, :endpoint_index)

    result =
      try do
        transport.drive_stats(node, drive, drive_stats_opts(opts))
      rescue
        e -> {:error, {:exception, Exception.message(e)}}
      catch
        kind, reason -> {:error, {kind, reason}}
      end

    case result do
      {:ok, sample} ->
        sample
        |> Map.put(:endpoint, normalize_endpoint(endpoint))
        |> Map.put(:set_id, set_id)
        |> Map.put(:endpoint_index, endpoint_index)

      {:error, reason} ->
        error_sample(endpoint, set_id, endpoint_index, reason, observed_at_ms)
    end
  end

  @doc "Probe every endpoint in a topology and summarize per-endpoint capacity stats."
  @spec sample_topology(keyword()) :: topology_summary()
  def sample_topology(opts \\ []) do
    case topology_view(opts) do
      :no_topology ->
        empty_summary(:no_topology)

      view ->
        samples =
          for set_id <- all_set_ids(view),
              {endpoint, endpoint_index} <- endpoints(view, set_id) |> Enum.with_index() do
            sample_endpoint(
              endpoint,
              opts
              |> Keyword.put(:set_id, set_id)
              |> Keyword.put(:endpoint_index, endpoint_index)
            )
          end

        summarize(samples, length(all_set_ids(view)))
    end
  end

  @doc "Probe one local drive path and wrap it in the same summary shape as topology probes."
  @spec sample_local_drive(String.t(), keyword()) :: topology_summary()
  def sample_local_drive(drive_root, opts \\ []) do
    sample =
      case local(drive_root, opts) do
        {:ok, sample} -> sample
        {:error, reason} -> error_sample(nil, nil, nil, reason, now_ms(opts), drive_root)
      end

    summarize([sample], 0)
  end

  @doc "Default OS-backed provider. Prefer exact path/mount stats, fall back to cached disksup data."
  @spec default_provider(String.t()) :: {:ok, map()} | {:error, term()}
  def default_provider(drive_root) when is_binary(drive_root) do
    with {:ok, _apps} <- Application.ensure_all_started(:os_mon) do
      drive_root
      |> exact_disksup_stats()
      |> case do
        {:ok, _stats} = ok -> ok
        {:error, _reason} -> cached_disksup_stats(drive_root)
      end
    else
      {:error, reason} -> {:error, {:os_mon_unavailable, reason}}
    end
  end

  defp provider(opts) do
    configured =
      opts
      |> Keyword.get(:provider)
      |> case do
        nil -> Application.get_env(:maxio, :drive_stats, [])[:provider]
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

  defp normalize_provider_result({:ok, %{} = stats}, drive_root, observed_at_ms) do
    capacity_bytes = stat_int(stats, [:capacity_bytes, :total_bytes], 0)
    free_bytes = stat_int(stats, [:free_bytes, :available_bytes], 0)

    if capacity_bytes > 0 and free_bytes >= 0 do
      free_bytes = min(free_bytes, capacity_bytes)
      used_bytes = capacity_bytes - free_bytes

      {:ok,
       %{
         status: :ok,
         endpoint: nil,
         set_id: nil,
         endpoint_index: nil,
         drive: Path.expand(drive_root),
         mount_root: to_string(Map.get(stats, :mount_root, Path.expand(drive_root))),
         capacity_bytes: capacity_bytes,
         free_bytes: free_bytes,
         used_bytes: used_bytes,
         used_percent_x100:
           stat_int(stats, [:used_percent_x100], used_percent_x100(used_bytes, capacity_bytes)),
         source: Map.get(stats, :source, :unknown),
         precision: Map.get(stats, :precision, :estimated),
         observed_at_ms: observed_at_ms
       }}
    else
      {:error, :unavailable}
    end
  end

  defp normalize_provider_result({:error, reason}, _drive_root, _observed_at_ms),
    do: {:error, reason}

  defp normalize_provider_result(other, _drive_root, _observed_at_ms),
    do: {:error, {:invalid_provider_result, other}}

  defp exact_disksup_stats(drive_root) do
    if Code.ensure_loaded?(:disksup) and function_exported?(:disksup, :get_disk_info, 1) do
      drive_root
      |> path_candidates()
      |> Enum.find_value(fn path ->
        path
        |> String.to_charlist()
        |> then(&apply(:disksup, :get_disk_info, [&1]))
        |> normalize_exact_disk_info()
      end)
      |> case do
        nil -> {:error, :unavailable}
        stats -> {:ok, stats}
      end
    else
      {:error, :unavailable}
    end
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp normalize_exact_disk_info([{id, total_kib, free_kib, _capacity} | _rest])
       when is_integer(total_kib) and total_kib > 0 and is_integer(free_kib) and free_kib >= 0 do
    %{
      mount_root: to_string(id),
      capacity_bytes: total_kib * 1_024,
      free_bytes: free_kib * 1_024,
      source: :disksup_path,
      precision: :exact
    }
  end

  defp normalize_exact_disk_info([_invalid | rest]), do: normalize_exact_disk_info(rest)
  defp normalize_exact_disk_info([]), do: nil

  defp cached_disksup_stats(drive_root) do
    if Code.ensure_loaded?(:disksup) and function_exported?(:disksup, :get_disk_data, 0) do
      drive_root
      |> matching_cached_disk(apply(:disksup, :get_disk_data, []))
      |> case do
        nil ->
          {:error, :unavailable}

        {id, total_kib, used_percent}
        when is_integer(total_kib) and total_kib > 0 and is_integer(used_percent) ->
          used_percent = clamp(used_percent, 0, 100)
          capacity_bytes = total_kib * 1_024
          free_bytes = div(capacity_bytes * (100 - used_percent), 100)

          {:ok,
           %{
             mount_root: to_string(id),
             capacity_bytes: capacity_bytes,
             free_bytes: free_bytes,
             used_percent_x100: used_percent * 100,
             source: :disksup_cached,
             precision: :estimated
           }}
      end
    else
      {:error, :unavailable}
    end
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp matching_cached_disk(drive_root, disk_data) do
    normalized_drive = normalize_mount_path(Path.expand(drive_root))

    disk_data
    |> Enum.filter(fn
      {id, total_kib, used_percent}
      when is_integer(total_kib) and total_kib > 0 and is_integer(used_percent) ->
        mount = normalize_mount_path(to_string(id))

        mount != "" and mount_matches?(normalized_drive, mount)

      _other ->
        false
    end)
    |> Enum.max_by(
      fn {id, _total_kib, _used_percent} ->
        String.length(normalize_mount_path(to_string(id)))
      end,
      fn ->
        nil
      end
    )
  end

  defp path_candidates(drive_root) do
    expanded = Path.expand(drive_root)
    root = filesystem_root(expanded)

    [expanded, root]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp filesystem_root(path) do
    normalized = String.replace(path, "\\", "/")

    case Regex.run(~r/\A([A-Za-z]):/, normalized) do
      [_, drive] -> String.upcase(drive) <> ":\\"
      _ -> nil
    end
  end

  defp normalize_mount_path(path) do
    path
    |> String.replace("\\", "/")
    |> String.trim_trailing("/")
    |> String.downcase()
    |> case do
      "" -> "/"
      mount -> mount
    end
  end

  defp mount_matches?(normalized_drive, "/"), do: String.starts_with?(normalized_drive, "/")

  defp mount_matches?(normalized_drive, mount),
    do: normalized_drive == mount or String.starts_with?(normalized_drive, mount <> "/")

  defp sample_ok?(%{status: :ok}), do: true
  defp sample_ok?(_sample), do: false

  defp summarize(samples, set_count) do
    ok_samples = Enum.filter(samples, &sample_ok?/1)
    errors = length(samples) - length(ok_samples)

    status =
      cond do
        samples == [] -> :no_topology
        errors == 0 -> :ok
        true -> :partial
      end

    %{
      status: status,
      topology_sets: set_count,
      endpoints: length(samples),
      ok: length(ok_samples),
      errors: errors,
      capacity_bytes: sum(ok_samples, :capacity_bytes),
      free_bytes: sum(ok_samples, :free_bytes),
      used_bytes: sum(ok_samples, :used_bytes),
      min_free_bytes: min_field(ok_samples, :free_bytes),
      min_free_percent_x100: min_free_percent(ok_samples),
      samples: samples
    }
  end

  defp empty_summary(status) do
    %{
      status: status,
      topology_sets: 0,
      endpoints: 0,
      ok: 0,
      errors: 0,
      capacity_bytes: 0,
      free_bytes: 0,
      used_bytes: 0,
      min_free_bytes: 0,
      min_free_percent_x100: 0,
      samples: []
    }
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

  defp drive_stats_opts(opts) do
    opts
    |> Keyword.take([:provider, :now_ms, :now_fun])
    |> maybe_put_provider_from_config()
  end

  defp maybe_put_provider_from_config(opts) do
    if Keyword.has_key?(opts, :provider) do
      opts
    else
      case Application.get_env(:maxio, :drive_stats, [])[:provider] do
        nil -> opts
        provider -> Keyword.put(opts, :provider, provider)
      end
    end
  end

  defp normalize_endpoint({node, drive}), do: {node, Path.expand(drive)}

  defp stat_int(stats, keys, default) do
    keys
    |> Enum.find_value(fn key ->
      case Map.get(stats, key) do
        value when is_integer(value) and value >= 0 -> value
        _other -> nil
      end
    end)
    |> case do
      nil -> default
      value -> value
    end
  end

  defp used_percent_x100(_used_bytes, 0), do: 0
  defp used_percent_x100(used_bytes, capacity_bytes), do: div(used_bytes * 10_000, capacity_bytes)

  defp min_free_percent(samples) do
    samples
    |> Enum.map(fn %{capacity_bytes: capacity_bytes, free_bytes: free_bytes} ->
      if capacity_bytes > 0, do: div(free_bytes * 10_000, capacity_bytes), else: 0
    end)
    |> min_int()
  end

  defp sum(samples, key),
    do: Enum.reduce(samples, 0, fn sample, acc -> acc + Map.fetch!(sample, key) end)

  defp min_field(samples, key), do: samples |> Enum.map(&Map.fetch!(&1, key)) |> min_int()
  defp min_int([]), do: 0
  defp min_int(values), do: Enum.min(values)

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
end
