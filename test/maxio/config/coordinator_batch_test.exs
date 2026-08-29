defmodule Maxio.Config.CoordinatorBatchTest do
  use Maxio.DataCase, async: false

  import Ecto.Query

  alias Maxio.Config
  alias Maxio.Config.{Coordinator, CorruptValueError, RuntimeConfig, RuntimeConfigAudit, Store}

  alias Maxio.Test.{
    ConfigBatchFailureRepo,
    ConfigBatchSchema,
    ConfigPostcommitNotify,
    ConfigPostcommitStore
  }

  @paths [
    {:listing, :sql_hard_limit},
    {:prometheus_metrics, :public},
    {:s3, :clock_skew_ms}
  ]

  setup do
    ConfigBatchFailureRepo.clear!()
    Store.reset_local!()
    start_supervised!({ConfigPostcommitStore, owner: self()})
    start_supervised!({ConfigPostcommitNotify, owner: self()})

    on_exit(fn ->
      ConfigBatchFailureRepo.clear!()
      Store.reset_local!()
    end)

    :ok
  end

  test "authoritative snapshot reads only explicit paths in one statement with source and version" do
    insert_runtime!(:listing, :sql_hard_limit, 321, version: 4, source: "admin_api")
    insert_orphan!("archive_orphan", "private_value")
    insert_orphan!("listing", "clock_skew_ms")
    insert_orphan!("s3", "sql_hard_limit")

    {{:ok, snapshot}, queries} =
      capture_queries(fn ->
        apply(Config, :authoritative_snapshot, [Enum.reverse(@paths), [repo: Repo]])
      end)

    assert [snapshot_query] = Enum.filter(queries, &runtime_select?/1)

    assert snapshot_query.params == [
             "listing",
             "sql_hard_limit",
             "prometheus_metrics",
             "public",
             "s3",
             "clock_skew_ms"
           ]

    assert snapshot_query.num_rows == 1
    assert Map.keys(snapshot) |> Enum.sort() == @paths

    assert snapshot[{:listing, :sql_hard_limit}] == %{
             value: 321,
             source: :runtime,
             version: 4
           }

    assert snapshot[{:prometheus_metrics, :public}] == %{
             value: false,
             source: :fallback,
             version: nil
           }

    assert snapshot[{:s3, :clock_skew_ms}] == %{
             value: 900_000,
             source: :fallback,
             version: nil
           }

    refute Map.has_key?(snapshot, {:archive_orphan, :private_value})
    refute Map.has_key?(snapshot, {:listing, :clock_skew_ms})
    refute Map.has_key?(snapshot, {:s3, :sql_hard_limit})
  end

  test "authoritative snapshot rejects non-static paths and fails closed on corrupt registered data" do
    assert {:error, _reason} =
             apply(Config, :authoritative_snapshot, [[{"s3", :clock_skew_ms}], [repo: Repo]])

    Repo.insert!(%RuntimeConfig{
      subsystem: "s3",
      key: "clock_skew_ms",
      value: %{"v" => "CORRUPT-SNAPSHOT-VALUE"},
      version: 1,
      apply_mode: "hot",
      source: "admin_api"
    })

    assert_raise CorruptValueError, fn ->
      apply(Config, :authoritative_snapshot, [[{:s3, :clock_skew_ms}], [repo: Repo]])
    end
  end

  test "batch acquires every byte-sorted advisory lock before the first row read" do
    owner = self()

    checkpoint = fn phase ->
      send(owner, {:batch_checkpoint, phase})
      :ok
    end

    {{:ok, _result}, queries} =
      capture_queries(fn ->
        mutate_many(
          [
            {:s3, [{:set, :clock_skew_ms, 1}]},
            {:listing, [{:set, :sql_hard_limit, 2}]},
            {:prometheus_metrics, [{:set, :public, true}]}
          ],
          checkpoint: checkpoint
        )
      end)

    assert drain_checkpoints() == [
             {:after_advisory_lock, :listing},
             {:after_advisory_lock, :prometheus_metrics},
             {:after_advisory_lock, :s3},
             :before_first_row_read
           ]

    statements = substantive_statements(queries)
    first_read = Enum.find_index(statements, &runtime_select?/1)
    locks = Enum.take(statements, first_read)

    assert Enum.map(locks, & &1.params) == [["listing"], ["prometheus_metrics"], ["s3"]]
    assert Enum.all?(locks, &String.contains?(&1.query, "pg_advisory_xact_lock"))
  end

  test "a last-subsystem validator rejection rolls every subsystem back before writes" do
    seed_three_overrides!()
    before = database_snapshot()
    owner = self()

    validators = %{
      listing: fn candidate ->
        send(owner, {:validated, :listing, candidate})
        :ok
      end,
      prometheus_metrics: fn candidate ->
        send(owner, {:validated, :prometheus_metrics, candidate})
        :ok
      end,
      s3: fn candidate ->
        assert database_snapshot() == before
        send(owner, {:validated, :s3, candidate})
        {:error, {:invalid_config_candidate, :s3_rejected}}
      end
    }

    assert {:error, {:invalid_config_candidate, :s3_rejected}} =
             mutate_many(changing_groups(), validators: validators)

    assert_receive {:validated, :listing, %{sql_hard_limit: 101}}
    assert_receive {:validated, :prometheus_metrics, %{public: true}}
    assert_receive {:validated, :s3, %{clock_skew_ms: 303}}
    refute_receive {:validated, _, _}
    assert database_snapshot() == before
  end

  for stage <- [:runtime_insert, :audit_insert] do
    test "a late #{stage} failure rolls back rows, versions, and audits across subsystems" do
      stage = unquote(stage)
      insert_runtime!(:listing, :sql_hard_limit, 11, version: 2)
      insert_runtime!(:prometheus_metrics, :public, false, version: 3)
      before = database_snapshot()
      ConfigBatchFailureRepo.arm!(stage, :clock_skew_ms)

      assert {:error, {:forced_config_batch_failure, ^stage, "clock_skew_ms"}} =
               mutate_many(changing_groups())

      assert database_snapshot() == before
    end
  end

  test "explicit fallback is a v1 set while omitted reset and identical operations remain no-ops" do
    insert_runtime!(:listing, :sql_hard_limit, 77, version: 5)
    insert_orphan!("archive_orphan", "private_value")

    assert {:ok, result} =
             mutate_many(
               [
                 {:listing, [{:reset, :sql_hard_limit}]},
                 {:prometheus_metrics, [{:reset, :public}]},
                 {:s3, [{:set, :clock_skew_ms, 900_000}]}
               ],
               request_id: "req-batch-semantics"
             )

    assert %{
             committed?: true,
             touched_subsystems: [:listing, :prometheus_metrics, :s3],
             changed_subsystems: [:listing, :s3],
             changed_count: 2,
             changed_paths: [
               {:listing, :sql_hard_limit},
               {:s3, :clock_skew_ms}
             ]
           } = result

    changed_reset = result.outcomes[{:listing, :sql_hard_limit}]
    no_op_reset = result.outcomes[{:prometheus_metrics, :public}]
    changed_set = result.outcomes[{:s3, :clock_skew_ms}]

    assert changed_reset == %{
             operation: :reset,
             changed?: true,
             version: nil,
             applied: :hot
           }

    assert no_op_reset.changed? == false
    assert changed_set.version == 1
    refute Map.has_key?(changed_reset, :value)
    refute Map.has_key?(no_op_reset, :value)
    refute Map.has_key?(changed_set, :value)

    assert runtime_rows() == [
             {"archive_orphan", "private_value", %{"v" => "ORPHAN-MUST-STAY"}, 9},
             {"s3", "clock_skew_ms", %{"v" => 900_000}, 1}
           ]

    assert Enum.map(audit_rows(), fn audit ->
             {audit.subsystem, audit.key, audit.operation, audit.source, audit.principal_arn,
              audit.access_key_id, audit.request_id, audit.from_version, audit.to_version}
           end) == [
             {"listing", "sql_hard_limit", "reset", "admin_api", "arn:test:batch",
              "AKIA-BATCH-S7", "req-batch-semantics", 5, 6},
             {"s3", "clock_skew_ms", "set", "admin_api", "arn:test:batch", "AKIA-BATCH-S7",
              "req-batch-semantics", nil, 1}
           ]
  end

  test "batch options are path keyed, validators are subsystem scoped, and source is a string" do
    insert_runtime!(:listing, :sql_hard_limit, 10, version: 2)
    insert_runtime!(:s3, :clock_skew_ms, 20, version: 3)
    owner = self()

    assert {:error, {:invalid_expected_versions, _}} =
             mutate_many(
               [
                 {:listing, [{:set, :sql_hard_limit, 11}]},
                 {:s3, [{:set, :clock_skew_ms, 21}]}
               ],
               expected_versions: %{sql_hard_limit: 2, clock_skew_ms: 3}
             )

    validators = %{
      listing: fn candidate ->
        send(owner, {:candidate, :listing, candidate})
        :ok
      end,
      s3: fn candidate ->
        send(owner, {:candidate, :s3, candidate})
        :ok
      end
    }

    assert {:ok, _result} =
             mutate_many(
               [
                 {:s3, [{:set, :clock_skew_ms, 21}]},
                 {:listing, [{:set, :sql_hard_limit, 11}]}
               ],
               expected_versions: %{
                 {:listing, :sql_hard_limit} => 2,
                 {:s3, :clock_skew_ms} => 3
               },
               validators: validators
             )

    assert_receive {:candidate, :listing, %{sql_hard_limit: 11}}
    assert_receive {:candidate, :s3, %{clock_skew_ms: 21}}
    refute_receive {:candidate, _, _}

    assert {:error, {:invalid_config_source, _}} =
             mutate_many([{:listing, [{:set, :sql_hard_limit, 12}]}], source: :admin_api)

    assert {:error, {:invalid_config_value, :listing, :sql_hard_limit, _reason}} =
             mutate_many([{:listing, [{:set, :sql_hard_limit, "12"}]}])

    assert {:error, _reason} =
             mutate_many(
               [{:listing, [{:set, :sql_hard_limit, 12}]}],
               validators: %{listing: :not_a_function}
             )
  end

  test "direct coordinator and Config facade keep same-name paths isolated" do
    opts = [
      source: "admin_api",
      request_id: "req-direct-coordinator",
      expected_versions: %{
        {:batch_alpha, :shared} => nil,
        {:batch_omega, :shared} => nil
      },
      repo: ConfigBatchFailureRepo,
      schema: ConfigBatchSchema,
      store: ConfigPostcommitStore,
      notify: ConfigPostcommitNotify
    ]

    assert {:ok, direct} =
             apply(Coordinator, :mutate_many, [
               [
                 {:batch_omega, [{:set, :shared, 222}]},
                 {:batch_alpha, [{:set, :shared, 111}]}
               ],
               opts
             ])

    assert direct.changed_paths == [{:batch_alpha, :shared}, {:batch_omega, :shared}]
    assert direct.outcomes[{:batch_alpha, :shared}].version == 1
    assert direct.outcomes[{:batch_omega, :shared}].version == 1
    refute Map.has_key?(direct.outcomes[{:batch_alpha, :shared}], :value)
    refute Map.has_key?(direct.outcomes[{:batch_omega, :shared}], :value)

    assert {:ok, facade} =
             apply(Config, :mutate_many, [
               [
                 {:batch_alpha, [{:set, :shared, 333}]},
                 {:batch_omega, [{:set, :shared, 444}]}
               ],
               Keyword.put(opts, :expected_versions, %{
                 {:batch_alpha, :shared} => 1,
                 {:batch_omega, :shared} => 1
               })
             ])

    assert facade.outcomes[{:batch_alpha, :shared}].version == 2
    assert facade.outcomes[{:batch_omega, :shared}].version == 2
    refute Map.has_key?(facade.outcomes[{:batch_alpha, :shared}], :value)
    refute Map.has_key?(facade.outcomes[{:batch_omega, :shared}], :value)

    assert runtime_rows() == [
             {"batch_alpha", "shared", %{"v" => 333}, 2},
             {"batch_omega", "shared", %{"v" => 444}, 2}
           ]
  end

  test "malformed batch options fail before a transaction and untouched validators are rejected" do
    cases = [
      [expected_versions: %{sql_hard_limit: nil}],
      [expected_versions: %{{:listing, :sql_hard_limit} => -1}],
      [expected_versions: %{{:listing, :unregistered_sibling} => nil}],
      [expected_versions: %{{:s3, :clock_skew_ms} => nil}],
      [validators: %{listing: :not_a_function}],
      [validators: %{s3: fn _candidate -> :ok end}],
      [source: :admin_api]
    ]

    for extra_opts <- cases do
      ConfigBatchFailureRepo.clear!()

      assert {:error, _reason} =
               mutate_many([{:listing, [{:set, :sql_hard_limit, 12}]}], extra_opts)

      assert ConfigBatchFailureRepo.observations().transactions == 0
      assert runtime_rows() == []
      assert audit_rows() == []
    end
  end

  test "unknown subsystem with an empty operation group fails before transaction or advisory lock" do
    result = mutate_many([{:batch_absent, []}])
    observations = ConfigBatchFailureRepo.observations()

    assert observations == %{transactions: 0, query_calls: 0, advisory_locks: 0}
    assert {:error, {:unknown_config_subsystem, :batch_absent}} = result
    assert runtime_rows() == []
    assert audit_rows() == []
  end

  test "batch expected versions accept registered siblings and check their locked snapshot" do
    accepted =
      mutate_many(
        [{:batch_fixture, [{:set, :left, 10}]}],
        schema: ConfigBatchSchema,
        expected_versions: %{{:batch_fixture, :right} => nil},
        request_id: "req-batch-sibling-accepted"
      )

    accepted_observations = ConfigBatchFailureRepo.observations()

    insert_runtime!(:batch_fixture, :right, 7, version: 3)
    before_conflict = database_snapshot()
    ConfigBatchFailureRepo.clear!()

    conflict =
      mutate_many(
        [{:batch_fixture, [{:set, :left, 11}]}],
        schema: ConfigBatchSchema,
        expected_versions: %{{:batch_fixture, :right} => nil},
        request_id: "req-batch-sibling-conflict"
      )

    conflict_observations = ConfigBatchFailureRepo.observations()
    after_conflict = database_snapshot()

    assert {:ok,
            %{
              touched_subsystems: [:batch_fixture],
              changed_paths: [{:batch_fixture, :left}],
              outcomes: %{{:batch_fixture, :left} => %{changed?: true, version: 1}}
            }} = accepted

    assert accepted_observations.transactions == 1
    assert accepted_observations.advisory_locks == 1
    assert conflict == {:error, :config_version_conflict}
    assert conflict_observations.transactions == 1
    assert conflict_observations.advisory_locks == 1
    assert after_conflict == before_conflict
  end

  test "one stale path version conflicts the whole batch with zero writes" do
    insert_runtime!(:listing, :sql_hard_limit, 10, version: 2)
    insert_runtime!(:s3, :clock_skew_ms, 20, version: 3)
    before = database_snapshot()

    assert {:error, :config_version_conflict} =
             mutate_many(
               [
                 {:listing, [{:set, :sql_hard_limit, 11}]},
                 {:s3, [{:set, :clock_skew_ms, 21}]}
               ],
               expected_versions: %{
                 {:listing, :sql_hard_limit} => 1,
                 {:s3, :clock_skew_ms} => 3
               }
             )

    assert ConfigBatchFailureRepo.observations().transactions == 1
    assert database_snapshot() == before
  end

  defp mutate_many(groups, extra_opts \\ []) do
    opts =
      [
        source: "admin_api",
        principal_arn: "arn:test:batch",
        access_key_id: "AKIA-BATCH-S7",
        request_id: "req-batch-s7",
        repo: ConfigBatchFailureRepo,
        store: ConfigPostcommitStore,
        notify: ConfigPostcommitNotify
      ]
      |> Keyword.merge(extra_opts)

    apply(Config, :mutate_many, [groups, opts])
  end

  defp changing_groups do
    [
      {:listing, [{:set, :sql_hard_limit, 101}]},
      {:prometheus_metrics, [{:set, :public, true}]},
      {:s3, [{:set, :clock_skew_ms, 303}]}
    ]
  end

  defp seed_three_overrides! do
    insert_runtime!(:listing, :sql_hard_limit, 10, version: 2)
    insert_runtime!(:prometheus_metrics, :public, false, version: 3)
    insert_runtime!(:s3, :clock_skew_ms, 30, version: 4)
  end

  defp insert_runtime!(subsystem, key, value, opts) do
    Repo.insert!(%RuntimeConfig{
      subsystem: Atom.to_string(subsystem),
      key: Atom.to_string(key),
      value: %{"v" => value},
      previous_value: Keyword.get(opts, :previous_value),
      version: Keyword.fetch!(opts, :version),
      apply_mode: "hot",
      source: Keyword.get(opts, :source, "cli")
    })
  end

  defp insert_orphan!(subsystem, key) do
    Repo.insert!(%RuntimeConfig{
      subsystem: subsystem,
      key: key,
      value: %{"v" => "ORPHAN-MUST-STAY"},
      version: 9,
      apply_mode: "hot",
      source: "system"
    })
  end

  defp database_snapshot, do: {runtime_rows(), audit_rows()}

  defp runtime_rows do
    Repo.all(
      from row in RuntimeConfig,
        order_by: [asc: row.subsystem, asc: row.key],
        select: {row.subsystem, row.key, row.value, row.version}
    )
  end

  defp audit_rows do
    Repo.all(
      from audit in RuntimeConfigAudit,
        order_by: [asc: audit.subsystem, asc: audit.key, asc: audit.inserted_at]
    )
  end

  defp capture_queries(fun) do
    owner = self()
    id = {__MODULE__, make_ref()}
    prefix = Keyword.get(Repo.config(), :telemetry_prefix) || [:maxio, :repo]

    :ok =
      :telemetry.attach(
        id,
        prefix ++ [:query],
        fn _event, _measurements, metadata, pid ->
          if self() == pid and is_binary(metadata.query) do
            send(pid, {
              :batch_sql,
              id,
              metadata.query,
              Map.get(metadata, :params, []),
              query_result_num_rows(Map.get(metadata, :result, :missing))
            })
          end
        end,
        owner
      )

    try do
      result = fun.()
      {result, collect_queries(id, [])}
    after
      :telemetry.detach(id)
    end
  end

  defp collect_queries(id, queries) do
    receive do
      {:batch_sql, ^id, query, params, num_rows} ->
        collect_queries(id, [
          %{query: normalize_sql(query), params: params, num_rows: num_rows} | queries
        ])
    after
      0 -> Enum.reverse(queries)
    end
  end

  defp drain_checkpoints(phases \\ []) do
    receive do
      {:batch_checkpoint, phase} -> drain_checkpoints([phase | phases])
    after
      0 -> Enum.reverse(phases)
    end
  end

  defp normalize_sql(sql), do: sql |> String.trim() |> String.replace(~r/\s+/, " ")

  defp substantive_statements(queries) do
    Enum.reject(queries, fn %{query: query} ->
      String.downcase(query) in ["begin", "commit", "rollback"]
    end)
  end

  defp runtime_select?(%{query: query}) do
    normalized = String.downcase(query)
    String.starts_with?(normalized, "select") and String.contains?(normalized, "runtime_configs")
  end

  defp query_result_num_rows({:ok, %{num_rows: num_rows}}) when is_integer(num_rows), do: num_rows
  defp query_result_num_rows(%{num_rows: num_rows}) when is_integer(num_rows), do: num_rows
  defp query_result_num_rows(_missing_or_unknown), do: :missing
end
