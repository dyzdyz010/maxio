defmodule Maxio.Config.StoreBatchEventTest do
  use Maxio.DataCase, async: false

  alias Maxio.Cluster.Notify
  alias Maxio.Config
  alias Maxio.Config.{RuntimeConfig, Store}
  alias Maxio.Test.ConfigPostcommitStore

  setup do
    Store.reset_local!()
    start_supervised!({ConfigPostcommitStore, owner: self()})

    on_exit(fn -> Store.reset_local!() end)
    :ok
  end

  test "two-tuple subsystem event performs exactly one full authoritative load" do
    # Catches the new batch event falling through handle_info/2 or being implemented as a partial
    # subsystem read that can erase evidence of an unrelated dropped broadcast.
    insert_runtime!(2_001)
    pid = start_store(:config_store_two_tuple_event)

    ConfigPostcommitStore.reset_observations()
    send(pid, {:config_changed, :listing})
    _ = :sys.get_state(pid)

    assert ConfigPostcommitStore.observations().repo_calls == %{one: 1, all: 1}
    assert Store.lookup(:listing, :sql_hard_limit) == {:ok, 2_001}
    assert Store.meta().last_reload_reason == {:broadcast, :listing}
  end

  test "legacy three-tuple event remains compatible and still performs one full load" do
    # Catches migration cleanup removing the old event before every sender has moved to the batch
    # event, or regressing it back to a partial load.
    insert_runtime!(2_101)
    pid = start_store(:config_store_legacy_three_tuple_event)

    ConfigPostcommitStore.reset_observations()
    send(pid, {:config_changed, :listing, :sql_hard_limit})
    _ = :sys.get_state(pid)

    assert ConfigPostcommitStore.observations().repo_calls == %{one: 1, all: 1}
    assert Store.lookup(:listing, :sql_hard_limit) == {:ok, 2_101}
    assert Store.meta().last_reload_reason == {:broadcast, :listing, :sql_hard_limit}
  end

  test "attention status keeps only the latest safe postcommit record" do
    # Catches the first unsafe record being copied into status. It is inspected before a later
    # record can overwrite it, then the second write independently proves bounded latest-only state.
    first = %{
      subsystem: :listing,
      local_reload: {:error, {:transport, "ATTENTION-RAW-RELOAD-MUST-NOT-PERSIST"}},
      broadcast: {:error, {:transport, "ATTENTION-RAW-BROADCAST-MUST-NOT-PERSIST"}},
      value: "ATTENTION-RAW-VALUE-MUST-NOT-PERSIST",
      reason: {:transport, "ATTENTION-RAW-REASON-MUST-NOT-PERSIST"}
    }

    second = %{
      subsystem: :s3,
      local_reload: :ok,
      broadcast: {:error, :broadcast_failed}
    }

    assert {:returned, :ok} =
             capture_outcome(fn -> apply(Store, :note_postcommit_attention, [first]) end)

    first_status = Store.status()
    first_attention = first_status.postcommit_attention

    assert first_attention == %{
             subsystem: :listing,
             local_reload: {:error, :reload_failed},
             broadcast: {:error, :broadcast_failed}
           }

    first_serialized = inspect(first_attention, limit: :infinity)
    refute first_serialized =~ "ATTENTION-RAW-RELOAD-MUST-NOT-PERSIST"
    refute first_serialized =~ "ATTENTION-RAW-BROADCAST-MUST-NOT-PERSIST"
    refute first_serialized =~ "ATTENTION-RAW-VALUE-MUST-NOT-PERSIST"
    refute first_serialized =~ "ATTENTION-RAW-REASON-MUST-NOT-PERSIST"

    assert :ok = apply(Store, :note_postcommit_attention, [second])

    status = Store.status()
    attention = apply(Map, :fetch!, [status, :postcommit_attention])

    assert attention == %{
             subsystem: :s3,
             local_reload: :ok,
             broadcast: {:error, :broadcast_failed}
           }

    refute is_list(attention)

    serialized = inspect(attention, limit: :infinity)
    refute serialized =~ "ATTENTION-RAW-RELOAD-MUST-NOT-PERSIST"
    refute serialized =~ "ATTENTION-RAW-BROADCAST-MUST-NOT-PERSIST"
    refute serialized =~ "ATTENTION-RAW-VALUE-MUST-NOT-PERSIST"
    refute serialized =~ "ATTENTION-RAW-REASON-MUST-NOT-PERSIST"
  end

  test "real PubSub self-loop does not reload after the synchronous batch reload" do
    assert is_pid(Process.whereis(Maxio.PubSub))
    pid = start_store(:config_store_batch_self_loop, subscribe: true, repo: Repo)
    Phoenix.PubSub.subscribe(Maxio.PubSub, Notify.topic())

    {{result, event}, query_count} =
      count_reload_queries([self(), pid], fn ->
        result =
          apply(Config, :mutate_many, [
            [
              {:listing, [{:set, :sql_hard_limit, 8_001}]},
              {:s3, [{:set, :clock_skew_ms, 8_002}]}
            ],
            [source: "admin_api", request_id: "req-real-pubsub-self-loop"]
          ])

        assert_receive {:config_changed_batch, _payload} = event
        _ = :sys.get_state(pid)
        {result, event}
      end)

    assert {:ok, %{changed_count: 2}} = result

    assert {:config_changed_batch,
            %{
              origin: %{node: node_name, instance: instance},
              epoch: epoch,
              subsystems: [:listing, :s3]
            }} = event

    assert node_name == node()
    assert is_binary(instance) and byte_size(instance) > 0
    assert is_integer(epoch) and epoch > 0

    # One Store.load_all!/1 is one aggregate SELECT plus one row SELECT. A self-loop reload would
    # make this four; the telemetry handler counts only the caller and this subscribed Store.
    assert query_count.() == 2
  end

  test "real PubSub reloads a different origin once and ignores its replay with bounded state" do
    assert is_pid(Process.whereis(Maxio.PubSub))
    pid = start_store(:config_store_batch_remote_replay, subscribe: true, repo: Repo)
    Phoenix.PubSub.subscribe(Maxio.PubSub, Notify.topic())
    insert_runtime!(8_101)

    event =
      {:config_changed_batch,
       %{
         origin: %{node: node(), instance: "same-node-other-instance-1"},
         epoch: 41,
         subsystems: [:listing]
       }}

    same_epoch_other_origin =
      {:config_changed_batch,
       %{
         origin: %{node: node(), instance: "same-node-other-instance-2"},
         epoch: 41,
         subsystems: [:listing]
       }}

    {_result, query_count} =
      count_reload_queries([pid], fn ->
        assert :ok = Phoenix.PubSub.broadcast(Maxio.PubSub, Notify.topic(), event)
        assert_receive ^event
        _ = :sys.get_state(pid)

        assert :ok = Phoenix.PubSub.broadcast(Maxio.PubSub, Notify.topic(), event)
        assert_receive ^event

        assert :ok =
                 Phoenix.PubSub.broadcast(
                   Maxio.PubSub,
                   Notify.topic(),
                   same_epoch_other_origin
                 )

        assert_receive ^same_epoch_other_origin
        state = :sys.get_state(pid)

        assert bounded_recent_event_count(state) in 1..256
        state
      end)

    assert query_count.() == 4
    assert Store.lookup(:listing, :sql_hard_limit) == {:ok, 8_101}
  end

  test "remote batch replay cache remains bounded after more unique events than its limit" do
    pid = start_store(:config_store_batch_bounded_replay, subscribe: false, repo: Repo)

    event = fn epoch ->
      {:config_changed_batch,
       %{
         origin: %{node: :"remote@maxio-test", instance: "remote-overflow"},
         epoch: epoch,
         subsystems: [:listing]
       }}
    end

    {_state, initial_queries} =
      count_reload_queries([pid], fn ->
        for epoch <- 1..300, do: send(pid, event.(epoch))
        :sys.get_state(pid)
      end)

    state = :sys.get_state(pid)
    assert initial_queries.() == 600
    assert bounded_recent_event_count(state) == 256

    {_state, recent_replay_queries} =
      count_reload_queries([pid], fn ->
        send(pid, event.(300))
        :sys.get_state(pid)
      end)

    assert recent_replay_queries.() == 0

    {_state, evicted_replay_queries} =
      count_reload_queries([pid], fn ->
        send(pid, event.(1))
        :sys.get_state(pid)
      end)

    assert evicted_replay_queries.() == 2
  end

  defp start_store(name, extra_opts \\ []) do
    pid =
      start_supervised!(
        {Store,
         Keyword.merge(
           [
             name: name,
             repo: ConfigPostcommitStore,
             load_on_boot: false,
             subscribe: false,
             refresh_interval_ms: 0
           ],
           extra_opts
         )}
      )

    Ecto.Adapters.SQL.Sandbox.allow(Maxio.Repo, self(), pid)
    _ = :sys.get_state(pid)
    pid
  end

  defp count_reload_queries(pids, fun) do
    owner = self()
    id = {__MODULE__, :reload_query_count, make_ref()}
    prefix = Keyword.get(Repo.config(), :telemetry_prefix) || [:maxio, :repo]

    :ok =
      :telemetry.attach(
        id,
        prefix ++ [:query],
        fn _event, _measurements, metadata, state ->
          if self() in state.pids and reload_query?(metadata.query) do
            send(state.owner, {:reload_query, state.id})
          end
        end,
        %{owner: owner, pids: pids, id: id}
      )

    try do
      result = fun.()
      {result, fn -> drain_reload_queries(id, 0) end}
    after
      :telemetry.detach(id)
    end
  end

  defp drain_reload_queries(id, count) do
    receive do
      {:reload_query, ^id} -> drain_reload_queries(id, count + 1)
    after
      0 -> count
    end
  end

  defp reload_query?(query) when is_binary(query) do
    normalized = String.downcase(query)

    String.starts_with?(normalized, "select") and
      String.contains?(normalized, "runtime_configs") and
      not String.contains?(normalized, "for update")
  end

  defp reload_query?(_query), do: false

  defp bounded_recent_event_count(%{recent_batch_events: %MapSet{} = recent}),
    do: MapSet.size(recent)

  defp bounded_recent_event_count(%{recent_batch_events: recent}) when is_map(recent),
    do: map_size(recent)

  defp bounded_recent_event_count(%{recent_batch_events: recent}) when is_list(recent),
    do: length(recent)

  defp bounded_recent_event_count(_state), do: 0

  defp insert_runtime!(value) do
    Repo.insert!(%RuntimeConfig{
      subsystem: "listing",
      key: "sql_hard_limit",
      value: %{"v" => value},
      version: 1,
      apply_mode: "hot",
      source: "cli"
    })
  end

  defp capture_outcome(fun) do
    {:returned, fun.()}
  rescue
    error -> {:raised, error.__struct__}
  catch
    kind, _reason -> {:caught, kind}
  end
end
