defmodule Maxio.Config.CoordinatorTest do
  use Maxio.DataCase, async: false

  import Ecto.Query

  alias Maxio.Admin.ConfigKV.Registry
  alias Maxio.Config
  alias Maxio.Config.{RuntimeConfig, RuntimeConfigAudit, Schema, Store}
  alias Maxio.Test.{ConfigBatchFailureRepo, ConfigBatchSchema, ConfigMissingQueryRepo}

  setup do
    ConfigBatchFailureRepo.clear!()
    Store.reset_local!()

    on_exit(fn ->
      ConfigBatchFailureRepo.clear!()
      Store.reset_local!()
    end)

    :ok
  end

  test "set and reset changes commit as one batch with one request id" do
    # Catches per-key transactions: the reset and set must share one commit and audit identity.
    insert_runtime!(:right, 7, version: 2, previous_value: 6)

    assert {:ok, result} =
             mutate(
               [{:set, :left, 10}, {:reset, :right}],
               request_id: "req-one-batch"
             )

    assert result.committed? == true
    assert result.subsystem == :batch_fixture
    assert result.changed_count == 2

    assert runtime_snapshot() == [
             %{key: "left", previous_value: nil, value: %{"v" => 10}, version: 1}
           ]

    assert audit_snapshot() == [
             %{
               from_version: nil,
               key: "left",
               operation: "set",
               request_id: "req-one-batch",
               to_version: 1
             },
             %{
               from_version: 2,
               key: "right",
               operation: "reset",
               request_id: "req-one-batch",
               to_version: 3
             }
           ]
  end

  test "a later invalid scalar prevents every runtime and audit write" do
    # Catches a coordinator that persists the first typed operation before casting the rest.
    assert {:error, {:invalid_config_value, :batch_fixture, :right, reason}} =
             mutate([{:set, :left, 10}, {:set, :right, "not-an-integer"}])

    assert reason =~ "integer"
    assert runtime_snapshot() == []
    assert audit_snapshot() == []
  end

  test "repo without query boundary fails before any runtime read or mutation" do
    # Catches the test-build bypass that silently treats a missing advisory-lock API as success.
    {outcome, queries} =
      capture_current_process_queries(fn ->
        try do
          {:returned,
           apply(Config, :mutate_subsystem, [
             :listing,
             [{:set, :sql_hard_limit, 321}],
             [
               source: "cli",
               request_id: "req-missing-query-boundary",
               repo: ConfigMissingQueryRepo,
               store: ConfigBatchSchema,
               notify: ConfigBatchSchema
             ]
           ])}
        rescue
          error in ArgumentError -> {:raised, ArgumentError, Exception.message(error)}
        end
      end)

    evidence = %{
      outcome: outcome,
      explicit_query_boundary_failure?:
        match?({:raised, ArgumentError, _message}, outcome) and
          String.contains?(elem(outcome, 2), "query!"),
      runtime_queries: Enum.filter(queries, &String.contains?(&1, "runtime_configs")),
      runtime_count:
        Repo.aggregate(
          from(row in RuntimeConfig,
            where: row.subsystem == "listing" and row.key == "sql_hard_limit"
          ),
          :count
        ),
      audit_count:
        Repo.aggregate(
          from(audit in RuntimeConfigAudit,
            where: audit.subsystem == "listing" and audit.key == "sql_hard_limit"
          ),
          :count
        )
    }

    assert %{
             explicit_query_boundary_failure?: true,
             runtime_queries: [],
             runtime_count: 0,
             audit_count: 0
           } = evidence
  end

  test "candidate rejection occurs before mutation and rolls the whole batch back" do
    # Catches candidate validation after persistence or outside the transaction.
    validator = fn candidate ->
      assert candidate == %{left: 10, right: 20}
      {:error, {:invalid_config_candidate, :fixture_rejected}}
    end

    assert {:error, {:invalid_config_candidate, :fixture_rejected}} =
             mutate([{:set, :left, 10}, {:set, :right, 20}], validator: validator)

    assert runtime_snapshot() == []
    assert audit_snapshot() == []
  end

  test "a later runtime insert failure rolls back earlier inserts" do
    # Catches independent insert commits or exception handling that leaves the first key behind.
    ConfigBatchFailureRepo.arm!(:runtime_insert, :right)

    assert {:error, {:forced_config_batch_failure, :runtime_insert, "right"}} =
             mutate([{:set, :left, 10}, {:set, :right, 20}])

    assert runtime_snapshot() == []
    assert audit_snapshot() == []
  end

  test "a later runtime update failure restores every prior row and writes no audit" do
    # Catches an update path that is not enclosed by the same transaction as its sibling update.
    insert_runtime!(:left, 1, version: 3, previous_value: 0)
    insert_runtime!(:right, 2, version: 4, previous_value: 1)
    before = runtime_snapshot()
    ConfigBatchFailureRepo.arm!(:runtime_update, :right)

    assert {:error, {:forced_config_batch_failure, :runtime_update, "right"}} =
             mutate([{:set, :left, 11}, {:set, :right, 22}])

    assert runtime_snapshot() == before
    assert audit_snapshot() == []
  end

  test "a later runtime delete failure restores every prior row and writes no audit" do
    # Catches reset implemented as per-key delete transactions.
    insert_runtime!(:left, 1, version: 3, previous_value: 0)
    insert_runtime!(:right, 2, version: 4, previous_value: 1)
    before = runtime_snapshot()
    ConfigBatchFailureRepo.arm!(:runtime_delete, :right)

    assert {:error, {:forced_config_batch_failure, :runtime_delete, "right"}} =
             mutate([{:reset, :left}, {:reset, :right}])

    assert runtime_snapshot() == before
    assert audit_snapshot() == []
  end

  test "a later audit failure rolls runtime rows and earlier audits back together" do
    # Catches the MinIO-style split where values commit before history persistence finishes.
    ConfigBatchFailureRepo.arm!(:audit_insert, :right)

    assert {:error, {:forced_config_batch_failure, :audit_insert, "right"}} =
             mutate([{:set, :left, 10}, {:set, :right, 20}])

    assert runtime_snapshot() == []
    assert audit_snapshot() == []
  end

  test "setting the exact current typed override is a no-op" do
    # Catches unconditional version increments and spurious audit rows for equal values.
    insert_runtime!(:left, 10, version: 4, previous_value: 9)

    assert {:ok, %{committed?: true, changed_count: 0}} = mutate([{:set, :left, 10}])

    assert runtime_snapshot() == [
             %{key: "left", previous_value: %{"v" => 9}, value: %{"v" => 10}, version: 4}
           ]

    assert audit_snapshot() == []
  end

  test "resetting an absent legal key is a no-op" do
    # Catches a reset that manufactures an audit/version for a row that never existed.
    assert {:ok, %{committed?: true, changed_count: 0}} = mutate([{:reset, :right}])
    assert runtime_snapshot() == []
    assert audit_snapshot() == []
  end

  test "reset closes the old version incarnation and a later set restarts at one" do
    # Catches treating row version as a global monotonic revision across deletion/recreation.
    insert_runtime!(:left, 30, version: 3, previous_value: 20)

    assert {:ok, %{changed_count: 1}} =
             mutate([{:reset, :left}], request_id: "req-reset-incarnation")

    assert runtime_snapshot() == []

    assert audit_snapshot() == [
             %{
               from_version: 3,
               key: "left",
               operation: "reset",
               request_id: "req-reset-incarnation",
               to_version: 4
             }
           ]

    assert {:ok, %{changed_count: 1}} =
             mutate([{:set, :left, 40}], request_id: "req-new-incarnation")

    assert [%{key: "left", value: %{"v" => 40}, version: 1}] =
             Enum.map(runtime_snapshot(), &Map.take(&1, [:key, :value, :version]))

    assert Enum.map(audit_snapshot(), &Map.take(&1, [:operation, :to_version, :request_id])) == [
             %{
               operation: "reset",
               request_id: "req-reset-incarnation",
               to_version: 4
             },
             %{
               operation: "set",
               request_id: "req-new-incarnation",
               to_version: 1
             }
           ]
  end

  test "synthetic coordinator keys never enter the production schema or wire registry" do
    # Catches a test fixture accidentally becoming a user-visible or production-writable setting.
    refute Map.has_key?(Schema.entries(), {:batch_fixture, :left})
    refute Map.has_key?(Schema.entries(), {:batch_fixture, :right})

    refute Enum.any?(Registry.entries(), fn entry ->
             entry.core_subsystem == :batch_fixture
           end)
  end

  defp mutate(operations, extra_opts \\ []) do
    opts =
      [
        source: "admin_api",
        principal_arn: "arn:aws:iam:::root",
        access_key_id: "AKIA-BATCH",
        request_id: "req-batch-default",
        repo: ConfigBatchFailureRepo,
        schema: ConfigBatchSchema,
        store: ConfigBatchSchema,
        notify: ConfigBatchSchema
      ]
      |> Keyword.merge(extra_opts)

    apply(Config, :mutate_subsystem, [:batch_fixture, operations, opts])
  end

  defp insert_runtime!(key, value, opts) do
    previous_value = Keyword.get(opts, :previous_value)

    %RuntimeConfig{}
    |> RuntimeConfig.changeset(%{
      subsystem: "batch_fixture",
      key: Atom.to_string(key),
      value: ConfigBatchSchema.encode_stored(value),
      previous_value: previous_value && ConfigBatchSchema.encode_stored(previous_value),
      version: Keyword.fetch!(opts, :version),
      apply_mode: "hot",
      source: "cli"
    })
    |> Repo.insert!()
  end

  defp runtime_snapshot do
    Repo.all(
      from row in RuntimeConfig,
        where: row.subsystem == "batch_fixture",
        order_by: [asc: row.key],
        select: %{
          key: row.key,
          previous_value: row.previous_value,
          value: row.value,
          version: row.version
        }
    )
  end

  defp audit_snapshot do
    Repo.all(
      from audit in RuntimeConfigAudit,
        where: audit.subsystem == "batch_fixture",
        order_by: [asc: audit.inserted_at, asc: audit.key],
        select: %{
          from_version: audit.from_version,
          key: audit.key,
          operation: audit.operation,
          request_id: audit.request_id,
          to_version: audit.to_version
        }
    )
  end

  defp capture_current_process_queries(fun) do
    owner = self()
    handler_id = {__MODULE__, :query_capture, make_ref()}
    prefix = Keyword.get(Repo.config(), :telemetry_prefix) || [:maxio, :repo]

    :ok =
      :telemetry.attach(
        handler_id,
        prefix ++ [:query],
        fn _event, _measurements, metadata, test_pid ->
          if self() == test_pid and is_binary(metadata.query) do
            send(test_pid, {:config_sql, handler_id, metadata.query})
          end
        end,
        owner
      )

    try do
      outcome = fun.()
      {outcome, collect_queries(handler_id, [])}
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
end
