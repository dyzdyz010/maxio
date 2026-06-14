defmodule Maxio.Cluster.SchedulerCadenceTest do
  use Maxio.DataCase, async: false

  alias Maxio.Cluster.FreshDriveHeal.Scheduler, as: FreshScheduler
  alias Maxio.Cluster.Rebalance.Scheduler, as: RebalanceScheduler
  alias Maxio.Cluster.{Rebalance.Jobs, SchedulerRuns, Topology}

  @t0 ~U[2026-06-14 00:00:00.000000Z]

  test "fresh-drive heal scheduler cadence lets only one local instance enter the runner" do
    parent = self()

    runner = fn _opts ->
      send(parent, {:fresh_runner_entered, self()})

      receive do
        :release_fresh_runner -> {:ok, %{status: :ok, scanned: 1}}
      after
        5_000 -> {:ok, %{status: :ok, scanned: 1, reason: :test_timeout_release}}
      end
    end

    first =
      start_fresh_scheduler!(
        runner: runner,
        probe_drive_health: false,
        scheduler_ledger: [node: :fresh_scheduler_a]
      )

    second =
      start_fresh_scheduler!(
        runner: runner,
        probe_drive_health: false,
        scheduler_ledger: [node: :fresh_scheduler_b]
      )

    first_task = Task.async(fn -> FreshScheduler.run_now(first, []) end)
    assert_receive {:fresh_runner_entered, runner_pid}, 1_000

    second_task = Task.async(fn -> FreshScheduler.run_now(second, []) end)
    assert {:error, :lock_unavailable} = Task.await(second_task, 1_000)
    refute_receive {:fresh_runner_entered, _other_pid}, 20

    send(runner_pid, :release_fresh_runner)
    assert {:ok, %{status: :ok, scanned: 1}} = Task.await(first_task, 1_000)

    assert_effective_state(:fresh_drive_heal, "ok")
    assert_run_statuses(:fresh_drive_heal, ["ok", "skipped"])
  end

  test "rebalance scheduler cadence lets only one local instance enter the copy runner" do
    parent = self()
    topology = two_set_topology("scheduler-cadence-rebalance")
    {:ok, job} = Jobs.start_decommission(0, topology: topology, include_drive_stats: false)

    copy_runner = fn job_id, _opts ->
      send(parent, {:rebalance_runner_entered, self(), job_id})

      receive do
        :release_rebalance_runner -> {:ok, %{status: :partial, job_id: job_id}}
      after
        5_000 -> {:ok, %{status: :partial, job_id: job_id, reason: :test_timeout_release}}
      end
    end

    first =
      start_rebalance_scheduler!(
        topology: topology,
        destination_set_id: 1,
        copy_runner: copy_runner,
        scheduler_ledger: [node: :rebalance_scheduler_a]
      )

    second =
      start_rebalance_scheduler!(
        topology: topology,
        destination_set_id: 1,
        copy_runner: copy_runner,
        scheduler_ledger: [node: :rebalance_scheduler_b]
      )

    first_task = Task.async(fn -> RebalanceScheduler.run_now(first, []) end)
    assert_receive {:rebalance_runner_entered, runner_pid, job_id}, 1_000
    assert job_id == job.id

    second_task = Task.async(fn -> RebalanceScheduler.run_now(second, []) end)
    assert {:error, :lock_unavailable} = Task.await(second_task, 1_000)
    refute_receive {:rebalance_runner_entered, _other_pid, _other_job_id}, 20

    send(runner_pid, :release_rebalance_runner)

    assert {:ok, %{phase: :copy, status: :partial, job_id: ^job_id}} =
             Task.await(first_task, 1_000)

    assert_effective_state(:rebalance, "ok")
    assert_run_statuses(:rebalance, ["ok", "skipped"])
  end

  test "scheduled backoff cadence skips all local instances without clearing effective failure" do
    backoff_now = DateTime.add(@t0, 1, :second)
    parent = self()

    {:ok, %{run: failed_run, state: failed}} =
      SchedulerRuns.record(
        :fresh_drive_heal,
        :scheduled,
        @t0,
        @t0,
        {:error, :boom},
        failure_threshold: 1,
        backoff_ms: 60_000
      )

    first =
      start_fresh_scheduler!(
        enabled: true,
        initial_delay_ms: 60_000,
        interval_ms: 60_000,
        probe_drive_health: false,
        scheduler_ledger: [
          failure_threshold: 1,
          backoff_ms: 60_000,
          now_fun: fn -> backoff_now end,
          node: :fresh_scheduler_backoff_a
        ],
        runner: fn _opts ->
          send(parent, :fresh_runner_called_during_backoff)
          {:ok, %{status: :ok}}
        end
      )

    second =
      start_fresh_scheduler!(
        enabled: true,
        initial_delay_ms: 60_000,
        interval_ms: 60_000,
        probe_drive_health: false,
        scheduler_ledger: [
          failure_threshold: 1,
          backoff_ms: 60_000,
          now_fun: fn -> backoff_now end,
          node: :fresh_scheduler_backoff_b
        ],
        runner: fn _opts ->
          send(parent, :fresh_runner_called_during_backoff)
          {:ok, %{status: :ok}}
        end
      )

    send(first, :run)
    send(second, :run)
    _ = :sys.get_state(first)
    _ = :sys.get_state(second)

    refute_receive :fresh_runner_called_during_backoff, 20

    state = SchedulerRuns.state(:fresh_drive_heal)
    assert state.status == "failed"
    assert state.alert_status == "alert"
    assert state.backoff_until == failed.backoff_until
    assert state.last_run_id == failed_run.id

    assert_run_statuses(:fresh_drive_heal, ["failed", "skipped", "skipped"])
  end

  defp start_fresh_scheduler!(opts) do
    start_supervised!(
      Supervisor.child_spec(
        {Maxio.Cluster.FreshDriveHeal.Scheduler,
         Keyword.merge(
           [name: nil, enabled: false, lock_nodes: [Node.self()], lock_timeout_ms: 50],
           opts
         )},
        id: {:fresh_drive_heal_scheduler, make_ref()}
      )
    )
  end

  defp start_rebalance_scheduler!(opts) do
    start_supervised!(
      Supervisor.child_spec(
        {Maxio.Cluster.Rebalance.Scheduler,
         Keyword.merge(
           [name: nil, enabled: false, lock_nodes: [Node.self()], lock_timeout_ms: 50],
           opts
         )},
        id: {:rebalance_scheduler, make_ref()}
      )
    )
  end

  defp assert_effective_state(scheduler, status) do
    state = SchedulerRuns.state(scheduler)
    assert state.status == status
    assert state.last_run_id
  end

  defp assert_run_statuses(scheduler, expected) do
    statuses =
      SchedulerRuns.list_runs(scheduler: scheduler, limit: 10)
      |> Enum.map(& &1.status)
      |> Enum.sort()

    assert statuses == Enum.sort(expected)
  end

  defp two_set_topology(prefix) do
    base = Path.join(System.tmp_dir!(), "maxio_#{prefix}_#{System.unique_integer([:positive])}")
    endpoints0 = for i <- 0..1, do: {Node.self(), Path.join(base, "s0d#{i}")}
    endpoints1 = for i <- 0..1, do: {Node.self(), Path.join(base, "s1d#{i}")}

    Topology.parse_and_validate!(
      data_shards: 1,
      parity_shards: 1,
      block_size: 1024,
      allow_colocated_endpoints: true,
      pools: [%{id: 0, sets: [%{id: 0, endpoints: endpoints0}, %{id: 1, endpoints: endpoints1}]}]
    )
  end
end
