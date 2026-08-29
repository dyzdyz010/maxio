defmodule Maxio.Config.CoordinatorPostcommitTest do
  use Maxio.DataCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  alias Maxio.Config
  alias Maxio.Config.{RuntimeConfig, RuntimeConfigAudit, Store}

  alias Maxio.Test.{
    ConfigBatchFailureRepo,
    ConfigBatchSchema,
    ConfigPostcommitNotify,
    ConfigPostcommitStore
  }

  @sensitive_terms [
    "POSTCOMMIT-SUBMITTED-VALUE-7391",
    "POSTCOMMIT-PLAINTEXT-S3CR3T",
    "POSTCOMMIT-CIPHERTEXT-S3CR3T",
    "POSTCOMMIT-CALLER-S3CR3T"
  ]
  @unknown_reload_sentinel "POSTCOMMIT-UNKNOWN-MAP-S3CR3T"

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

  test "changed batch commits before one full reload and one checked subsystem broadcast" do
    # Catches callbacks inside the transaction, per-key reload/broadcast, legacy broadcast, and a
    # postcommit retry that manufactures a second version/audit.
    assert {:returned, {:ok, result}} = capture_outcome(fn -> mutate(1_001) end)

    assert [
             {:reload,
              %{
                transaction_open?: false,
                runtime_count: 1,
                audit_count: 1,
                runtime_keys: [{"listing", "sql_hard_limit", 1}]
              }, {:write, :listing, [:sql_hard_limit]}},
             {:checked, {:config_changed, :listing}}
           ] = dependency_events()

    assert %{
             committed?: true,
             changed_count: 1,
             local_reload: :ok,
             broadcast: :ok,
             attention?: false
           } = result

    assert ConfigPostcommitStore.observations().attention_calls == []
    assert ConfigPostcommitStore.observations().reload_calls |> length() == 1
    assert ConfigPostcommitNotify.observations().checked_calls == [{:config_changed, :listing}]
    assert ConfigPostcommitNotify.observations().legacy_calls == []
    assert Store.lookup(:listing, :sql_hard_limit) == {:ok, 1_001}
    assert_committed_once(1_001)
  end

  test "real two-key batch crosses one transaction, advisory lock, reload, and checked broadcast" do
    # Catches transaction/lock/callback orchestration being repeated per key. Repo facade counters
    # observe the real coordinator boundaries; PG rows/audits prove the result is not mock-only.
    assert {:ok, result} = mutate_batch_fixture(11, 22)

    assert %{
             committed?: true,
             changed_count: 2,
             changed_keys: [:left, :right],
             local_reload: :ok,
             broadcast: :ok,
             attention?: false
           } = result

    assert ConfigBatchFailureRepo.observations() == %{
             transactions: 1,
             query_calls: 1,
             advisory_locks: 1
           }

    assert event_kinds(dependency_events()) == [:reload, :checked]
    assert length(ConfigPostcommitStore.observations().reload_calls) == 1
    assert ConfigPostcommitStore.observations().attention_calls == []

    assert ConfigPostcommitNotify.observations() == %{
             checked_calls: [{:config_changed, :batch_fixture}],
             legacy_calls: []
           }

    assert_batch_fixture_committed_once(11, 22)
  end

  for {label, stage} <- [
        {"reload", :reload},
        {"checked broadcast", :broadcast},
        {"attention recorder", :recorder}
      ] do
    test "two-key batch is not retried after #{label} failure" do
      # Catches postcommit recovery re-entering the mutation. Even under each independent failure
      # stage there is one real transaction/lock and exactly two v1 rows/two audits.
      stage = unquote(stage)
      configure_multi_key_failure(stage)

      assert {:returned, {:ok, result}} =
               capture_outcome(fn -> mutate_batch_fixture(33, 44) end)

      assert %{committed?: true, changed_count: 2, attention?: true} = result
      assert Map.take(result, [:local_reload, :broadcast]) == multi_key_postcommit(stage)

      assert ConfigBatchFailureRepo.observations() == %{
               transactions: 1,
               query_calls: 1,
               advisory_locks: 1
             }

      assert event_kinds(dependency_events()) == [:reload, :checked, :attention]
      assert length(ConfigPostcommitStore.observations().reload_calls) == 1
      assert length(ConfigPostcommitStore.observations().attention_calls) == 1

      assert ConfigPostcommitNotify.observations().checked_calls == [
               {:config_changed, :batch_fixture}
             ]

      assert ConfigPostcommitNotify.observations().legacy_calls == []
      assert_batch_fixture_committed_once(33, 44)
    end
  end

  test "secret-bearing unknown reload map is a safe committed attention result" do
    # Catches the broad `is_map(result)` success branch accepting malformed reload returns. The
    # sentinel pressures result, persisted attention status, and structured log redaction together.
    ConfigPostcommitStore.configure(reload: {:return, %{unexpected: @unknown_reload_sentinel}})

    outcome_ref = make_ref()

    log =
      capture_log(fn ->
        send(self(), {outcome_ref, capture_outcome(fn -> mutate(1_051) end)})
      end)

    assert_receive {^outcome_ref, {:returned, {:ok, result}}}

    assert %{
             committed?: true,
             changed_count: 1,
             local_reload: {:error, :reload_failed},
             broadcast: :ok,
             attention?: true
           } = result

    assert event_kinds(dependency_events()) == [:reload, :checked, :attention]

    assert ConfigPostcommitStore.observations().attention_calls == [
             %{
               subsystem: :listing,
               local_reload: {:error, :reload_failed},
               broadcast: :ok
             }
           ]

    assert %{
             postcommit_attention: %{
               subsystem: :listing,
               local_reload: {:error, :reload_failed},
               broadcast: :ok
             }
           } = Store.status()

    assert log =~ "config_attention_record=ok"
    assert log =~ "config_subsystem=listing"
    assert log =~ "reason=reload_failed"

    serialized = inspect(result, limit: :infinity) <> inspect(Store.status()) <> log
    refute serialized =~ @unknown_reload_sentinel
    assert_committed_once(1_051)
  end

  for {label, reload_outcome} <- [
        {"raise", {:raise, "private reload exception"}},
        {"exit", {:exit, {:private_reload_exit, "discard-me"}}},
        {"transport return", {:return, {:error, {:transport, "discard-me"}}}}
      ] do
    test "reload #{label} is a safe committed result and checked broadcast is still attempted" do
      # Catches a postcommit reload failure escaping as a false rollback/5xx or short-circuiting the
      # independent broadcast. All dependency details collapse to the fixed reload_failed atom.
      ConfigPostcommitStore.configure(reload: unquote(Macro.escape(reload_outcome)))

      outcome = capture_outcome(fn -> mutate(1_101) end)
      events = dependency_events()

      assert {:returned, {:ok, result}} = outcome

      assert %{
               committed?: true,
               changed_count: 1,
               local_reload: {:error, :reload_failed},
               broadcast: :ok,
               attention?: true
             } = result

      assert event_kinds(events) == [:reload, :checked, :attention]
      assert ConfigPostcommitNotify.observations().checked_calls == [{:config_changed, :listing}]
      assert ConfigPostcommitNotify.observations().legacy_calls == []

      assert ConfigPostcommitStore.observations().attention_calls == [
               %{
                 subsystem: :listing,
                 local_reload: {:error, :reload_failed},
                 broadcast: :ok
               }
             ]

      assert_committed_once(1_101)
    end
  end

  for {label, broadcast_outcome} <- [
        {"raise", {:raise, "private broadcast exception"}},
        {"exit", {:exit, {:private_broadcast_exit, "discard-me"}}},
        {"transport return", {:return, {:error, {:transport, "discard-me"}}}}
      ] do
    test "checked broadcast #{label} is safe and does not turn a hot commit into restart" do
      # Catches checked transport failure escaping after commit, legacy broadcast swallowing it, or
      # broadcast failure being misreported as a restart requirement despite a successful reload.
      ConfigPostcommitNotify.configure(checked: unquote(Macro.escape(broadcast_outcome)))

      assert {:returned, {:ok, result}} = capture_outcome(fn -> mutate(1_201) end)

      assert %{
               committed?: true,
               changed_count: 1,
               local_reload: :ok,
               broadcast: {:error, :broadcast_failed},
               attention?: true,
               outcomes: %{sql_hard_limit: %{applied: :hot}}
             } = result

      assert event_kinds(dependency_events()) == [:reload, :checked, :attention]
      assert ConfigPostcommitNotify.observations().checked_calls == [{:config_changed, :listing}]
      assert ConfigPostcommitNotify.observations().legacy_calls == []

      assert ConfigPostcommitStore.observations().attention_calls == [
               %{
                 subsystem: :listing,
                 local_reload: :ok,
                 broadcast: {:error, :broadcast_failed}
               }
             ]

      assert Store.lookup(:listing, :sql_hard_limit) == {:ok, 1_201}
      assert_committed_once(1_201)
    end
  end

  test "successful no-op has no callbacks, needs no attention, and remains applied-eligible" do
    # Catches unconditional postcommit work for changed_count=0 and a no-op being mistaken for a
    # restart merely because there was no reload to report.
    insert_runtime!(1_301)
    ConfigPostcommitStore.reset_observations()
    ConfigPostcommitNotify.reset_observations()

    assert {:returned, {:ok, result}} = capture_outcome(fn -> mutate(1_301) end)

    assert %{
             committed?: true,
             changed_count: 0,
             local_reload: :not_needed,
             broadcast: :not_needed,
             attention?: false,
             outcomes: %{
               sql_hard_limit: %{changed?: false, applied: :hot, version: 1}
             }
           } = result

    assert dependency_events() == []
    assert ConfigPostcommitStore.observations().reload_calls == []
    assert ConfigPostcommitStore.observations().attention_calls == []
    assert ConfigPostcommitNotify.observations() == %{checked_calls: [], legacy_calls: []}
    assert Repo.aggregate(RuntimeConfigAudit, :count) == 0
  end

  test "changed multi-subsystem facade reloads once and broadcasts one origin-aware batch event" do
    assert {:ok, result} =
             mutate_many([
               {:s3, [{:set, :clock_skew_ms, 7_001}]},
               {:listing, [{:set, :sql_hard_limit, 7_002}]},
               {:prometheus_metrics, [{:reset, :public}]}
             ])

    assert %{
             committed?: true,
             touched_subsystems: [:listing, :prometheus_metrics, :s3],
             changed_subsystems: [:listing, :s3],
             changed_count: 2,
             changed_paths: [
               {:listing, :sql_hard_limit},
               {:s3, :clock_skew_ms}
             ],
             local_reload: :ok,
             broadcast: :ok,
             attention?: false
           } = result

    assert [reload] = ConfigPostcommitStore.observations().reload_calls
    assert reload.commit.transaction_open? == false

    assert reload.opts[:reason] ==
             {:write_batch,
              [
                {:listing, :sql_hard_limit},
                {:s3, :clock_skew_ms}
              ]}

    assert [event] = ConfigPostcommitNotify.observations().checked_calls

    assert {:config_changed_batch,
            %{
              origin: %{node: node_name, instance: instance},
              epoch: epoch,
              subsystems: [:listing, :s3]
            }} = event

    assert node_name == node()
    assert is_binary(instance) and byte_size(instance) > 0
    assert is_integer(epoch) and epoch > 0
    assert ConfigPostcommitNotify.observations().legacy_calls == []
    assert ConfigPostcommitStore.observations().attention_calls == []
  end

  test "successive changed batches keep one Store instance and strictly increase event epoch" do
    assert {:ok, %{changed_count: 1}} =
             mutate_many([{:listing, [{:set, :sql_hard_limit, 7_401}]}])

    assert {:ok, %{changed_count: 1}} =
             mutate_many([{:listing, [{:set, :sql_hard_limit, 7_402}]}])

    assert [first_event, second_event] = ConfigPostcommitNotify.observations().checked_calls

    assert {:config_changed_batch,
            %{origin: %{instance: instance}, epoch: first_epoch, subsystems: [:listing]}} =
             first_event

    assert {:config_changed_batch,
            %{origin: %{instance: ^instance}, epoch: second_epoch, subsystems: [:listing]}} =
             second_event

    assert second_epoch > first_epoch
    assert event_kinds(dependency_events()) == [:reload, :checked, :reload, :checked]
    assert length(ConfigPostcommitStore.observations().reload_calls) == 2
    assert ConfigPostcommitNotify.observations().legacy_calls == []
  end

  test "batch reload failure remains committed, still broadcasts, and records safe plural attention" do
    ConfigPostcommitStore.configure(reload: {:raise, "BATCH-PRIVATE-RELOAD-DETAIL"})

    assert {:ok, result} =
             mutate_many([
               {:listing, [{:set, :sql_hard_limit, 7_501}]},
               {:s3, [{:set, :clock_skew_ms, 7_502}]}
             ])

    assert %{
             committed?: true,
             changed_count: 2,
             local_reload: {:error, :reload_failed},
             broadcast: :ok,
             attention?: true
           } = result

    assert event_kinds(dependency_events()) == [:reload, :checked, :attention]
    assert [_batch_event] = ConfigPostcommitNotify.observations().checked_calls

    assert ConfigPostcommitStore.observations().attention_calls == [
             %{
               subsystems: [:listing, :s3],
               changed_paths: [
                 {:listing, :sql_hard_limit},
                 {:s3, :clock_skew_ms}
               ],
               local_reload: {:error, :reload_failed},
               broadcast: :ok
             }
           ]

    assert Repo.aggregate(RuntimeConfig, :count) == 2
    assert Repo.aggregate(RuntimeConfigAudit, :count) == 2
    refute inspect(result, limit: :infinity) =~ "BATCH-PRIVATE-RELOAD-DETAIL"
  end

  test "global batch no-op touches subsystems but invokes no postcommit dependency" do
    insert_runtime!(7_101)
    ConfigPostcommitStore.reset_observations()
    ConfigPostcommitNotify.reset_observations()

    assert {:ok, result} =
             mutate_many([
               {:listing, [{:set, :sql_hard_limit, 7_101}]},
               {:prometheus_metrics, [{:reset, :public}]}
             ])

    assert %{
             committed?: true,
             touched_subsystems: [:listing, :prometheus_metrics],
             changed_subsystems: [],
             changed_paths: [],
             changed_count: 0,
             local_reload: :not_needed,
             broadcast: :not_needed,
             attention?: false
           } = result

    assert dependency_events() == []
    assert ConfigPostcommitStore.observations().reload_calls == []
    assert ConfigPostcommitStore.observations().attention_calls == []
    assert ConfigPostcommitNotify.observations() == %{checked_calls: [], legacy_calls: []}
  end

  test "batch broadcast failure stays committed and records only safe path names and statuses" do
    ConfigPostcommitNotify.configure(
      checked: {:return, {:error, {:transport, "BATCH-PRIVATE-TRANSPORT-DETAIL"}}}
    )

    assert {:ok, result} =
             mutate_many([
               {:listing, [{:set, :sql_hard_limit, 7_201}]},
               {:s3, [{:set, :clock_skew_ms, 7_202}]}
             ])

    assert %{
             committed?: true,
             changed_subsystems: [:listing, :s3],
             changed_paths: [
               {:listing, :sql_hard_limit},
               {:s3, :clock_skew_ms}
             ],
             local_reload: :ok,
             broadcast: {:error, :broadcast_failed},
             attention?: true
           } = result

    assert ConfigPostcommitStore.observations().attention_calls == [
             %{
               subsystems: [:listing, :s3],
               changed_paths: [
                 {:listing, :sql_hard_limit},
                 {:s3, :clock_skew_ms}
               ],
               local_reload: :ok,
               broadcast: {:error, :broadcast_failed}
             }
           ]

    refute inspect(result, limit: :infinity) =~ "BATCH-PRIVATE-TRANSPORT-DETAIL"
  end

  test "legacy facade keeps exactly one legacy reload reason and event with no batch event" do
    assert {:ok, %{subsystem: :listing, outcomes: %{sql_hard_limit: _outcome}}} =
             mutate(7_301)

    assert [reload] = ConfigPostcommitStore.observations().reload_calls
    assert reload.opts[:reason] == {:write, :listing, [:sql_hard_limit]}
    assert ConfigPostcommitNotify.observations().checked_calls == [{:config_changed, :listing}]
    assert ConfigPostcommitNotify.observations().legacy_calls == []
  end

  for {label, trigger, recorder_outcome, expected_record} <- [
        {"reload failure then recorder raise", :reload,
         {:raise,
          "POSTCOMMIT-SUBMITTED-VALUE-7391 POSTCOMMIT-PLAINTEXT-S3CR3T " <>
            "POSTCOMMIT-CIPHERTEXT-S3CR3T POSTCOMMIT-CALLER-S3CR3T"}, :recorder_raised},
        {"reload failure then recorder exit", :reload,
         {:exit, {:private, "POSTCOMMIT-PLAINTEXT-S3CR3T"}}, :recorder_exited},
        {"reload failure then recorder unavailable", :reload, {:return, {:error, :unavailable}},
         :recorder_unavailable},
        {"broadcast failure then recorder transport", :broadcast, {:return, {:error, :transport}},
         :recorder_transport_failed},
        {"broadcast failure then secret-bearing recorder transport", :broadcast,
         {:return, {:error, {:transport, "POSTCOMMIT-CIPHERTEXT-S3CR3T"}}},
         :recorder_transport_failed}
      ] do
    test "#{label} cannot replace or disclose the committed result" do
      # Catches the attention recorder as a second point of failure: it is invoked only after a
      # postcommit problem, but its own raise/exit/transport details may never escape or trigger a
      # second mutation.
      trigger = unquote(trigger)
      recorder_outcome = unquote(Macro.escape(recorder_outcome))
      expected_record = unquote(expected_record)

      configure_attention_failure(trigger, recorder_outcome)

      outcome_ref = make_ref()

      log =
        capture_log(fn ->
          send(self(), {outcome_ref, capture_outcome(fn -> mutate(1_401, sensitive_opts()) end)})
        end)

      assert_receive {^outcome_ref, {:returned, {:ok, result}}}

      expected_postcommit = expected_postcommit(trigger)

      assert %{committed?: true, changed_count: 1, attention?: true} = result
      assert Map.take(result, [:local_reload, :broadcast]) == expected_postcommit
      refute Map.has_key?(result, :attention_record)
      assert result.outcomes.sql_hard_limit.applied == :hot

      assert event_kinds(dependency_events()) == [:reload, :checked, :attention]

      assert ConfigPostcommitStore.observations().attention_calls == [
               Map.put(expected_postcommit, :subsystem, :listing)
             ]

      assert_committed_once(1_401)

      assert log =~ "config_attention_record=#{expected_record}"
      assert log =~ "config_subsystem=listing"
      assert log =~ "request_id=req-postcommit-recorder"

      serialized = inspect(result, limit: :infinity, printable_limit: :infinity) <> log
      Enum.each(@sensitive_terms, &refute(serialized =~ &1))
    end
  end

  defp mutate(value, extra_opts \\ []) do
    opts =
      [
        source: "admin_api",
        principal_arn: "arn:aws:iam:::root",
        access_key_id: "AKIA-POSTCOMMIT",
        request_id: "req-postcommit",
        repo: ConfigBatchFailureRepo,
        store: ConfigPostcommitStore,
        notify: ConfigPostcommitNotify
      ]
      |> Keyword.merge(extra_opts)

    Config.mutate_subsystem(:listing, [{:set, :sql_hard_limit, value}], opts)
  end

  defp mutate_many(groups) do
    apply(Config, :mutate_many, [
      groups,
      [
        source: "admin_api",
        principal_arn: "arn:aws:iam:::root",
        access_key_id: "AKIA-POSTCOMMIT-BATCH-S7",
        request_id: "req-postcommit-batch-s7",
        repo: ConfigBatchFailureRepo,
        store: ConfigPostcommitStore,
        notify: ConfigPostcommitNotify
      ]
    ])
  end

  defp mutate_batch_fixture(left, right) do
    Config.mutate_subsystem(
      :batch_fixture,
      [{:set, :left, left}, {:set, :right, right}],
      source: "admin_api",
      principal_arn: "arn:aws:iam:::root",
      access_key_id: "AKIA-POSTCOMMIT-BATCH",
      request_id: "req-postcommit-batch",
      repo: ConfigBatchFailureRepo,
      schema: ConfigBatchSchema,
      store: ConfigPostcommitStore,
      notify: ConfigPostcommitNotify
    )
  end

  defp configure_multi_key_failure(:reload) do
    ConfigPostcommitStore.configure(reload: {:raise, "private multi-key reload failure"})
  end

  defp configure_multi_key_failure(:broadcast) do
    ConfigPostcommitNotify.configure(checked: {:return, {:error, :transport}})
  end

  defp configure_multi_key_failure(:recorder) do
    ConfigPostcommitStore.configure(attention: {:raise, "private multi-key recorder failure"})
    ConfigPostcommitNotify.configure(checked: {:return, {:error, :transport}})
  end

  defp multi_key_postcommit(:reload) do
    %{local_reload: {:error, :reload_failed}, broadcast: :ok}
  end

  defp multi_key_postcommit(stage) when stage in [:broadcast, :recorder] do
    %{local_reload: :ok, broadcast: {:error, :broadcast_failed}}
  end

  defp configure_attention_failure(:reload, recorder_outcome) do
    ConfigPostcommitStore.configure(
      reload: {:return, {:error, {:transport, "private reload detail"}}},
      attention: recorder_outcome
    )
  end

  defp configure_attention_failure(:broadcast, recorder_outcome) do
    ConfigPostcommitStore.configure(attention: recorder_outcome)

    ConfigPostcommitNotify.configure(
      checked: {:return, {:error, {:transport, "private broadcast detail"}}}
    )
  end

  defp expected_postcommit(:reload) do
    %{local_reload: {:error, :reload_failed}, broadcast: :ok}
  end

  defp expected_postcommit(:broadcast) do
    %{local_reload: :ok, broadcast: {:error, :broadcast_failed}}
  end

  defp sensitive_opts do
    [
      request_id: "req-postcommit-recorder",
      submitted_value: "POSTCOMMIT-SUBMITTED-VALUE-7391",
      plaintext: "POSTCOMMIT-PLAINTEXT-S3CR3T",
      ciphertext: "POSTCOMMIT-CIPHERTEXT-S3CR3T",
      caller_secret: "POSTCOMMIT-CALLER-S3CR3T"
    ]
  end

  defp capture_outcome(fun) do
    {:returned, fun.()}
  rescue
    error -> {:raised, error.__struct__}
  catch
    :exit, _reason -> {:exited, :dependency_exit}
    _kind, _reason -> {:caught, :dependency_failure}
  end

  defp dependency_events(events \\ []) do
    receive do
      {:config_postcommit_dependency, :reload, evidence, reason} ->
        dependency_events([{:reload, evidence, reason} | events])

      {:config_postcommit_dependency, :attention, fields} ->
        dependency_events([{:attention, fields} | events])

      {:config_postcommit_dependency, kind, event} when kind in [:checked, :legacy] ->
        dependency_events([{kind, event} | events])
    after
      0 -> Enum.reverse(events)
    end
  end

  defp event_kinds(events), do: Enum.map(events, &elem(&1, 0))

  defp insert_runtime!(value) do
    %RuntimeConfig{}
    |> RuntimeConfig.changeset(%{
      subsystem: "listing",
      key: "sql_hard_limit",
      value: %{"v" => value},
      version: 1,
      apply_mode: "hot",
      source: "cli"
    })
    |> Repo.insert!()
  end

  defp assert_committed_once(value) do
    assert [row] =
             Repo.all(
               from row in RuntimeConfig,
                 where: row.subsystem == "listing" and row.key == "sql_hard_limit"
             )

    assert row.value == %{"v" => value}
    assert row.version == 1

    assert [audit] =
             Repo.all(
               from audit in RuntimeConfigAudit,
                 where: audit.subsystem == "listing" and audit.key == "sql_hard_limit"
             )

    assert audit.operation == "set"
    assert audit.to_version == 1
  end

  defp assert_batch_fixture_committed_once(left, right) do
    assert Repo.all(
             from row in RuntimeConfig,
               where: row.subsystem == "batch_fixture",
               order_by: [asc: row.key],
               select: {row.key, row.value, row.version}
           ) == [
             {"left", %{"v" => left}, 1},
             {"right", %{"v" => right}, 1}
           ]

    assert Repo.all(
             from audit in RuntimeConfigAudit,
               where: audit.subsystem == "batch_fixture",
               order_by: [asc: audit.key],
               select: {audit.key, audit.operation, audit.to_version}
           ) == [
             {"left", "set", 1},
             {"right", "set", 1}
           ]
  end
end
