defmodule Maxio.S3.InFlight do
  @moduledoc """
  Lightweight in-flight S3 request counter for background scrubber pacing.

  The counter is intentionally process-local to the BEAM node and best-effort:
  it is not an admission-control mechanism and it does not reject requests. It
  only exposes current S3 handler activity so background maintenance work can
  pause when live traffic is present.
  """

  use GenServer

  @table :maxio_s3_in_flight
  @key :total

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

  @doc "Run `fun` while counting one active S3 handler on this node."
  @spec track((-> result)) :: result when result: term()
  def track(fun) when is_function(fun, 0) do
    increment()

    try do
      fun.()
    after
      decrement()
    end
  end

  @doc "Return current in-flight S3 handler count for this BEAM node."
  @spec count() :: non_neg_integer()
  def count do
    case :ets.whereis(@table) do
      :undefined ->
        0

      _tid ->
        case :ets.lookup(@table, @key) do
          [{@key, value}] when is_integer(value) and value > 0 -> value
          _ -> 0
        end
    end
  end

  @doc "Return true when current in-flight count is above `threshold`."
  @spec over?(non_neg_integer()) :: boolean()
  def over?(threshold) when is_integer(threshold) and threshold >= 0 do
    count() > threshold
  end

  @doc false
  @spec reset() :: :ok
  def reset do
    ensure_table()
    :ets.insert(@table, {@key, 0})
    :ok
  end

  defp increment do
    ensure_table()
    :ets.update_counter(@table, @key, {2, 1}, {@key, 0})
    :ok
  end

  defp decrement do
    ensure_table()
    value = :ets.update_counter(@table, @key, {2, -1}, {@key, 0})

    if value < 0 do
      :ets.insert(@table, {@key, 0})
    end

    :ok
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        ensure_table_owner()

      tid ->
        tid
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
end
