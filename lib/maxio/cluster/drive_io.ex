defmodule Maxio.Cluster.DriveIO do
  @moduledoc """
  Node-local storage IO pressure counters.

  This is an observational signal for background maintenance pacing. It tracks
  actual shard/sidecar filesystem operations executed by `ShardServer`; it does
  not reject foreground requests and it is not a persistence journal.
  """

  use GenServer

  @table :maxio_cluster_drive_io

  @counter_keys [
    :active_ops,
    :active_read_ops,
    :active_write_ops,
    :active_metadata_ops,
    :read_ops,
    :write_ops,
    :metadata_ops,
    :delete_ops,
    :bytes_read,
    :bytes_written,
    :errors
  ]

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
          errors: non_neg_integer()
        }

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
    keys = counter_keys(op)
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
      {:ok, snapshot} -> snapshot
      {:error, _reason} -> zero_snapshot()
    end
  end

  @doc false
  @spec reset() :: :ok
  def reset do
    _ =
      safe_call(fn ->
        ensure_table()
        Enum.each(@counter_keys, &:ets.insert(@table, {&1, 0}))
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

  defp safe_each(items, fun) do
    safe_call(fn -> Enum.each(items, fun) end)
  end

  defp safe_call(fun) when is_function(fun, 0) do
    {:ok, fun.()}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp zero_snapshot, do: Map.new(@counter_keys, &{&1, 0})
end
