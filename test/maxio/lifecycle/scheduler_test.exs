defmodule Maxio.Lifecycle.SchedulerTest do
  use ExUnit.Case, async: true

  alias Maxio.Lifecycle.Scheduler

  test "disabled scheduler starts without scheduling a timer" do
    pid = start_supervised!({Scheduler, name: nil, enabled: false})

    assert %{enabled: false, timer_ref: nil, last_result: nil} = :sys.get_state(pid)
  end

  test "run_now invokes configured runner with run options and records summary" do
    parent = self()
    summary = summary(%{buckets_scanned: 1, objects_expired: 2})

    runner = fn opts ->
      send(parent, {:runner_called, opts})
      summary
    end

    pid =
      start_supervised!(
        {Scheduler, name: nil, enabled: false, runner: runner, run_opts: [bucket: "logs"]}
      )

    assert {:ok, ^summary} = Scheduler.run_now(pid)
    assert_receive {:runner_called, [bucket: "logs"]}
    assert %{last_result: {:ok, ^summary}} = :sys.get_state(pid)
  end

  test "scheduled sweep uses the same runner and reschedules after completion" do
    parent = self()

    runner = fn opts ->
      send(parent, {:swept, opts})
      summary(%{buckets_scanned: 1})
    end

    pid =
      start_supervised!(
        {Scheduler,
         name: nil,
         enabled: true,
         initial_delay_ms: 60_000,
         interval_ms: 60_000,
         runner: runner,
         run_opts: [dry_run: true]}
      )

    send(pid, :sweep)
    _ = :sys.get_state(pid)

    assert_receive {:swept, [dry_run: true]}
    assert %{enabled: true, timer_ref: ref, last_result: {:ok, _}} = :sys.get_state(pid)
    assert is_reference(ref)
  end

  test "runner crashes are captured without stopping the scheduler" do
    runner = fn _opts -> raise "boom" end

    pid =
      start_supervised!({Scheduler, name: nil, enabled: false, runner: runner})

    assert {:error, "boom"} = Scheduler.run_now(pid)
    assert %{last_result: {:error, "boom"}} = :sys.get_state(pid)
  end

  defp summary(overrides) do
    Map.merge(
      %{
        buckets_scanned: 0,
        objects_expired: 0,
        noncurrent_versions_expired: 0,
        delete_markers_removed: 0,
        multipart_uploads_aborted: 0,
        mfa_delete_protected_actions_skipped: 0,
        unsupported_rules: 0,
        errors: []
      },
      overrides
    )
  end
end
