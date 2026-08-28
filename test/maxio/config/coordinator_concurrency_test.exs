defmodule Maxio.Config.CoordinatorConcurrencyTest do
  use Maxio.DataCase, async: false

  import Ecto.Query

  alias Maxio.Config
  alias Maxio.Config.{RuntimeConfig, RuntimeConfigAudit, Store}
  alias Maxio.Test.ConfigBatchSchema

  setup do
    task_supervisor = start_supervised!(Task.Supervisor)
    cleanup_unboxed!()
    Store.reset_local!()

    on_exit(fn ->
      cleanup_unboxed!()
      Store.reset_local!()
    end)

    {:ok, task_supervisor: task_supervisor}
  end

  test "batch transaction takes the exact advisory lock before any runtime query" do
    # Catches moving the lock after the authoritative read, changing its namespace, or hashing in
    # the BEAM instead of PostgreSQL.
    assert_mutate_available!()

    queries =
      capture_current_process_queries(fn -> mutate(:listing, [{:set, :sql_hard_limit, 41}]) end)

    statements = substantive_statements(queries)
    assert [lock_query | _rest] = statements

    runtime_index = Enum.find_index(statements, &String.contains?(&1, "runtime_configs"))

    assert is_integer(runtime_index),
           "batch emitted no authoritative runtime query: #{inspect(queries)}"

    assert runtime_index > 0

    assert lock_query ==
             "SELECT pg_advisory_xact_lock(1297638214, hashtext($1))"
  end

  test "old single-key writer uses the same exact lock before its runtime query" do
    # Catches retaining the old SELECT FOR UPDATE fast path after batch coordination is added.
    queries =
      capture_current_process_queries(fn ->
        assert {:ok, _result} = Config.set(:listing, :sql_hard_limit, 42, source: "cli")
      end)

    assert [lock_query | _rest] = substantive_statements(queries)

    assert lock_query ==
             "SELECT pg_advisory_xact_lock(1297638214, hashtext($1))"
  end

  test "same-subsystem batch and old single-key writer serialize", %{
    task_supervisor: task_supervisor
  } do
    # Catches either public writer bypassing the shared subsystem lock.
    assert_mutate_available!()
    owner = self()
    release_ref = make_ref()

    holder =
      Task.Supervisor.async_nolink(task_supervisor, fn ->
        unboxed(fn ->
          checkpoint = hold_after_advisory_lock(owner, :batch_holder, release_ref)

          mutate(:listing, [{:set, :sql_hard_limit, 111}],
            request_id: "req-batch-holder",
            checkpoint: checkpoint
          )
        end)
      end)

    assert_receive {:config_after_advisory_lock, :batch_holder, holder_pid}, 5_000

    old_writer =
      Task.Supervisor.async_nolink(task_supervisor, fn ->
        unboxed(fn ->
          backend_pid = backend_pid!()
          send(owner, {:old_writer_backend, backend_pid})
          Config.set(:listing, :sql_hard_limit, 222, source: "cli", request_id: "req-old-writer")
        end)
      end)

    assert_receive {:old_writer_backend, backend_pid}, 5_000
    assert_backend_waits_on_lock!(backend_pid)
    send(holder_pid, {:release_config_lock, release_ref})

    assert {:ok, %{changed_count: 1}} = Task.await(holder, 10_000)
    assert {:ok, %{version: 2, changed?: true}} = Task.await(old_writer, 10_000)

    assert unboxed(fn ->
             Repo.one(
               from row in RuntimeConfig,
                 where: row.subsystem == "listing" and row.key == "sql_hard_limit",
                 select: {row.value, row.version}
             )
           end) == {%{"v" => 222}, 2}
  end

  test "different subsystems cross the advisory-lock-held phase", %{
    task_supervisor: task_supervisor
  } do
    # Catches a global config lock that needlessly serializes independent subsystems.
    assert_mutate_available!()
    owner = self()
    listing_release = make_ref()
    s3_release = make_ref()

    listing_task =
      Task.Supervisor.async_nolink(task_supervisor, fn ->
        unboxed(fn ->
          mutate(:listing, [{:set, :sql_hard_limit, 123}],
            checkpoint: hold_after_advisory_lock(owner, :listing, listing_release)
          )
        end)
      end)

    assert_receive {:config_after_advisory_lock, :listing, listing_pid}, 5_000

    s3_task =
      Task.Supervisor.async_nolink(task_supervisor, fn ->
        unboxed(fn ->
          mutate(:s3, [{:set, :clock_skew_ms, 456}],
            checkpoint: hold_after_advisory_lock(owner, :s3, s3_release)
          )
        end)
      end)

    assert_receive {:config_after_advisory_lock, :s3, s3_pid}, 5_000
    send(s3_pid, {:release_config_lock, s3_release})
    send(listing_pid, {:release_config_lock, listing_release})

    assert {:ok, %{changed_count: 1}} = Task.await(s3_task, 10_000)
    assert {:ok, %{changed_count: 1}} = Task.await(listing_task, 10_000)
  end

  test "queued writer validates the patched candidate against the latest locked sibling", %{
    task_supervisor: task_supervisor
  } do
    # Catches a validator fed from a pre-lock snapshot or invoked after the patched row is written.
    assert_mutate_available!()
    seed_batch_fixture_unboxed!()
    owner = self()
    release_ref = make_ref()

    sibling_writer =
      Task.Supervisor.async_nolink(task_supervisor, fn ->
        unboxed(fn ->
          mutate(:batch_fixture, [{:set, :right, 20}],
            schema: ConfigBatchSchema,
            store: ConfigBatchSchema,
            notify: ConfigBatchSchema,
            checkpoint: hold_after_advisory_lock(owner, :sibling_writer, release_ref)
          )
        end)
      end)

    assert_receive {:config_after_advisory_lock, :sibling_writer, sibling_pid}, 5_000

    validating_writer =
      Task.Supervisor.async_nolink(task_supervisor, fn ->
        unboxed(fn ->
          backend_pid = backend_pid!()
          send(owner, {:validating_writer_backend, backend_pid})

          validator = fn candidate ->
            persisted_left =
              Repo.one(
                from row in RuntimeConfig,
                  where: row.subsystem == "batch_fixture" and row.key == "left",
                  select: row.value
              )

            send(owner, {:candidate_validated, candidate, persisted_left})
            :ok
          end

          mutate(:batch_fixture, [{:set, :left, 10}],
            schema: ConfigBatchSchema,
            store: ConfigBatchSchema,
            notify: ConfigBatchSchema,
            validator: validator
          )
        end)
      end)

    assert_receive {:validating_writer_backend, backend_pid}, 5_000
    assert_backend_waits_on_lock!(backend_pid)
    send(sibling_pid, {:release_config_lock, release_ref})

    assert_receive {:candidate_validated, %{left: 10, right: 20}, %{"v" => 1}}, 5_000
    assert {:ok, %{changed_count: 1}} = Task.await(sibling_writer, 10_000)
    assert {:ok, %{changed_count: 1}} = Task.await(validating_writer, 10_000)

    assert unboxed(fn ->
             Repo.all(
               from row in RuntimeConfig,
                 where: row.subsystem == "batch_fixture",
                 order_by: [asc: row.key],
                 select: {row.key, row.value}
             )
           end) == [{"left", %{"v" => 10}}, {"right", %{"v" => 20}}]
  end

  defp mutate(subsystem, operations, extra_opts \\ []) do
    opts =
      [source: "admin_api", request_id: "req-concurrency-default"]
      |> Keyword.merge(extra_opts)

    apply(Config, :mutate_subsystem, [subsystem, operations, opts])
  end

  defp hold_after_advisory_lock(owner, tag, release_ref) do
    fn
      :after_advisory_lock ->
        send(owner, {:config_after_advisory_lock, tag, self()})

        receive do
          {:release_config_lock, ^release_ref} -> :ok
        after
          10_000 -> raise "config advisory-lock checkpoint timed out for #{inspect(tag)}"
        end

      _phase ->
        :ok
    end
  end

  defp capture_current_process_queries(fun) do
    owner = self()
    handler_id = {__MODULE__, :query_capture, make_ref()}
    prefix = Keyword.get(Repo.config(), :telemetry_prefix) || [:maxio, :repo]
    event = prefix ++ [:query]

    :ok =
      :telemetry.attach(
        handler_id,
        event,
        fn _event, _measurements, metadata, test_pid ->
          if self() == test_pid and is_binary(metadata.query) do
            send(test_pid, {:config_sql, handler_id, metadata.query})
          end
        end,
        owner
      )

    try do
      assert {:ok, _result} = fun.()
      collect_queries(handler_id, [])
    after
      :telemetry.detach(handler_id)
    end
  end

  defp collect_queries(handler_id, queries) do
    receive do
      {:config_sql, ^handler_id, query} -> collect_queries(handler_id, [query | queries])
    after
      0 -> Enum.reverse(queries)
    end
  end

  defp normalize_sql(sql) do
    sql
    |> String.trim()
    |> String.replace(~r/\s+/, " ")
  end

  defp substantive_statements(queries) do
    queries
    |> Enum.map(&normalize_sql/1)
    |> Enum.reject(&transaction_control_statement?/1)
  end

  defp transaction_control_statement?(statement) do
    normalized = String.downcase(statement)

    normalized in ["begin", "commit", "rollback"] or
      String.starts_with?(normalized, "savepoint ") or
      String.starts_with?(normalized, "release savepoint ") or
      String.starts_with?(normalized, "rollback to savepoint ")
  end

  defp assert_mutate_available! do
    Code.ensure_loaded!(Config)

    assert function_exported?(Config, :mutate_subsystem, 3),
           "Maxio.Config.mutate_subsystem/3 is required for subsystem coordination"
  end

  defp assert_backend_waits_on_lock!(backend_pid) do
    deadline = System.monotonic_time(:millisecond) + 5_000
    poll_backend_lock!(backend_pid, deadline, nil)
  end

  defp poll_backend_lock!(backend_pid, deadline, last_observed) do
    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        Repo,
        "SELECT wait_event_type, wait_event, state FROM pg_stat_activity WHERE pid = $1",
        [backend_pid]
      )

    observed = List.first(rows)

    cond do
      match?(["Lock", _wait_event, _state], observed) ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk(
          "backend #{backend_pid} did not wait on the config subsystem lock; " <>
            "observed=#{inspect(observed || last_observed)}"
        )

      true ->
        :erlang.yield()
        poll_backend_lock!(backend_pid, deadline, observed || last_observed)
    end
  end

  defp backend_pid! do
    %{rows: [[backend_pid]]} = Ecto.Adapters.SQL.query!(Repo, "SELECT pg_backend_pid()")
    backend_pid
  end

  defp seed_batch_fixture_unboxed! do
    unboxed(fn ->
      insert_runtime!(:left, 1)
      insert_runtime!(:right, 1)
    end)
  end

  defp insert_runtime!(key, value) do
    %RuntimeConfig{}
    |> RuntimeConfig.changeset(%{
      subsystem: "batch_fixture",
      key: Atom.to_string(key),
      value: ConfigBatchSchema.encode_stored(value),
      version: 1,
      apply_mode: "hot",
      source: "cli"
    })
    |> Repo.insert!()
  end

  defp cleanup_unboxed! do
    unboxed(fn ->
      subsystems = ["batch_fixture", "listing", "s3"]
      Repo.delete_all(from audit in RuntimeConfigAudit, where: audit.subsystem in ^subsystems)
      Repo.delete_all(from row in RuntimeConfig, where: row.subsystem in ^subsystems)
    end)
  end

  defp unboxed(fun), do: Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fun)
end
