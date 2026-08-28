defmodule Maxio.Config.StoreBatchEventTest do
  use Maxio.DataCase, async: false

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

    assert %{
             postcommit_attention: %{
               subsystem: :listing,
               local_reload: {:error, :reload_failed},
               broadcast: {:error, :broadcast_failed}
             }
           } = first_status

    first_serialized = inspect(first_status.postcommit_attention, limit: :infinity)
    refute first_serialized =~ "ATTENTION-RAW-RELOAD-MUST-NOT-PERSIST"
    refute first_serialized =~ "ATTENTION-RAW-BROADCAST-MUST-NOT-PERSIST"
    refute first_serialized =~ "ATTENTION-RAW-VALUE-MUST-NOT-PERSIST"
    refute first_serialized =~ "ATTENTION-RAW-REASON-MUST-NOT-PERSIST"

    assert :ok = apply(Store, :note_postcommit_attention, [second])

    status = Store.status()
    attention = apply(Map, :fetch!, [status, :postcommit_attention])

    assert %{
             postcommit_attention: %{
               subsystem: :s3,
               local_reload: :ok,
               broadcast: {:error, :broadcast_failed}
             }
           } = status

    refute is_list(attention)

    serialized = inspect(attention, limit: :infinity)
    refute serialized =~ "ATTENTION-RAW-RELOAD-MUST-NOT-PERSIST"
    refute serialized =~ "ATTENTION-RAW-BROADCAST-MUST-NOT-PERSIST"
    refute serialized =~ "ATTENTION-RAW-VALUE-MUST-NOT-PERSIST"
    refute serialized =~ "ATTENTION-RAW-REASON-MUST-NOT-PERSIST"
  end

  defp start_store(name) do
    pid =
      start_supervised!(
        {Store,
         name: name,
         repo: ConfigPostcommitStore,
         load_on_boot: false,
         subscribe: false,
         refresh_interval_ms: 0}
      )

    Ecto.Adapters.SQL.Sandbox.allow(Maxio.Repo, self(), pid)
    _ = :sys.get_state(pid)
    pid
  end

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
