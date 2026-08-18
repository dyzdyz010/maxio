defmodule Maxio.ActiveGauge do
  @moduledoc """
  Crash-safe in-flight ("active") gauge accounting on a shared ETS table.

  `try/after` alone cannot release an active gauge: a process killed by an exit
  signal (`Process.exit(pid, :kill)`, a brutal supervisor shutdown, an
  `async_stream` timeout) never runs its `after` block. Without an owner-side
  release path a single killed worker inflates the gauge for the lifetime of the
  node, and every consumer that paces work off that gauge (scrubber throttle,
  fresh-drive heal, cluster pressure aggregation) is silently throttled forever
  while the counters keep claiming the node is busy. That is exactly the silent
  failure AGENTS.md §3 forbids, so the release path must not depend on the
  claiming process still being alive.

  The gauge therefore keeps two shapes in the owning module's own ETS table:

    * aggregate rows `{key, count}` — the O(1) read path used by every consumer,
      semantics unchanged;
    * per-process ledger rows `{{:active_owner, pid, key}, count}` — how many
      units the claiming process currently holds.

  A process registers with the gauge owner (the long-lived process that also owns
  the ETS table) on its first claim; the owner monitors it. Normal completion
  still returns units through `release/2`; the owner only settles the ledger of
  processes that died before their `after` block could run.

  ## Write ordering (why the residue is always downward)

  The ledger row and the aggregate row are two separate ETS writes; **they are
  not atomic with respect to each other**, and a process can be killed between
  them. The ordering is therefore chosen so that every reachable residue biases
  the gauge *down*, never up:

    * `claim/3` writes the **ledger row first, the aggregate row second**. A death
      inside that window leaves "ledger holds a unit the aggregate never got".
      The owner then settles the ledger and decrements an aggregate that was
      never incremented — `decrement_aggregate/3` clamps the result at 0, so the
      gauge self-heals and the error does not accumulate.
    * `release/2` mirrors it: **aggregate first, ledger second**, which yields the
      same "ledger ≥ aggregate" residue and settles downward as well. The
      ordering is deliberate and kept — but the *outcome* is not as benign as
      the claim window, and this module will not pretend otherwise:

      a death inside the release window makes the gauge **under-report**. The
      aggregate has already been decremented, the ledger row still holds that
      unit, and the owner's settlement decrements a second time. The gauge then
      reads one below the truth. That −1 offset is **not** repaired by later
      claims and releases: it persists until the gauge next bottoms out (where
      `decrement_aggregate/3` clamps at 0), and several such deaths stack. A
      genuinely busy node can therefore read `0` active operations.

      The consequence is operational, not cosmetic:
      `Maxio.Cluster.IOPressure.local_count/1` derives `:storage_ops` and
      `:combined` from this gauge, so an under-reporting node looks *idle* to
      the scrubber, fresh-drive heal and rebalance pacers, and they will run at
      full speed straight over live S3 traffic. This ordering is still the right
      one — the alternative (aggregate first on claim) leaks *upward*
      permanently and never self-heals, which pauses maintenance forever — but
      "clamped and self-healing" describes the claim window only. The release
      window is a bounded, downward, self-limiting *mis-report*.

  The forbidden ordering is the reverse of `claim/3` (aggregate first): it leaves
  "aggregate incremented, no ledger row", the owner finds nothing to settle, and
  the unit leaks permanently — the exact failure mode this module exists to
  remove.

  ## Registration cost and the owner's throughput ceiling

  Registration is one synchronous call to the owner, cached in the process
  dictionary. The cache only amortises anything for long-lived repeat claimers;
  the main callers here — `Task.Supervisor.async_stream_nolink` workers, `:erpc`
  request processes, Bandit's per-connection processes — are one-shot, so in
  practice each of them pays exactly one registration call for its lifetime. The
  call is cheap (the owner does a `Process.monitor/1` and two map writes) and
  bounded by `@register_timeout_ms`.

  Because every first claim is serialised through that single process, **the
  gauge owner is a per-node ceiling on the rate of first claims**: no node can
  start monitored claims faster than one GenServer can retire monitor + two map
  writes. `@register_timeout_ms` bounds what an individual caller pays when the
  ceiling is hit; it does not raise the ceiling. Consumers that fan out per
  object (erasure coding issues K+M shard operations, each tracked through
  `Maxio.Cluster.DriveIO.track/3`) multiply the number of one-shot claimers, not
  the number of registrations per process.

  ## Degradation (which states are observable)

  Accounting is best-effort telemetry: it never fails the caller. Every claim
  lands in exactly one of three states, and the two of them that are real
  degradations are counted and logged:

    * **monitored** — the owner answered the registration call. A ledger row is
      written and a death of any kind is settled by the owner.

    * **unmonitored, declared** — `owner` is `nil` (a table created by the caller
      itself: CLI/IEx/unit-test usage) or the caller *is* the owner process.
      Nothing outlives the claimer to settle its ledger, so no ledger row is
      written and no counter moves. This is a supported, declared mode, not a
      degradation; making "no owner" an explicit argument value is what allows
      the next state to be reported honestly instead of being indistinguishable
      from it.

    * **unmonitored, degraded** — a named owner was declared but is not
      registered at this instant (both owners in this application —
      `Maxio.S3.InFlight` and `Maxio.Cluster.DriveIO`, see `Maxio.Application` —
      are supervised named processes, so this is their crash/restart window,
      during which live S3 and storage traffic runs through here), or its
      registration call failed or timed out. This claim writes **no ledger row**,
      so if the calling process is then killed by an exit signal its aggregate
      unit **leaks permanently upward**: nothing will ever collect it, and only
      the owner restarting (which drops the whole table) clears it. Both flavours
      bump a cumulative counter — `owner_absent_count/1` for an unregistered
      owner, `register_failure_count/1` for a failed call — and emit a
      rate-limited structured warning with a distinct `action:`.
      `Maxio.Cluster.DriveIO.snapshot/0`, and therefore `mix maxio.drive.io`,
      prints both counters.

  Ledger rows are deliberately **not** written for unmonitored claims: nothing
  would ever collect them, so the table would grow without bound on every
  fail-open claim. The trade is stated above — a bounded table against a
  per-claim permanent leak for the duration of the degradation.

  The one degradation this module cannot report is the gauge table itself having
  disappeared: both the counters and the rate-limit budget live in that table. In
  that case the claim's own aggregate write raises as well, into whatever
  fail-open wrapper the caller uses (`Maxio.Cluster.DriveIO` swallows it into its
  `safe_call/1`), so the accounting is lost there too.

  ## Known assumptions

  Ledger keys are `{:active_owner, pid, key}` and `monitor/2` deduplicates by
  pid. The accounting therefore assumes a pid is never reused while the previous
  holder's ledger rows or monitor entry are still live. BEAM pid numbers do wrap
  around, so a wrapped pid colliding with a still-monitored, still-ledgered pid
  would merge two processes' accounting and settle both at the first `:DOWN`.
  That needs pid wrap-around and a backlogged owner mailbox inside the same
  window; it is **accepted as a known assumption, not defended against**. Keying
  the ledger by the owner's monitor reference would remove it, at the cost of
  handing every claimer its reference (an extra round-trip on the claim path).
  """

  require Logger

  @ledger_prefix :active_owner

  # Registration is best-effort telemetry sitting *in front of* a storage
  # operation, so the wait must stay far below the operation it precedes. A
  # healthy owner replies in microseconds (one monitor + two map writes); beyond
  # that the owner is dead, restarting, or backed up, and waiting longer fixes
  # none of those — it only delays a storage call before degrading anyway.
  #
  # 50 ms is the budget this codebase already uses for telemetry-class waits
  # (`Maxio.Cluster.Transport`'s pressure-snapshot timeout and
  # `Maxio.Cluster.PressureAggregator`'s peer timeout are both 50 ms) and is two
  # orders of magnitude under the 5 s shard RPC budget in
  # `Maxio.Cluster.Transport`. A stuck owner therefore degrades cleanly instead
  # of cascading into shard-operation timeouts, which matters because
  # `Maxio.Cluster.ShardServer` tracks ~29 call sites through
  # `Maxio.Cluster.DriveIO.track/3`, each erasure-coded object multiplies them by
  # K+M, and `:erpc`-invoked one-shot processes pay one registration each.
  #
  # Note the standard `GenServer.call/3` caveat: a timed-out call can still leave
  # a late `{ref, reply}` in the caller's mailbox. The claimers here are one-shot
  # processes, so it dies with them.
  @register_timeout_ms 50

  # Bookkeeping rows for fail-open visibility. All of them live in the gauge
  # table but are never gauge keys, so no consumer's aggregate read is affected.
  @register_failure_key :active_gauge_register_failures
  @owner_absent_key :active_gauge_owner_absent
  @register_log_window_key :active_gauge_register_log_window
  @owner_absent_log_window_key :active_gauge_owner_absent_log_window
  @register_log_interval_ms 60_000

  @degradation_keys [@register_failure_key, @owner_absent_key]

  @type table :: atom()
  @type key :: atom()

  @typedoc "Registered name of the gauge owner, or `nil` for a table with no owner at all."
  @type owner :: atom() | nil

  @opaque owner_state :: %{monitors: %{reference() => pid()}, pids: %{pid() => reference()}}

  @doc "Owner-side bookkeeping state. Hold it in the gauge owner's GenServer state."
  @spec owner_state() :: owner_state()
  def owner_state, do: %{monitors: %{}, pids: %{}}

  @doc """
  Claim one unit of every `keys` counter for the calling process.

  The caller must have ensured `table` exists. `owner` is the registered name of
  the gauge owner process, or `nil` to declare that this table has no owner at
  all (CLI/IEx/unit-test tables). Registration with a named owner happens once
  per process (per table) and is synchronous, so once `claim/3` returns the owner
  is monitoring the caller and can settle its ledger if it is killed.

  When the owner is `nil`, or is the calling process itself, the claim is
  unmonitored **by declaration**: no ledger row, no counter, no log.

  When a *named* owner is unavailable (not registered, or its registration call
  failed) the claim degrades to aggregate-only counting. That degradation is
  counted and logged, and it is not free: no ledger row is written, so if this
  process is subsequently killed by an exit signal, the unit it just added to the
  aggregate **leaks permanently** — no owner will ever settle it and only a
  restart of the gauge owner clears it. See "Degradation" in the module docs.
  """
  @spec claim(table(), owner(), [key()]) :: :ok
  def claim(table, owner, keys) do
    pid = self()
    monitored? = ensure_registered(table, owner) == :monitored

    Enum.each(keys, fn key ->
      # Ledger row FIRST, aggregate row second — see "Write ordering" in the
      # module docs. Reversing these two lines reintroduces the permanent leak.
      if monitored? do
        ledger = ledger_key(pid, key)
        :ets.update_counter(table, ledger, {2, 1}, {ledger, 0})
      end

      :ets.update_counter(table, key, {2, 1}, {key, 0})
    end)
  end

  @doc """
  Return one unit of every `keys` counter held by the calling process.

  A death between this function's two writes leaves the gauge under-reporting by
  the units involved until it next bottoms out; see "Write ordering" in the
  module docs for why that ordering is still the right one.
  """
  @spec release(table(), [key()]) :: :ok
  def release(table, keys) do
    pid = self()

    Enum.each(keys, fn key ->
      # Aggregate FIRST, ledger second — the mirror of `claim/3`, so a death in
      # the window leaves "ledger ≥ aggregate" and settles downward (at the cost
      # of an under-report; see the module docs).
      decrement_aggregate(table, key, 1)
      ledger = ledger_key(pid, key)

      if :ets.update_counter(table, ledger, {2, -1}, {ledger, 0}) <= 0 do
        :ets.delete(table, ledger)
      end
    end)
  end

  @doc """
  Cumulative number of failed owner registration *calls* observed on `table`.

  Every increment is one claim that degraded to the leak-prone aggregate-only
  path because the owner was registered but did not answer (restarting, dead
  mid-call, or slower than `@register_timeout_ms`). Exposed through
  `Maxio.Cluster.DriveIO.snapshot/0` and `mix maxio.drive.io`, so the degradation
  is readable from the CLI without grepping logs.
  """
  @spec register_failure_count(table()) :: non_neg_integer()
  def register_failure_count(table), do: read_counter(table, @register_failure_key)

  @doc """
  Cumulative number of claims on `table` that found their declared owner missing.

  Every increment is one claim taken while the named owner process was not
  registered — for the supervised owners in `Maxio.Application` that is their
  crash/restart window. Like `register_failure_count/1` these claims are
  unmonitored and leak-prone, and the counter is exposed through
  `Maxio.Cluster.DriveIO.snapshot/0` and `mix maxio.drive.io`.
  """
  @spec owner_absent_count(table()) :: non_neg_integer()
  def owner_absent_count(table), do: read_counter(table, @owner_absent_key)

  @doc "Bookkeeping keys reported by `degradation_snapshot/1`."
  @spec degradation_keys() :: [atom()]
  def degradation_keys, do: @degradation_keys

  @doc """
  Both degradation counters of `table` in one map, for snapshot/CLI surfaces.
  """
  @spec degradation_snapshot(table()) :: %{atom() => non_neg_integer()}
  def degradation_snapshot(table) do
    %{
      @register_failure_key => register_failure_count(table),
      @owner_absent_key => owner_absent_count(table)
    }
  end

  @doc "Owner-side: start monitoring `pid` so its ledger can be settled when it dies."
  @spec monitor(owner_state(), pid()) :: owner_state()
  def monitor(state, pid) when is_pid(pid) do
    if Map.has_key?(state.pids, pid) do
      state
    else
      ref = Process.monitor(pid)

      %{
        monitors: Map.put(state.monitors, ref, pid),
        pids: Map.put(state.pids, pid, ref)
      }
    end
  end

  @doc """
  Owner-side: settle the ledger of a monitored process that went down.

  Returns the updated owner state; unknown monitor references are ignored so the
  owner can share its mailbox with other monitors.
  """
  @spec handle_down(owner_state(), reference(), table(), [key()]) :: owner_state()
  def handle_down(state, ref, table, keys) when is_reference(ref) do
    case Map.pop(state.monitors, ref) do
      {nil, _monitors} ->
        state

      {pid, monitors} ->
        release_ledger(table, pid, keys)
        %{monitors: monitors, pids: Map.delete(state.pids, pid)}
    end
  end

  @doc "Owner-side: return every unit `pid` still holds and drop its ledger rows."
  @spec release_ledger(table(), pid(), [key()]) :: :ok
  def release_ledger(table, pid, keys) do
    if :ets.whereis(table) != :undefined do
      Enum.each(keys, fn key ->
        ledger = ledger_key(pid, key)

        case :ets.lookup(table, ledger) do
          [{^ledger, held}] when is_integer(held) and held > 0 ->
            decrement_aggregate(table, key, held)

          _other ->
            :ok
        end

        :ets.delete(table, ledger)
      end)
    end

    :ok
  end

  # Declared ownerless table (CLI/IEx/unit tests): nothing outlives the caller to
  # settle its ledger and the caller said so. Supported mode, not a degradation —
  # this explicit `nil` is what lets the clause below report a *named* owner that
  # is merely missing right now.
  defp ensure_registered(_table, nil), do: :unmonitored

  defp ensure_registered(table, owner) do
    case Process.whereis(owner) do
      # A declared owner that is not registered at this instant. In this
      # application both owners are supervised named processes, so this is their
      # crash/restart window — with live S3/storage traffic taking the leak-prone
      # path meanwhile. Never silent (AGENTS.md §3).
      nil ->
        note_owner_absent(table, owner)
        :unmonitored

      owner_pid when owner_pid == self() ->
        # The owner claiming against its own table: a monitor on itself would
        # never fire while the table still exists, so there is nothing to settle.
        :unmonitored

      owner_pid ->
        if Process.get({__MODULE__, table}) == owner_pid do
          :monitored
        else
          register(owner_pid, table)
        end
    end
  end

  defp register(owner_pid, table) do
    GenServer.call(owner_pid, {:maxio_active_gauge_register, self()}, @register_timeout_ms)
    Process.put({__MODULE__, table}, owner_pid)
    :monitored
  catch
    # Telemetry must never take a storage/request path down with it: an owner that
    # is restarting simply leaves this process unmonitored for now. That is a real
    # degradation (this claim can leak if the process is killed), so it is counted
    # and logged rather than swallowed.
    :exit, reason ->
      note_register_failure(table, owner_pid, reason)
      :unmonitored
  end

  defp note_register_failure(table, owner_pid, reason) do
    failures = bump_counter(table, @register_failure_key)

    if claim_log_window(table, @register_log_window_key) do
      Logger.warning("active gauge owner registration failed; gauge degraded to aggregate-only",
        action: :active_gauge_register_failed,
        table: table,
        owner: inspect(owner_pid),
        failures: failures,
        log_window_ms: @register_log_interval_ms,
        reason: inspect(reason)
      )
    end

    :ok
  end

  defp note_owner_absent(table, owner) do
    absences = bump_counter(table, @owner_absent_key)

    if claim_log_window(table, @owner_absent_log_window_key) do
      Logger.warning(
        "active gauge owner is not registered; gauge degraded to aggregate-only",
        action: :active_gauge_owner_absent,
        table: table,
        owner: inspect(owner),
        absences: absences,
        log_window_ms: @register_log_interval_ms,
        reason: "owner process not registered (restarting, or never started)"
      )
    end

    :ok
  end

  # The rescue is deliberately narrow — only this ETS call. The gauge table can
  # disappear between the claim and this bookkeeping (owner shut down), and
  # visibility must never take a storage path down; but a `Logger` backend or
  # formatter raising `ArgumentError` must NOT be swallowed here, or the warning
  # this path exists to emit would vanish silently.
  defp bump_counter(table, key) do
    :ets.update_counter(table, key, {2, 1}, {key, 0})
  rescue
    ArgumentError -> :unknown
  end

  # Hand the log budget to exactly one caller per window and per degradation
  # kind, atomically and without any per-process state: the claim path is
  # dominated by one-shot processes, so a process-local rate limit would still
  # let every one of them log once and produce exactly the storm we are avoiding.
  # Separate window keys keep one kind of degradation from muting the other.
  defp claim_log_window(table, window_key) do
    window = div(System.monotonic_time(:millisecond), @register_log_interval_ms)

    replace_stale_window = [
      {{window_key, :"$1"}, [{:<, :"$1", window}], [{{window_key, window}}]}
    ]

    case :ets.select_replace(table, replace_stale_window) do
      1 -> true
      _other -> :ets.insert_new(table, {window_key, window})
    end
  rescue
    # Same narrow contract as `bump_counter/2`: the table may be gone. With no
    # table there is no rate-limit budget either, so this reports "no budget"
    # rather than logging unbounded during a table-less owner restart.
    ArgumentError -> false
  end

  defp read_counter(table, key) do
    case :ets.whereis(table) do
      :undefined ->
        0

      _tid ->
        case :ets.lookup(table, key) do
          [{^key, count}] when is_integer(count) and count > 0 -> count
          _other -> 0
        end
    end
  end

  defp decrement_aggregate(table, key, n) do
    if :ets.update_counter(table, key, {2, -n}, {key, 0}) < 0 do
      :ets.insert(table, {key, 0})
    end

    :ok
  end

  defp ledger_key(pid, key), do: {@ledger_prefix, pid, key}
end
