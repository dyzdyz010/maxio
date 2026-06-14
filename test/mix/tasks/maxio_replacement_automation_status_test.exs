defmodule Mix.Tasks.MaxioReplacementAutomationStatusTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Maxio.Replacement.AutomationStatus

  @task "maxio.replacement.automation_status"
  @env_keys [:fresh_drive_heal_scheduler, :rebalance_scheduler, :scheduler_ledger]

  setup do
    previous = Map.new(@env_keys, &{&1, Application.get_env(:maxio, &1, :__unset__)})
    Mix.Task.reenable(@task)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, :__unset__} -> Application.delete_env(:maxio, key)
        {key, value} -> Application.put_env(:maxio, key, value)
      end)

      Mix.Task.reenable(@task)
    end)
  end

  test "default command prints read-only blocked automation profile" do
    put_scheduler_env([], [], enabled: true)

    output = capture_io(fn -> AutomationStatus.run([]) end)

    assert output =~ "[maxio replacement.automation_status] status=blocked"
    assert output =~ "component=fresh_drive_heal_scheduler"
    assert output =~ "component=rebalance_scheduler"
    assert output =~ "fresh_drive_heal_scheduler_disabled"
    assert output =~ "next_action=\"configure :fresh_drive_heal_scheduler, enabled: true\""
  end

  test "json command emits machine-readable ready report" do
    put_ready_env()

    decoded =
      capture_io(fn -> AutomationStatus.run(["--json"]) end)
      |> Jason.decode!()

    assert decoded["profile"] == "replacement_automation_v1"
    assert decoded["status"] == "ready"
    assert decoded["ready?"] == true
    assert decoded["blockers"] == []
    assert decoded["warnings"] == []
    assert decoded["next_action"] == "none"
  end

  test "fail-on-blocked prints JSON before returning a non-zero gate" do
    put_scheduler_env([], [], enabled: true)

    output =
      capture_io(fn ->
        assert_raise Mix.Error, ~r/replacement automation blocked/, fn ->
          AutomationStatus.run(["--json", "--fail-on-blocked"])
        end
      end)

    decoded = Jason.decode!(output)
    assert decoded["status"] == "blocked"
    assert "fresh_drive_heal_scheduler_disabled" in decoded["blockers"]
  end

  test "fail-on-attention also fails blocked reports after printing JSON" do
    put_scheduler_env([], [], enabled: true)

    output =
      capture_io(fn ->
        assert_raise Mix.Error, ~r/replacement automation blocked/, fn ->
          AutomationStatus.run(["--json", "--fail-on-attention"])
        end
      end)

    decoded = Jason.decode!(output)
    assert decoded["status"] == "blocked"
    assert "fresh_drive_heal_scheduler_disabled" in decoded["blockers"]
  end

  test "command does not start application schedulers" do
    put_ready_env()

    code = """
    Application.put_env(:maxio, :fresh_drive_heal_scheduler, enabled: true, auto_rebalance_after_heal: true)
    Application.put_env(:maxio, :rebalance_scheduler, enabled: true, auto_source_cleanup: true, auto_rebalance_closure: true)
    Application.put_env(:maxio, :scheduler_ledger, enabled: true)
    Mix.Task.run("maxio.replacement.automation_status", ["--json"])
    IO.puts("FRESH_SCHEDULER=\#{inspect(Process.whereis(Maxio.Cluster.FreshDriveHeal.Scheduler))}")
    IO.puts("REBALANCE_SCHEDULER=\#{inspect(Process.whereis(Maxio.Cluster.Rebalance.Scheduler))}")
    IO.puts("LIFECYCLE_SCHEDULER=\#{inspect(Process.whereis(Maxio.Lifecycle.Scheduler))}")
    """

    script_path =
      Path.join(
        System.tmp_dir!(),
        "maxio_replacement_automation_status_probe_#{System.unique_integer([:positive])}.exs"
      )

    File.write!(script_path, code)
    on_exit(fn -> File.rm(script_path) end)

    {cmd, args} = mix_run_no_start_script(script_path)
    {output, status} = System.cmd(cmd, args, env: [{"MIX_ENV", "test"}], stderr_to_stdout: true)

    assert status == 0, output
    assert output =~ "FRESH_SCHEDULER=nil"
    assert output =~ "REBALANCE_SCHEDULER=nil"
    assert output =~ "LIFECYCLE_SCHEDULER=nil"
  end

  defp put_ready_env do
    put_scheduler_env(
      [enabled: true, probe_drive_health: true, auto_rebalance_after_heal: true],
      [enabled: true, auto_source_cleanup: true, auto_rebalance_closure: true],
      enabled: true
    )
  end

  defp put_scheduler_env(fresh, rebalance, ledger) do
    Application.put_env(:maxio, :fresh_drive_heal_scheduler, fresh)
    Application.put_env(:maxio, :rebalance_scheduler, rebalance)
    Application.put_env(:maxio, :scheduler_ledger, ledger)
  end

  defp mix_run_no_start_script(script_path) do
    case :os.type() do
      {:win32, _} -> {"cmd", ["/c", "mix", "run", "--no-start", script_path]}
      _other -> {System.find_executable("mix") || "mix", ["run", "--no-start", script_path]}
    end
  end
end
