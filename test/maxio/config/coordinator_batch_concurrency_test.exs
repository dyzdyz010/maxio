defmodule Maxio.Config.CoordinatorBatchConcurrencyTest do
  use Maxio.DataCase, async: false

  import Ecto.Query

  alias Maxio.Config
  alias Maxio.Config.{RuntimeConfig, RuntimeConfigAudit, Store}

  setup do
    supervisor = start_supervised!(Task.Supervisor)
    cleanup_unboxed!()
    Store.reset_local!()

    on_exit(fn ->
      cleanup_unboxed!()
      Store.reset_local!()
    end)

    {:ok, supervisor: supervisor}
  end

  test "multi-subsystem batch serializes with an overlapping legacy single writer", %{
    supervisor: supervisor
  } do
    assert_batch_available!()
    owner = self()
    release = make_ref()

    batch =
      Task.Supervisor.async_nolink(supervisor, fn ->
        unboxed(fn ->
          checkpoint = fn
            :before_first_row_read ->
              send(owner, {:batch_holds_all_locks, self()})

              receive do
                {:release_batch, ^release} -> :ok
              after
                10_000 -> raise "batch checkpoint timed out"
              end

            _phase ->
              :ok
          end

          mutate_many(
            [
              {:s3, [{:set, :clock_skew_ms, 111}]},
              {:listing, [{:set, :sql_hard_limit, 111}]}
            ],
            request_id: "req-batch-holder",
            checkpoint: checkpoint
          )
        end)
      end)

    assert_receive {:batch_holds_all_locks, holder_pid}, 5_000

    legacy =
      Task.Supervisor.async_nolink(supervisor, fn ->
        unboxed(fn ->
          backend = backend_pid!()
          send(owner, {:legacy_backend, backend})

          Config.set(:listing, :sql_hard_limit, 222,
            source: "cli",
            request_id: "req-legacy-overlap"
          )
        end)
      end)

    assert_receive {:legacy_backend, backend}, 5_000
    assert_backend_waits_on_lock!(backend)
    send(holder_pid, {:release_batch, release})

    assert {:ok, %{changed_count: 2}} = Task.await(batch, 10_000)
    assert {:ok, %{changed?: true, version: 2}} = Task.await(legacy, 10_000)

    assert unboxed(fn ->
             Repo.all(
               from row in RuntimeConfig,
                 where: row.subsystem in ["listing", "s3"],
                 order_by: [asc: row.subsystem],
                 select: {row.subsystem, row.value, row.version}
             )
           end) == [
             {"listing", %{"v" => 222}, 2},
             {"s3", %{"v" => 111}, 1}
           ]
  end

  test "opposite input order batches normalize lock order and finish without deadlock", %{
    supervisor: supervisor
  } do
    assert_batch_available!()
    owner = self()
    release = make_ref()
    capture_id = attach_lock_capture(owner)
    on_exit(fn -> :telemetry.detach(capture_id) end)

    first =
      Task.Supervisor.async_nolink(supervisor, fn ->
        unboxed(fn ->
          checkpoint = fn
            {:after_advisory_lock, :listing} ->
              send(owner, {:first_batch_holds_listing, self()})

              receive do
                {:release_first, ^release} -> :ok
              after
                10_000 -> raise "first batch checkpoint timed out"
              end

            _phase ->
              :ok
          end

          mutate_many(
            [
              {:s3, [{:set, :clock_skew_ms, 10}]},
              {:listing, [{:set, :sql_hard_limit, 10}]}
            ],
            request_id: "req-first-batch",
            checkpoint: checkpoint
          )
        end)
      end)

    assert_receive {:first_batch_holds_listing, first_pid}, 5_000

    second =
      Task.Supervisor.async_nolink(supervisor, fn ->
        unboxed(fn ->
          backend = backend_pid!()
          send(owner, {:second_batch_backend, backend})

          mutate_many(
            [
              {:listing, [{:set, :sql_hard_limit, 20}]},
              {:s3, [{:set, :clock_skew_ms, 20}]}
            ],
            request_id: "req-second-batch"
          )
        end)
      end)

    assert_receive {:second_batch_backend, backend}, 5_000
    assert_backend_waits_on_lock!(backend)
    send(first_pid, {:release_first, release})

    assert {:ok, %{changed_count: 2}} = Task.await(first, 10_000)
    assert {:ok, %{changed_count: 2}} = Task.await(second, 10_000)

    lock_params = drain_lock_params(capture_id, %{})
    assert lock_params[first.pid] == [["listing"], ["s3"]]
    assert lock_params[second.pid] == [["listing"], ["s3"]]

    assert unboxed(fn ->
             Repo.all(
               from row in RuntimeConfig,
                 where: row.subsystem in ["listing", "s3"],
                 order_by: [asc: row.subsystem],
                 select: {row.subsystem, row.value, row.version}
             )
           end) == [
             {"listing", %{"v" => 20}, 2},
             {"s3", %{"v" => 20}, 2}
           ]
  end

  defp mutate_many(groups, extra_opts) do
    apply(Config, :mutate_many, [groups, [source: "admin_api"] ++ extra_opts])
  end

  defp assert_batch_available! do
    Code.ensure_loaded!(Config)

    assert function_exported?(Config, :mutate_many, 2),
           "Maxio.Config.mutate_many/2 is required for cross-subsystem serialization"
  end

  defp attach_lock_capture(owner) do
    id = {__MODULE__, :lock_params, make_ref()}
    prefix = Keyword.get(Repo.config(), :telemetry_prefix) || [:maxio, :repo]

    :ok =
      :telemetry.attach(
        id,
        prefix ++ [:query],
        fn _event, _measurements, metadata, state ->
          if is_binary(metadata.query) and
               String.contains?(metadata.query, "pg_advisory_xact_lock") do
            send(state.owner, {
              :batch_lock_params,
              state.id,
              self(),
              Map.get(metadata, :params, [])
            })
          end
        end,
        %{owner: owner, id: id}
      )

    id
  end

  defp drain_lock_params(id, by_pid) do
    receive do
      {:batch_lock_params, ^id, pid, params} ->
        drain_lock_params(id, Map.update(by_pid, pid, [params], &(&1 ++ [params])))
    after
      0 -> by_pid
    end
  end

  defp assert_backend_waits_on_lock!(backend_pid) do
    deadline = System.monotonic_time(:millisecond) + 5_000
    poll_backend_lock!(backend_pid, deadline, nil)
  end

  defp poll_backend_lock!(backend_pid, deadline, previous) do
    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        Repo,
        "SELECT wait_event_type, wait_event, state FROM pg_stat_activity WHERE pid = $1",
        [backend_pid]
      )

    observed = List.first(rows)

    cond do
      match?(["Lock", _event, _state], observed) ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("backend did not wait on config lock: #{inspect(observed || previous)}")

      true ->
        :erlang.yield()
        poll_backend_lock!(backend_pid, deadline, observed || previous)
    end
  end

  defp backend_pid! do
    %{rows: [[pid]]} = Ecto.Adapters.SQL.query!(Repo, "SELECT pg_backend_pid()")
    pid
  end

  defp cleanup_unboxed! do
    unboxed(fn ->
      Repo.delete_all(
        from audit in RuntimeConfigAudit,
          where: audit.subsystem in ["listing", "s3"]
      )

      Repo.delete_all(from row in RuntimeConfig, where: row.subsystem in ["listing", "s3"])
    end)
  end

  defp unboxed(fun), do: Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fun)
end
