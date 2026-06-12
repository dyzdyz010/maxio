defmodule Maxio.Cluster.DriveIO do
  @moduledoc """
  Node-local storage IO pressure counters.

  This is an observational signal for background maintenance pacing. It tracks
  actual shard/sidecar filesystem operations executed by `ShardServer`; it does
  not reject foreground requests and it is not a persistence journal. Latency
  and throughput are application-level observations, not OS/device queue-depth
  or hardware telemetry. `max_latency_us` is a best-effort high-water mark under
  concurrent completions.
  """

  use GenServer

  @table :maxio_cluster_drive_io

  @active_counter_keys [
    :active_ops,
    :active_read_ops,
    :active_write_ops,
    :active_metadata_ops
  ]

  @cumulative_counter_keys [
    :read_ops,
    :write_ops,
    :metadata_ops,
    :delete_ops,
    :bytes_read,
    :bytes_written,
    :completed_ops,
    :total_latency_us,
    :max_latency_us,
    :errors
  ]

  @counter_keys @active_counter_keys ++ @cumulative_counter_keys

  @type op :: :read | :write | :metadata | :delete | :list | :probe
  @type snapshot :: %{
          active_ops: non_neg_integer(),
          active_read_ops: non_neg_integer(),
          active_write_ops: non_neg_integer(),
          active_metadata_ops: non_neg_integer(),
          read_ops: non_neg_integer(),
          write_ops: non_neg_integer(),
          metadata_ops: non_neg_integer(),
          delete_ops: non_neg_integer(),
          bytes_read: non_neg_integer(),
          bytes_written: non_neg_integer(),
          completed_ops: non_neg_integer(),
          total_latency_us: non_neg_integer(),
          max_latency_us: non_neg_integer(),
          avg_latency_us: non_neg_integer(),
          sample_age_ms: non_neg_integer(),
          throughput_bytes_per_sec: non_neg_integer(),
          read_throughput_bytes_per_sec: non_neg_integer(),
          write_throughput_bytes_per_sec: non_neg_integer(),
          errors: non_neg_integer()
        }

  @started_at_key :started_at_ms

  @doc false
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    create_table()
    {:ok, %{}}
  end

  @impl true
  def handle_call(:ensure_table, _from, state) do
    create_table()
    {:reply, :ok, state}
  end

  @doc "Track one storage IO operation and preserve the wrapped function result."
  @spec track(op(), (-> result), keyword()) :: result when result: term()
  def track(op, fun, opts \\ []) when is_function(fun, 0) do
    normalized_op = normalize_op(op)
    keys = counter_keys(op)
    started_at_us = System.monotonic_time(:microsecond)
    _ = safe_each(keys.start, &increment(&1, 1))

    try do
      result = fun.()
      record_bytes(op, result, opts)
      result
    rescue
      e ->
        _ = safe_call(fn -> increment(:errors, 1) end)
        reraise e, __STACKTRACE__
    catch
      kind, reason ->
        _ = safe_call(fn -> increment(:errors, 1) end)
        :erlang.raise(kind, reason, __STACKTRACE__)
    after
      elapsed_us = max(System.monotonic_time(:microsecond) - started_at_us, 0)
      _ = safe_call(fn -> record_latency(normalized_op, elapsed_us) end)
      _ = safe_each(keys.stop, &decrement(&1, 1))
    end
  end

  @doc "Return the current node-local active storage operation count."
  @spec active_ops() :: non_neg_integer()
  def active_ops, do: counter(:active_ops)

  @doc "Return the current node-local active storage operation count."
  @spec active_count() :: non_neg_integer()
  def active_count, do: active_ops()

  @doc "Return all node-local IO counters."
  @spec snapshot() :: snapshot()
  def snapshot do
    case safe_call(fn -> Map.new(@counter_keys, &{&1, counter(&1)}) end) do
      {:ok, snapshot} -> add_derived_snapshot_fields(snapshot)
      {:error, _reason} -> zero_snapshot()
    end
  end

  @doc false
  @spec reset() :: :ok
  def reset do
    _ =
      safe_call(fn ->
        ensure_table()
        Enum.each(@cumulative_counter_keys, &:ets.insert(@table, {&1, 0}))
        :ets.insert(@table, {@started_at_key, System.monotonic_time(:millisecond)})
      end)

    :ok
  end

  defp counter_keys(op) do
    case normalize_op(op) do
      :read ->
        %{
          start: [:active_ops, :active_read_ops, :read_ops],
          stop: [:active_ops, :active_read_ops]
        }

      :write ->
        %{
          start: [:active_ops, :active_write_ops, :write_ops],
          stop: [:active_ops, :active_write_ops]
        }

      :delete ->
        %{
          start: [:active_ops, :active_write_ops, :delete_ops],
          stop: [:active_ops, :active_write_ops]
        }

      :metadata ->
        %{
          start: [:active_ops, :active_metadata_ops, :metadata_ops],
          stop: [:active_ops, :active_metadata_ops]
        }
    end
  end

  defp normalize_op(op) when op in [:read, :write, :metadata, :delete], do: op
  defp normalize_op(op) when op in [:list, :probe], do: :metadata
  defp normalize_op(_op), do: :metadata

  defp record_bytes(op, result, opts) do
    _ =
      safe_call(fn ->
        bytes =
          case Keyword.get(opts, :bytes) do
            fun when is_function(fun, 1) -> fun.(result)
            n when is_integer(n) and n > 0 -> n
            _ -> 0
          end

        if bytes > 0 do
          case normalize_op(op) do
            :read -> increment(:bytes_read, bytes)
            :write -> increment(:bytes_written, bytes)
            :delete -> :ok
            :metadata -> :ok
          end
        end
      end)

    :ok
  end

  defp record_latency(_op, elapsed_us) when is_integer(elapsed_us) and elapsed_us >= 0 do
    increment(:completed_ops, 1)
    increment(:total_latency_us, elapsed_us)
    update_max(:max_latency_us, elapsed_us)
  end

  defp counter(key) do
    case safe_call(fn ->
           ensure_table()

           case :ets.lookup(@table, key) do
             [{^key, value}] when is_integer(value) and value > 0 -> value
             _ -> 0
           end
         end) do
      {:ok, value} -> value
      {:error, _reason} -> 0
    end
  end

  defp increment(key, n) do
    ensure_table()
    :ets.update_counter(@table, key, {2, n}, {key, 0})
    :ok
  end

  defp update_max(key, value) do
    ensure_table()

    # Telemetry is fail-open; this best-effort read/replace can underreport
    # during concurrent completions but must never affect storage results.
    current =
      case :ets.lookup(@table, key) do
        [{^key, current}] when is_integer(current) and current >= 0 -> current
        _ -> 0
      end

    if value > current do
      :ets.insert(@table, {key, value})
    end

    :ok
  end

  defp decrement(key, n) do
    ensure_table()
    value = :ets.update_counter(@table, key, {2, -n}, {key, 0})

    if value < 0 do
      :ets.insert(@table, {key, 0})
    end

    :ok
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined -> ensure_table_owner()
      tid -> tid
    end
  end

  defp ensure_table_owner do
    case Process.whereis(__MODULE__) do
      nil ->
        create_table()

      pid when pid == self() ->
        create_table()

      _pid ->
        :ok = GenServer.call(__MODULE__, :ensure_table)
        :ets.whereis(@table)
    end
  end

  defp create_table do
    tid =
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

    ensure_started_at()
    tid
  end

  defp ensure_started_at do
    if :ets.whereis(@table) != :undefined and :ets.lookup(@table, @started_at_key) == [] do
      :ets.insert(@table, {@started_at_key, System.monotonic_time(:millisecond)})
    end
  end

  defp safe_each(items, fun) do
    safe_call(fn -> Enum.each(items, fun) end)
  end

  defp safe_call(fun) when is_function(fun, 0) do
    {:ok, fun.()}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp add_derived_snapshot_fields(snapshot) do
    completed_ops = Map.get(snapshot, :completed_ops, 0)
    total_latency_us = Map.get(snapshot, :total_latency_us, 0)
    bytes_read = Map.get(snapshot, :bytes_read, 0)
    bytes_written = Map.get(snapshot, :bytes_written, 0)
    total_bytes = bytes_read + bytes_written
    sample_age_ms = sample_age_ms()

    snapshot
    |> Map.put(:avg_latency_us, safe_div(total_latency_us, completed_ops))
    |> Map.put(:sample_age_ms, sample_age_ms)
    |> Map.put(:throughput_bytes_per_sec, throughput_bytes_per_sec(total_bytes, sample_age_ms))
    |> Map.put(
      :read_throughput_bytes_per_sec,
      throughput_bytes_per_sec(bytes_read, sample_age_ms)
    )
    |> Map.put(
      :write_throughput_bytes_per_sec,
      throughput_bytes_per_sec(bytes_written, sample_age_ms)
    )
  end

  defp sample_age_ms do
    now_ms = System.monotonic_time(:millisecond)
    max(now_ms - started_at_ms(now_ms), 0)
  end

  defp started_at_ms(default) do
    ensure_table()

    case :ets.lookup(@table, @started_at_key) do
      [{@started_at_key, started_at_ms}] when is_integer(started_at_ms) ->
        started_at_ms

      _ ->
        :ets.insert(@table, {@started_at_key, default})
        default
    end
  end

  defp throughput_bytes_per_sec(_total_bytes, 0), do: 0

  defp throughput_bytes_per_sec(total_bytes, sample_age_ms),
    do: div(total_bytes * 1_000, sample_age_ms)

  defp safe_div(_n, 0), do: 0
  defp safe_div(n, d), do: div(n, d)

  defp zero_snapshot do
    @counter_keys
    |> Map.new(&{&1, 0})
    |> Map.put(:avg_latency_us, 0)
    |> Map.put(:sample_age_ms, 0)
    |> Map.put(:throughput_bytes_per_sec, 0)
    |> Map.put(:read_throughput_bytes_per_sec, 0)
    |> Map.put(:write_throughput_bytes_per_sec, 0)
  end
end
