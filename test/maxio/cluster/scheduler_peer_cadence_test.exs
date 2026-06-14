defmodule Maxio.Cluster.SchedulerPeerCadenceTest do
  @moduledoc """
  Optional true-peer evidence for scheduler singleton cadence.

  The test keeps schedulers and Repo access on the local node, while the lock
  quorum includes a real `:peer` LockServer. This proves peer quorum participates
  in the scheduler exclusion path without requiring remote Repo sandbox plumbing.
  """
  use Maxio.DataCase, async: false
  @moduletag :distributed

  if System.get_env("MAXIO_RUN_PEER_LOCK") != "1" do
    @moduletag skip:
                 "set MAXIO_RUN_PEER_LOCK=1 and run with --include distributed to collect true scheduler peer cadence evidence"
  end

  alias Maxio.Cluster.FreshDriveHeal.Scheduler, as: FreshScheduler
  alias Maxio.Cluster.SchedulerRuns

  setup do
    case ensure_distribution() do
      :ok ->
        case start_peer(:maxio_scheduler_lock_peer) do
          {:ok, peer_pid, peer_node} ->
            :ok = :erpc.call(peer_node, :code, :add_paths, [:code.get_path()])
            {:ok, _pid} = :erpc.call(peer_node, Maxio.Cluster.LockServer, :start_link, [[]])

            on_exit(fn -> :peer.stop(peer_pid) end)

            {:ok, nodes: [Node.self(), peer_node]}

          {:error, reason} ->
            flunk(
              ":peer startup failed; scheduler cadence evidence was not collected: #{inspect(reason)}"
            )
        end

      {:error, reason} ->
        flunk(
          "distributed Erlang is unavailable; scheduler cadence evidence was not collected: #{inspect(reason)}"
        )
    end
  end

  test "fresh-drive scheduler excludes a competitor through a true peer lock quorum", ctx do
    parent = self()

    runner = fn _opts ->
      send(parent, {:peer_runner_entered, self()})

      receive do
        :release_peer_runner -> {:ok, %{status: :ok, scanned: 1}}
      after
        5_000 -> {:ok, %{status: :ok, scanned: 1, reason: :test_timeout_release}}
      end
    end

    first =
      start_fresh_scheduler!(
        lock_nodes: ctx.nodes,
        runner: runner,
        scheduler_ledger: [node: :peer_scheduler_a]
      )

    second =
      start_fresh_scheduler!(
        lock_nodes: ctx.nodes,
        runner: runner,
        scheduler_ledger: [node: :peer_scheduler_b]
      )

    first_task = Task.async(fn -> FreshScheduler.run_now(first, []) end)
    assert_receive {:peer_runner_entered, runner_pid}, 1_000

    second_task = Task.async(fn -> FreshScheduler.run_now(second, []) end)
    assert {:error, :lock_unavailable} = Task.await(second_task, 2_000)
    refute_receive {:peer_runner_entered, _other_pid}, 20

    send(runner_pid, :release_peer_runner)
    assert {:ok, %{status: :ok, scanned: 1}} = Task.await(first_task, 2_000)

    assert %{status: "ok"} = SchedulerRuns.state(:fresh_drive_heal)

    statuses =
      SchedulerRuns.list_runs(scheduler: :fresh_drive_heal, limit: 10)
      |> Enum.map(& &1.status)
      |> Enum.sort()

    assert statuses == ["ok", "skipped"]
  end

  defp start_fresh_scheduler!(opts) do
    start_supervised!(
      Supervisor.child_spec(
        {Maxio.Cluster.FreshDriveHeal.Scheduler,
         Keyword.merge(
           [
             name: nil,
             enabled: false,
             probe_drive_health: false,
             lock_timeout_ms: 1_000,
             lock_ttl_ms: 60_000
           ],
           opts
         )},
        id: {:fresh_drive_heal_peer_scheduler, make_ref()}
      )
    )
  end

  defp ensure_distribution do
    start_result =
      case Node.start(:"maxio_scheduler_primary@127.0.0.1", :longnames) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
        {:error, reason} -> {:error, reason}
      end

    if start_result == :ok and Node.alive?() do
      Node.set_cookie(:maxio_test_cookie)
      :ok
    else
      {:error, {start_result, Node.self(), Node.alive?()}}
    end
  end

  defp start_peer(name) do
    try do
      {:ok, pid, node} =
        :peer.start_link(%{
          name: name,
          host: ~c"127.0.0.1",
          longnames: true,
          args: [~c"-setcookie", ~c"maxio_test_cookie"]
        })

      {:ok, pid, node}
    rescue
      error -> {:error, {:exception, error, Node.self(), Node.alive?()}}
    catch
      kind, reason -> {:error, {kind, reason, Node.self(), Node.alive?()}}
    end
  end
end
