defmodule Maxio.ActiveGaugeTest.Owner do
  @moduledoc false
  use GenServer

  alias Maxio.ActiveGauge

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))

  @impl true
  def init(opts) do
    table = Keyword.fetch!(opts, :table)

    :ets.new(table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    {:ok,
     %{
       table: table,
       name: Keyword.fetch!(opts, :name),
       keys: Keyword.fetch!(opts, :keys),
       subscriber: Keyword.fetch!(opts, :subscriber),
       gauge: ActiveGauge.owner_state()
     }}
  end

  @impl true
  def handle_call({:maxio_active_gauge_register, pid}, _from, state) do
    {:reply, :ok, %{state | gauge: ActiveGauge.monitor(state.gauge, pid)}}
  end

  # Lets a test drive `claim/3` from inside the owner process itself, which is
  # the branch where `Process.whereis(owner) == self()`.
  def handle_call(:claim_from_owner, _from, state) do
    ActiveGauge.claim(state.table, state.name, state.keys)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    gauge = ActiveGauge.handle_down(state.gauge, ref, state.table, state.keys)
    # Settlement is observable, so the tests never have to guess when the owner
    # has processed the `:DOWN`.
    send(state.subscriber, {:gauge_settled, pid})
    {:noreply, %{state | gauge: gauge}}
  end
end

defmodule Maxio.ActiveGaugeTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Maxio.ActiveGauge
  alias Maxio.ActiveGaugeTest.Owner

  @table :maxio_active_gauge_test
  @owner Maxio.ActiveGaugeTest.Owner
  @key :active_ops
  @register_failed_message "active gauge owner registration failed"
  @owner_absent_message "active gauge owner is not registered"

  setup do
    start_supervised!({Owner, name: @owner, table: @table, keys: [@key], subscriber: self()})
    :ok
  end

  test "a claim killed between its two ETS writes cannot leak the aggregate" do
    worker = spawn_claimer(self())
    ref = Process.monitor(worker)

    # White-box, but deterministic: poisoning this worker's ledger row makes the
    # ledger write inside `claim/3` raise `ArgumentError`, which stops the claim
    # in exactly the window between its two (non-atomic) ETS writes — the window
    # that used to leak — with no timing assumptions at all.
    #
    # With the aggregate written first (the rejected ordering) this test observes
    # `active_ops == 1` with no ledger row for the owner to settle: a permanent
    # leak. With the ledger written first, the aggregate is never touched.
    :ets.insert(@table, {ledger_key(worker), :not_a_counter})

    capture_log(fn ->
      send(worker, :claim)

      assert_receive {:DOWN, ^ref, :process, ^worker, reason}
      refute reason == :normal

      assert_receive {:gauge_settled, ^worker}
    end)

    assert counter(@key) == 0
    assert :ets.lookup(@table, ledger_key(worker)) == []
  end

  test "settling a ledger row the aggregate never received clamps the gauge at zero" do
    worker = spawn_claimer(self())

    send(worker, :claim)
    assert_receive {:claimed, ^worker}

    assert counter(@key) == 1
    assert :ets.lookup(@table, ledger_key(worker)) == [{ledger_key(worker), 1}]

    # The only residue the fixed write order can leave behind: the ledger holds a
    # unit the aggregate never got. Settling it must clamp at 0, not go negative
    # and not accumulate.
    :ets.insert(@table, {@key, 0})

    Process.exit(worker, :kill)
    assert_receive {:gauge_settled, ^worker}

    assert counter(@key) == 0
    assert :ets.lookup(@table, ledger_key(worker)) == []
  end

  test "a killed claimer's units are returned by the owner" do
    worker = spawn_claimer(self())

    send(worker, :claim)
    assert_receive {:claimed, ^worker}
    assert counter(@key) == 1

    Process.exit(worker, :kill)
    assert_receive {:gauge_settled, ^worker}

    assert counter(@key) == 0
    assert ledger_rows() == []
  end

  test "a failed registration is counted, logged once per window, and writes no ledger row" do
    log =
      capture_log(fn ->
        claim_against_dying_owner(:maxio_active_gauge_test_dying_owner_a)
        claim_against_dying_owner(:maxio_active_gauge_test_dying_owner_b)
      end)

    # Both degradations are counted: fail-open is a real (leak-prone) downgrade,
    # so it must never be invisible to operators.
    assert ActiveGauge.register_failure_count(@table) == 2

    # ...but the hot path must not turn a flapping owner into a log storm.
    assert log =~ @register_failed_message
    assert occurrences(log, @register_failed_message) == 1

    # Degraded claims still move the aggregate (previous behaviour preserved)...
    assert counter(@key) == 2
    # ...and write no ledger row: nothing monitors this process, so a ledger row
    # would never be collected and the table would grow without bound.
    assert ledger_rows() == []
  end

  test "a declared-nil owner counts the aggregate, writes no ledger row, and is not a degradation" do
    log = capture_log(fn -> ActiveGauge.claim(@table, nil, [@key]) end)

    assert counter(@key) == 1
    assert ledger_rows() == []

    # `nil` owner is the declared "this table has no owner at all" mode
    # (CLI/IEx/unit-test tables): nothing could ever have settled this claim, so
    # nothing degraded and nothing is reported.
    assert ActiveGauge.register_failure_count(@table) == 0
    assert ActiveGauge.owner_absent_count(@table) == 0
    refute log =~ @owner_absent_message
    refute log =~ @register_failed_message
  end

  test "a named owner that is not registered is counted, logged once per window, and unmonitored" do
    log =
      capture_log(fn ->
        ActiveGauge.claim(@table, :maxio_active_gauge_test_absent_owner, [@key])
        ActiveGauge.claim(@table, :maxio_active_gauge_test_absent_owner, [@key])
      end)

    # Degraded claims still move the aggregate (previous behaviour preserved)...
    assert counter(@key) == 2
    # ...and write no ledger row: nothing monitors this process, so a ledger row
    # would never be collected and the table would grow without bound.
    assert ledger_rows() == []

    # Expectation deliberately raised from the previous "always 0 failures": a
    # *named* owner that is not registered is the supervised owner's
    # crash/restart window (both gauge owners are supervised named processes),
    # during which live traffic silently took the unsettleable path. Counting it
    # is what makes "no owner by declaration" and "owner missing right now"
    # distinguishable at all.
    assert ActiveGauge.owner_absent_count(@table) == 2
    # It is also a different failure from a registration call that failed, and
    # is tracked separately.
    assert ActiveGauge.register_failure_count(@table) == 0

    assert ActiveGauge.degradation_snapshot(@table) == %{
             active_gauge_register_failures: 0,
             active_gauge_owner_absent: 2
           }

    # Same rate limit as the failed-call path: a flapping owner must not turn the
    # hot path into a log storm, and the two kinds do not mute each other.
    assert log =~ @owner_absent_message
    assert occurrences(log, @owner_absent_message) == 1
  end

  test "the two degradations keep separate log windows and do not mute each other" do
    # Both kinds of degradation on the *same* table, inside the same rate-limit
    # window. Every other test here builds a fresh owner/table and triggers only
    # one kind, so nothing else would notice the two paths sharing a window key —
    # and sharing it would mean the first degradation to fire silences the other
    # for a full minute, which is exactly how an operator loses the signal that a
    # second, different failure started.
    log =
      capture_log(fn ->
        ActiveGauge.claim(@table, :maxio_active_gauge_test_absent_owner_pair, [@key])
        claim_against_dying_owner(:maxio_active_gauge_test_dying_owner_pair)
      end)

    # The second degradation must still get its own log line even though the
    # first one already spent its window.
    assert occurrences(log, @owner_absent_message) == 1
    assert occurrences(log, @register_failed_message) == 1

    # ...and the two are counted apart, never folded into one number.
    assert ActiveGauge.owner_absent_count(@table) == 1
    assert ActiveGauge.register_failure_count(@table) == 1

    assert ActiveGauge.degradation_snapshot(@table) == %{
             active_gauge_register_failures: 1,
             active_gauge_owner_absent: 1
           }

    # Both are fail-open aggregate-only claims: the units land, no ledger row does.
    assert counter(@key) == 2
    assert ledger_rows() == []
  end

  test "the owner claiming against its own table counts the aggregate but writes no ledger row" do
    # `GenServer.call/2` returning is the synchronisation point: the claim ran
    # inside the owner process before the reply was sent.
    assert GenServer.call(@owner, :claim_from_owner) == :ok

    assert counter(@key) == 1
    # A monitor on itself would never fire while the table still exists (the
    # table dies with the owner), so there is nothing a ledger row could settle.
    assert ledger_rows() == []

    # ...and, like the `nil` owner, this is a declared mode rather than a
    # degradation, so neither counter moves.
    assert ActiveGauge.register_failure_count(@table) == 0
    assert ActiveGauge.owner_absent_count(@table) == 0
  end

  test "a death inside the release window makes the gauge under-report until it bottoms out" do
    holder = spawn_claimer(self())
    victim = spawn_claimer(self())

    send(holder, :claim)
    assert_receive {:claimed, ^holder}
    send(victim, :claim)
    assert_receive {:claimed, ^victim}

    assert counter(@key) == 2

    # White-box, and deliberately so: `release/2` writes the aggregate first and
    # the ledger row second, and those two ETS writes are not atomic. Killing a
    # real worker exactly between them is timing-dependent, so the window is
    # reproduced by performing precisely `release/2`'s first write on the
    # victim's behalf (the aggregate decrement) and then killing it with its
    # ledger row still holding the unit.
    :ets.update_counter(@table, @key, {2, -1})
    Process.exit(victim, :kill)
    assert_receive {:gauge_settled, ^victim}

    # The owner settles the ledger row the victim never got to clear, so the same
    # unit is subtracted twice. The gauge now reads 0 while `holder` is still
    # holding one: this is the documented *under*-report — a busy node can read
    # as idle, which is why `Maxio.Cluster.IOPressure` consumers may pace
    # maintenance too aggressively rather than too conservatively.
    assert counter(@key) == 0
    assert :ets.lookup(@table, ledger_key(victim)) == []
    assert :ets.lookup(@table, ledger_key(holder)) == [{ledger_key(holder), 1}]

    # The deficit is bounded, not permanent: the holder's own release clamps at
    # 0, so the gauge is truthful again once it bottoms out.
    send(holder, :release)
    assert_receive {:released, ^holder}

    assert counter(@key) == 0
    assert ledger_rows() == []
  end

  test "release/2 decrements the aggregate before it touches the ledger row" do
    holder = spawn_claimer(self())
    victim = spawn_claimer(self())

    send(holder, :claim)
    assert_receive {:claimed, ^holder}
    send(victim, :claim)
    assert_receive {:claimed, ^victim}

    assert counter(@key) == 2

    ref = Process.monitor(victim)

    # White-box and deterministic, and unlike the test above it drives the real
    # `release/2` rather than reproducing its first write by hand — which is the
    # whole point: this is what pins the *order* of the two writes inside
    # `release/2` itself.
    #
    # Poisoning the victim's ledger row makes `release/2`'s ledger write raise
    # `ArgumentError`, stopping the release in exactly the window between its two
    # (non-atomic) ETS writes, with no timing assumptions at all. Which of the two
    # writes has already landed when it stops is therefore a direct readout of
    # their order:
    #
    #   * aggregate first (the ordering in force): the aggregate decrement has
    #     already happened, so the gauge drops to the holder's single unit and the
    #     owner's settlement finds nothing to return — the documented downward
    #     residue;
    #   * ledger first (the rejected ordering): nothing decremented the aggregate,
    #     the owner then deletes the ledger row without returning anything, and the
    #     victim's unit is stranded in the aggregate **permanently** — the upward
    #     leak this module exists to remove.
    :ets.insert(@table, {ledger_key(victim), :not_a_counter})

    capture_log(fn ->
      send(victim, :release)

      assert_receive {:DOWN, ^ref, :process, ^victim, reason}
      refute reason == :normal

      assert_receive {:gauge_settled, ^victim}
    end)

    # 2 - 1: the victim's unit came back before its process died. Reading 2 here
    # would be the permanent upward leak; no later claim or release repairs it.
    assert counter(@key) == 1
    assert :ets.lookup(@table, ledger_key(victim)) == []
    assert :ets.lookup(@table, ledger_key(holder)) == [{ledger_key(holder), 1}]
  end

  test "release returns the claimed unit and drops the ledger row" do
    worker = spawn_claimer(self())

    send(worker, :claim)
    assert_receive {:claimed, ^worker}

    send(worker, :release)
    assert_receive {:released, ^worker}

    assert counter(@key) == 0
    assert ledger_rows() == []
  end

  defp spawn_claimer(parent) do
    spawn(fn ->
      receive do
        :claim ->
          ActiveGauge.claim(@table, @owner, [@key])
          send(parent, {:claimed, self()})

          receive do
            :release ->
              ActiveGauge.release(@table, [@key])
              send(parent, {:released, self()})
          end
      end
    end)
  end

  # An owner that dies while answering the registration call: `GenServer.call`
  # notices via its monitor and exits immediately, so this exercises the
  # fail-open branch without waiting for `@register_timeout_ms`.
  defp claim_against_dying_owner(name) do
    pid =
      spawn(fn ->
        receive do
          {:"$gen_call", _from, {:maxio_active_gauge_register, _pid}} -> exit(:owner_boom)
        end
      end)

    Process.register(pid, name)
    ActiveGauge.claim(@table, name, [@key])
  end

  defp counter(key) do
    case :ets.lookup(@table, key) do
      [{^key, value}] -> value
      [] -> 0
    end
  end

  # Mirrors `Maxio.ActiveGauge`'s private ledger row shape on purpose: these are
  # white-box assertions about the two-row layout.
  defp ledger_key(pid), do: {:active_owner, pid, @key}

  defp ledger_rows, do: :ets.match_object(@table, {{:active_owner, :_, :_}, :_})

  defp occurrences(string, pattern), do: length(String.split(string, pattern)) - 1
end
