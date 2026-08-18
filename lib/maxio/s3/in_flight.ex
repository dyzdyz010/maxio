defmodule Maxio.S3.InFlight do
  @moduledoc """
  Lightweight in-flight S3 request counter for background scrubber pacing.

  The counter is intentionally process-local to the BEAM node and best-effort:
  it is not an admission-control mechanism and it does not reject requests. It
  only exposes current S3 handler activity so background maintenance work can
  pause when live traffic is present.

  The gauge is claimed through `Maxio.ActiveGauge`: an S3 handler process killed
  by an exit signal never runs its `after` block, so this process settles what a
  dead handler still holds when it observes the `:DOWN`. Otherwise one killed
  handler would pin the counter above zero for the lifetime of the node and
  silently pause background maintenance forever.

  When this owner is itself restarting, claims degrade to unsettleable
  aggregate-only counting (see the "Degradation" section of `Maxio.ActiveGauge`).
  That is counted and logged; the counters for this table are readable from IEx
  with `Maxio.ActiveGauge.degradation_snapshot(:maxio_s3_in_flight)`. The storage
  gauge's equivalents are printed by `mix maxio.drive.io`.
  """

  use GenServer

  require Logger

  alias Maxio.ActiveGauge

  @table :maxio_s3_in_flight
  @key :total
  @active_counter_keys [@key]

  @doc false
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    create_table()
    {:ok, ActiveGauge.owner_state()}
  end

  @impl true
  def handle_call(:ensure_table, _from, state) do
    create_table()
    {:reply, :ok, state}
  end

  def handle_call({:maxio_active_gauge_register, pid}, _from, state) do
    {:reply, :ok, ActiveGauge.monitor(state, pid)}
  end

  # Resetting through the owner serialises the reset against every `:DOWN` that
  # has ALREADY reached this mailbox. It does not order the reset against a
  # `:DOWN` still in flight: BEAM only guarantees message order between one
  # sender/receiver pair, and the `:DOWN` comes from the dying handler, not from
  # the caller of `reset/0`. That is harmless — a late settlement only decrements
  # the counter, which `Maxio.ActiveGauge` clamps at 0.
  def handle_call(:reset, _from, state) do
    {:reply, zero_counter(), state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    {:noreply, ActiveGauge.handle_down(state, ref, @table, @active_counter_keys)}
  end

  # Defining `handle_info/2` above replaces the `use GenServer` default clause,
  # which logs unexpected messages. Keep that visibility rather than silently
  # dropping them (AGENTS.md §3: never fail silently).
  def handle_info(message, state) do
    Logger.warning("s3 in-flight counter owner received an unexpected message",
      action: :s3_in_flight_unexpected_message,
      reason: inspect(message)
    )

    {:noreply, state}
  end

  @doc "Run `fun` while counting one active S3 handler on this node."
  @spec track((-> result)) :: result when result: term()
  def track(fun) when is_function(fun, 0) do
    claim()

    try do
      fun.()
    after
      release()
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

  @doc """
  Zero the counter.

  Runs inside the owner process when it is alive, so any dead-handler settlement
  already queued in the owner's mailbox is applied first. A `:DOWN` still in
  flight is *not* ordered against this call (see `handle_call(:reset, ...)`);
  that only ever decrements the counter, which is clamped at 0.
  """
  @spec reset() :: :ok
  def reset do
    case Process.whereis(__MODULE__) do
      nil ->
        zero_counter()

      pid when pid == self() ->
        zero_counter()

      pid ->
        try do
          GenServer.call(pid, :reset)
        catch
          # Owner unavailable (restarting): fall back to the direct ETS reset.
          :exit, _reason -> zero_counter()
        end
    end
  end

  defp zero_counter do
    ensure_table()
    :ets.insert(@table, {@key, 0})
    :ok
  end

  defp claim do
    ensure_table()
    ActiveGauge.claim(@table, __MODULE__, @active_counter_keys)
  end

  defp release do
    ensure_table()
    ActiveGauge.release(@table, @active_counter_keys)
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
