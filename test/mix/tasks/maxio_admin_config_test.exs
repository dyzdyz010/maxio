defmodule Mix.Tasks.MaxioAdminConfigTest do
  use Maxio.DataCase, async: false

  import ExUnit.CaptureIO

  alias Maxio.Cluster.Notify
  alias Maxio.Config
  alias Maxio.Config.{RuntimeConfig, RuntimeConfigAudit, Store}
  alias Mix.Tasks.Maxio.Admin.Config.Get, as: AdminGet
  alias Mix.Tasks.Maxio.Admin.Config.Reset, as: AdminReset
  alias Mix.Tasks.Maxio.Admin.Config.Set, as: AdminSet

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

  test "GET writes each exposed subsystem as exact redacted KVS bytes" do
    # Catches an added newline, loss of madmin's final ASCII space, a non-Adapter renderer, or a
    # CLI projection that includes a known hidden value.
    hidden_value = "DEPLOYMENT-MUST-NOT-REACH-CLI"
    insert_runtime!("cluster", "deployment_id", hidden_value, 1)

    for {subsystem, expected} <- [
          {"s3", "s3 clock_skew_ms=900000 \n"},
          {"listing", "listing sql_hard_limit=100000 \n"},
          {"prometheus_metrics", "prometheus_metrics public=false \n"}
        ] do
      output = capture_io(fn -> run_task(AdminGet, [subsystem]) end)

      assert output == expected
      assert String.ends_with?(output, <<32, 10>>)
      refute output =~ hidden_value
      refute output =~ "deployment_id"
    end
  end

  test "SET joins quoted and split argv identically and records fresh CLI audit ids" do
    # Catches parsing argv as independent key/value tokens, dropping source=cli, reusing one
    # request id across commands, or printing submitted values/audit identifiers.
    quoted_output =
      capture_io(fn -> run_task(AdminSet, ["s3 clock_skew_ms=1001"]) end)

    split_output =
      capture_io(fn -> run_task(AdminSet, ["s3", "clock_skew_ms=1002"]) end)

    expected =
      "committed=true changed_count=1 apply_modes=hot local_reload=ok broadcast=ok " <>
        "attention=false\n"

    assert quoted_output == expected
    assert split_output == expected
    refute quoted_output =~ "1001"
    refute split_output =~ "1002"

    assert Repo.one(
             from row in RuntimeConfig,
               where: row.subsystem == "s3" and row.key == "clock_skew_ms",
               select: {row.value, row.version, row.source}
           ) == {%{"v" => 1002}, 2, "cli"}

    audits =
      Repo.all(
        from audit in RuntimeConfigAudit,
          where: audit.subsystem == "s3" and audit.key == "clock_skew_ms",
          order_by: [asc: audit.to_version],
          select: %{
            source: audit.source,
            request_id: audit.request_id,
            principal_arn: audit.principal_arn,
            access_key_id: audit.access_key_id
          }
      )

    assert Enum.map(audits, & &1.source) == ["cli", "cli"]
    assert Enum.map(audits, & &1.principal_arn) == [nil, nil]
    assert Enum.map(audits, & &1.access_key_id) == [nil, nil]

    request_ids = Enum.map(audits, & &1.request_id)
    assert Enum.all?(request_ids, &match?({:ok, _uuid}, Ecto.UUID.cast(&1)))
    assert request_ids |> MapSet.new() |> MapSet.size() == 2
    Enum.each(request_ids, &refute(quoted_output =~ &1 or split_output =~ &1))
  end

  test "mutation formatter emits unique apply modes in deterministic order" do
    # Catches map-enumeration order leaking into operator-visible output or duplicate apply modes
    # being printed once per changed key instead of once per mode.
    result = %{
      committed?: true,
      subsystem: :formatter_fixture,
      changed_count: 4,
      changed_keys: [:restart_key, :hot_key, :next_cycle_key, :second_hot_key],
      outcomes: %{
        restart_key: full_outcome(:set, true, 1, :restart),
        hot_key: full_outcome(:set, true, 1, :hot),
        next_cycle_key: full_outcome(:reset, true, nil, :next_cycle),
        second_hot_key: full_outcome(:set, true, 1, :hot),
        unchanged_key: full_outcome(:set, false, 9, :restart)
      },
      local_reload: :ok,
      broadcast: :ok,
      attention?: false
    }

    assert AdminSet.format_result(result) ==
             "committed=true changed_count=4 apply_modes=hot,next_cycle,restart " <>
               "local_reload=ok broadcast=ok attention=false"
  end

  test "mutation formatter exposes only closed postcommit failure enums" do
    # Catches collapsing the two independently actionable postcommit failures into a generic
    # value, dropping attention=true, or leaking an internal reason into the safe CLI line.
    result = %{
      committed?: true,
      subsystem: :s3,
      changed_count: 1,
      changed_keys: [:clock_skew_ms],
      outcomes: %{
        clock_skew_ms: full_outcome(:set, true, 2, :hot)
      },
      local_reload: {:error, :reload_failed},
      broadcast: {:error, :broadcast_failed},
      attention?: true
    }

    assert AdminSet.format_result(result) ==
             "committed=true changed_count=1 apply_modes=hot " <>
               "local_reload=reload_failed broadcast=broadcast_failed attention=true"
  end

  test "mutation formatter rejects contradictory and unknown result shapes with one safe error" do
    # Catches malformed coordinator/Adapter results being rendered as committed truth with
    # apply_modes=unknown, local_reload=failed, a false changed count, or contradictory attention.
    valid_changed = %{
      committed?: true,
      subsystem: :s3,
      changed_count: 1,
      changed_keys: [:clock_skew_ms],
      outcomes: %{
        clock_skew_ms: full_outcome(:set, true, 2, :hot)
      },
      local_reload: :ok,
      broadcast: :ok,
      attention?: false
    }

    valid_no_op = %{
      committed?: true,
      subsystem: :s3,
      changed_count: 0,
      changed_keys: [],
      outcomes: %{
        clock_skew_ms: full_outcome(:set, false, 2, :hot)
      },
      local_reload: :not_needed,
      broadcast: :not_needed,
      attention?: false
    }

    invalid_results = [
      {"changed_count exceeds changed outcomes", Map.put(valid_changed, :changed_count, 2)},
      {"changed_count hides a changed outcome", Map.put(valid_changed, :changed_count, 0)},
      {"unknown applied mode",
       put_in(valid_changed, [:outcomes, :clock_skew_ms, :applied], :eventually)},
      {"malformed changed outcome",
       put_in(valid_changed, [:outcomes, :clock_skew_ms], %{changed?: true})},
      {"non-map outcome", put_in(valid_changed, [:outcomes, :clock_skew_ms], :invalid)},
      {"unknown reload result",
       Map.put(valid_changed, :local_reload, {:error, {:internal, "TOP-SECRET"}})},
      {"unknown broadcast result",
       Map.put(valid_changed, :broadcast, {:error, {:transport, "TOP-SECRET"}})},
      {"invalid attention", Map.put(valid_changed, :attention?, :yes)},
      {"uncommitted result", Map.put(valid_changed, :committed?, false)},
      {"failed postcommit without attention",
       Map.put(valid_changed, :local_reload, {:error, :reload_failed})},
      {"attention without postcommit failure", Map.put(valid_changed, :attention?, true)},
      {"changed result claims postcommit was unnecessary",
       valid_changed
       |> Map.put(:local_reload, :not_needed)
       |> Map.put(:broadcast, :not_needed)},
      {"no-op claims postcommit ran",
       valid_no_op
       |> Map.put(:local_reload, :ok)
       |> Map.put(:broadcast, :ok)}
    ]

    for {label, result} <- invalid_results do
      error =
        assert_raise Mix.Error, "configuration operation returned an invalid result", fn ->
          AdminSet.format_result(result)
        end

      assert error.message == "configuration operation returned an invalid result", label
      refute error.message =~ "TOP-SECRET"
    end
  end

  test "RESET subset joins quoted and split argv and changes only the exposed key" do
    # Catches a reset task with its own whitespace grammar or a direct delete that bypasses the
    # Adapter's exposed-key projection.
    capture_io(fn -> run_task(AdminSet, ["s3 clock_skew_ms=2001"]) end)

    quoted_output =
      capture_io(fn -> run_task(AdminReset, ["s3 clock_skew_ms"]) end)

    capture_io(fn -> run_task(AdminSet, ["s3", "clock_skew_ms=2002"]) end)

    split_output =
      capture_io(fn -> run_task(AdminReset, ["s3", "clock_skew_ms"]) end)

    expected =
      "committed=true changed_count=1 apply_modes=hot local_reload=ok broadcast=ok " <>
        "attention=false\n"

    assert quoted_output == expected
    assert split_output == expected

    refute Repo.exists?(
             from row in RuntimeConfig,
               where: row.subsystem == "s3" and row.key == "clock_skew_ms"
           )

    assert Repo.aggregate(
             from(audit in RuntimeConfigAudit,
               where:
                 audit.subsystem == "s3" and audit.key == "clock_skew_ms" and
                   audit.operation == "reset"
             ),
             :count
           ) == 2
  end

  test "RESET with only a subsystem is full for exposed keys and preserves hidden rows" do
    # Catches expanding a full reset from the core schema (which would delete hidden material) or
    # requiring a key when Adapter deliberately supports subsystem reset.
    insert_runtime!("s3", "root_user", "hidden-root", 7)
    capture_io(fn -> run_task(AdminSet, ["s3 clock_skew_ms=3001"]) end)

    output = capture_io(fn -> run_task(AdminReset, ["s3"]) end)

    assert output ==
             "committed=true changed_count=1 apply_modes=hot local_reload=ok broadcast=ok " <>
               "attention=false\n"

    assert Repo.all(
             from row in RuntimeConfig,
               where: row.subsystem == "s3",
               order_by: [asc: row.key],
               select: {row.key, row.value, row.version}
           ) == [{"root_user", %{"v" => "hidden-root"}, 7}]
  end

  test "equal SET reports a no-op without version audit reload or broadcast" do
    # Catches manufacturing a version/audit for an equal typed value or reporting postcommit work
    # that the coordinator deliberately skips.
    :ok = Phoenix.PubSub.subscribe(Maxio.PubSub, Notify.topic())

    assert capture_io(fn -> run_task(AdminSet, ["listing sql_hard_limit=4100"]) end) ==
             "committed=true changed_count=1 apply_modes=hot local_reload=ok broadcast=ok " <>
               "attention=false\n"

    assert_receive {:config_changed, :listing}
    refute_receive {:config_changed, :listing}, 0

    before_row = runtime_row("listing", "sql_hard_limit")
    before_audits = Repo.aggregate(RuntimeConfigAudit, :count)

    output = capture_io(fn -> run_task(AdminSet, ["listing", "sql_hard_limit=4100"]) end)

    assert output ==
             "committed=true changed_count=0 apply_modes=none local_reload=not_needed " <>
               "broadcast=not_needed attention=false\n"

    assert runtime_row("listing", "sql_hard_limit") == before_row
    assert Repo.aggregate(RuntimeConfigAudit, :count) == before_audits
    refute_receive {:config_changed, :listing}, 0
  end

  test "repeated full RESET reports a no-op without audit or broadcast" do
    # Catches treating a full-reset retry as an error or replaying mutation/postcommit side effects.
    :ok = Phoenix.PubSub.subscribe(Maxio.PubSub, Notify.topic())
    capture_io(fn -> run_task(AdminSet, ["prometheus_metrics public=true"]) end)
    assert_receive {:config_changed, :prometheus_metrics}

    assert capture_io(fn -> run_task(AdminReset, ["prometheus_metrics"]) end) ==
             "committed=true changed_count=1 apply_modes=hot local_reload=ok broadcast=ok " <>
               "attention=false\n"

    assert_receive {:config_changed, :prometheus_metrics}
    before_audits = Repo.aggregate(RuntimeConfigAudit, :count)

    assert capture_io(fn -> run_task(AdminReset, ["prometheus_metrics"]) end) ==
             "committed=true changed_count=0 apply_modes=none local_reload=not_needed " <>
               "broadcast=not_needed attention=false\n"

    assert Repo.aggregate(RuntimeConfigAudit, :count) == before_audits
    refute_receive {:config_changed, :prometheus_metrics}, 0
  end

  test "malformed target unknown hidden forbidden and invalid typed commands fail safely" do
    # Catches raw Adapter reasons, plaintext commands, values, hidden names, or a local second
    # grammar escaping through Mix.Error/stdout.
    cases = [
      {AdminSet, ["s3 clock_skew_ms=1\nlisting sql_hard_limit=2"],
       "configuration has incorrect format", ["clock_skew_ms=1", "sql_hard_limit=2"]},
      {AdminGet, ["s3:secondary"], "invalid argument", ["secondary"]},
      {AdminGet, ["absent"], "configuration request is invalid", ["absent"]},
      {AdminReset, ["cluster deployment_id"], "configuration request is invalid",
       ["deployment_id"]},
      {AdminSet, ["s3 root_password=TOP-SECRET-SUBMITTED-VALUE"], "access denied",
       ["root_password", "TOP-SECRET-SUBMITTED-VALUE"]},
      {AdminSet, ["s3 clock_skew_ms=NOT-AN-INTEGER"], "configuration has incorrect format",
       ["NOT-AN-INTEGER"]},
      {AdminSet, ["s3", "clock_skew_ms=12", "--expected-version", "0"],
       "configuration has incorrect format", ["clock_skew_ms=12", "expected-version"]}
    ]

    for {task, args, expected_message, private_fragments} <- cases do
      {message, output} = capture_mix_error(fn -> run_task(task, args) end)

      assert message == expected_message
      assert output == ""

      for fragment <- private_fragments do
        refute output =~ fragment
        refute message =~ fragment
      end
    end

    assert Repo.aggregate(RuntimeConfig, :count) == 0
    assert Repo.aggregate(RuntimeConfigAudit, :count) == 0
  end

  test "new KVS and old single-key CLI wait on the same subsystem advisory lock", %{
    task_supervisor: task_supervisor
  } do
    # Catches either CLI writing runtime_configs directly or preserving an old single-key fast
    # path. PostgreSQL wait state is observed on real independent connections; no timing sleep or
    # production spy is involved.
    owner = self()
    release_ref = make_ref()

    holder =
      Task.Supervisor.async_nolink(task_supervisor, fn ->
        unboxed(fn ->
          Config.mutate_subsystem(:listing, [{:set, :sql_hard_limit, 5100}],
            source: "system",
            request_id: "req-cli-lock-holder",
            checkpoint: hold_after_advisory_lock(owner, release_ref)
          )
        end)
      end)

    holder_pid =
      receive do
        {:config_cli_lock_held, pid} -> pid
      after
        5_000 -> flunk("holder did not reach the subsystem advisory-lock checkpoint")
      end

    new_writer =
      locked_cli_task(task_supervisor, owner, :new_writer, fn ->
        run_task(AdminSet, ["listing", "sql_hard_limit=5200"])
      end)

    old_writer =
      locked_cli_task(task_supervisor, owner, :old_writer, fn ->
        run_task(Mix.Tasks.Maxio.Config.Set, ["listing", "sql_hard_limit", "5300"])
      end)

    try do
      new_backend = receive_backend!(:new_writer)
      old_backend = receive_backend!(:old_writer)

      assert_backend_waits_on_lock!(new_backend)
      assert_backend_waits_on_lock!(old_backend)
    after
      send(holder_pid, {:release_config_cli_lock, release_ref})
    end

    assert {:ok, %{changed_count: 1}} = Task.await(holder, 10_000)

    assert Task.await(new_writer, 10_000) ==
             "committed=true changed_count=1 apply_modes=hot local_reload=ok broadcast=ok " <>
               "attention=false\n"

    old_output = Task.await(old_writer, 10_000)
    assert old_output =~ "[maxio config.set] subsystem=listing key=sql_hard_limit"
    assert old_output =~ "source=cli"

    assert unboxed(fn ->
             Repo.one(
               from row in RuntimeConfig,
                 where: row.subsystem == "listing" and row.key == "sql_hard_limit",
                 select: row.version
             )
           end) == 3

    assert unboxed(fn ->
             Repo.aggregate(
               from(audit in RuntimeConfigAudit,
                 where: audit.subsystem == "listing" and audit.key == "sql_hard_limit"
               ),
               :count
             )
           end) == 3
  end

  defp run_task(module, args), do: apply(module, :run, [args])

  defp capture_mix_error(fun) do
    ref = make_ref()

    output =
      capture_io(fn ->
        error = assert_raise Mix.Error, fun
        send(self(), {ref, error.message})
      end)

    assert_receive {^ref, message}
    {message, output}
  end

  defp runtime_row(subsystem, key) do
    Repo.one(
      from row in RuntimeConfig,
        where: row.subsystem == ^subsystem and row.key == ^key,
        select: {row.value, row.version, row.source}
    )
  end

  defp insert_runtime!(subsystem, key, value, version) do
    %RuntimeConfig{}
    |> RuntimeConfig.changeset(%{
      subsystem: subsystem,
      key: key,
      value: %{"v" => value},
      version: version,
      apply_mode: "hot",
      source: "system"
    })
    |> Repo.insert!()
  end

  defp locked_cli_task(task_supervisor, owner, tag, fun) do
    Task.Supervisor.async_nolink(task_supervisor, fn ->
      unboxed(fn ->
        backend_pid = backend_pid!()
        send(owner, {:config_cli_backend, tag, backend_pid})
        capture_io(fun)
      end)
    end)
  end

  defp receive_backend!(tag) do
    receive do
      {:config_cli_backend, ^tag, backend_pid} -> backend_pid
    after
      5_000 -> flunk("#{tag} did not report its PostgreSQL backend")
    end
  end

  defp hold_after_advisory_lock(owner, release_ref) do
    fn
      :after_advisory_lock ->
        send(owner, {:config_cli_lock_held, self()})

        receive do
          {:release_config_cli_lock, ^release_ref} -> :ok
        after
          10_000 -> raise "config CLI advisory-lock checkpoint timed out"
        end

      _phase ->
        :ok
    end
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
      match?(["Lock", "advisory", _state], observed) ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk(
          "backend #{backend_pid} did not wait on the config subsystem advisory lock; " <>
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

  defp full_outcome(operation, changed?, version, applied) do
    %{
      operation: operation,
      changed?: changed?,
      version: version,
      value: if(operation == :reset, do: nil, else: :fixture_value),
      applied: applied
    }
  end

  defp cleanup_unboxed! do
    unboxed(fn ->
      subsystems = ["cluster", "listing", "prometheus_metrics", "s3"]
      Repo.delete_all(from audit in RuntimeConfigAudit, where: audit.subsystem in ^subsystems)
      Repo.delete_all(from row in RuntimeConfig, where: row.subsystem in ^subsystems)
    end)
  end

  defp unboxed(fun), do: Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fun)
end
