defmodule Maxio.Cluster.SchedulerRunsTest do
  use Maxio.DataCase, async: false

  alias Maxio.Cluster.{SchedulerRun, SchedulerRuns}
  alias Maxio.Repo

  @t0 ~U[2026-06-14 00:00:00.000000Z]
  @day_seconds 86_400
  @day_ms @day_seconds * 1_000

  test "records ok run and restart-stable state" do
    {:ok, %{run: run, state: state}} =
      SchedulerRuns.record(
        :rebalance,
        :manual,
        @t0,
        DateTime.add(@t0, 125, :millisecond),
        {:ok, %{status: :ok, phase: :copy, job_id: "job-1", moved: 3}}
      )

    assert run.scheduler == "rebalance"
    assert run.trigger == "manual"
    assert run.status == "ok"
    assert run.result_kind == "ok"
    assert run.phase == "copy"
    assert run.job_id == "job-1"
    assert run.duration_ms == 125
    assert run.consecutive_failures_after == 0
    assert run.summary["moved"] == 3

    assert state.scheduler == "rebalance"
    assert state.status == "ok"
    assert state.consecutive_failures == 0
    assert state.last_run_id == run.id
    assert is_nil(state.backoff_until)
    assert is_nil(state.last_error_reason)
  end

  test "blocked and failed results advance alert and backoff state" do
    parent = self()

    {:ok, %{state: warning}} =
      SchedulerRuns.record(
        :fresh_drive_heal,
        :scheduled,
        @t0,
        @t0,
        {:ok,
         %{status: :ok, rebalance_enqueue: %{status: :failed, reason: :placement_fallbacks}}},
        failure_threshold: 2,
        backoff_ms: 60_000,
        alert_sink: fn _run, _state -> send(parent, :alert_emitted) end
      )

    assert warning.status == "blocked"
    assert warning.alert_status == "warning"
    assert warning.consecutive_failures == 1
    refute_receive :alert_emitted, 20

    {:ok, %{run: alert_run, state: alert}} =
      SchedulerRuns.record(
        :fresh_drive_heal,
        :scheduled,
        DateTime.add(@t0, 1, :second),
        DateTime.add(@t0, 1, :second),
        {:error, :transport_down},
        failure_threshold: 2,
        backoff_ms: 60_000,
        alert_sink: fn run, state -> send(parent, {:alert_emitted, run.id, state.scheduler}) end
      )

    assert alert_run.status == "failed"
    assert alert.status == "failed"
    assert alert.alert_status == "alert"
    assert alert.consecutive_failures == 2
    assert alert.backoff_until == DateTime.add(@t0, 61, :second)
    assert_receive {:alert_emitted, run_id, "fresh_drive_heal"}
    assert run_id == alert_run.id

    assert {:ok, ^alert} =
             SchedulerRuns.backoff_active?(:fresh_drive_heal,
               now: DateTime.add(@t0, 30, :second)
             )

    {:ok, %{state: recovered}} =
      SchedulerRuns.record(
        :fresh_drive_heal,
        :manual,
        DateTime.add(@t0, 62, :second),
        DateTime.add(@t0, 62, :second),
        {:ok, %{status: :ok}},
        failure_threshold: 2,
        backoff_ms: 60_000
      )

    assert recovered.status == "ok"
    assert recovered.alert_status == "ok"
    assert recovered.consecutive_failures == 0
    assert is_nil(recovered.backoff_until)
  end

  test "idle lock and backoff skips do not execute failure escalation incorrectly" do
    {:ok, %{state: failed}} =
      SchedulerRuns.record(
        :rebalance,
        :scheduled,
        @t0,
        @t0,
        {:error, :boom},
        failure_threshold: 1,
        backoff_ms: 60_000
      )

    assert failed.consecutive_failures == 1
    assert failed.alert_status == "alert"
    assert failed.backoff_until == DateTime.add(@t0, 60, :second)

    {:ok, %{run: backoff_run, state: skipped}} =
      SchedulerRuns.record(
        :rebalance,
        :scheduled,
        DateTime.add(@t0, 1, :second),
        DateTime.add(@t0, 1, :second),
        {:error, {:backoff_active, DateTime.to_iso8601(failed.backoff_until)}},
        failure_threshold: 1,
        backoff_ms: 60_000
      )

    assert backoff_run.status == "skipped"
    assert skipped.status == "failed"
    assert skipped.last_run_id == failed.last_run_id
    assert skipped.consecutive_failures == 1
    assert skipped.alert_status == "alert"
    assert skipped.backoff_until == failed.backoff_until

    {:ok, %{state: idle}} =
      SchedulerRuns.record(
        :rebalance,
        :scheduled,
        DateTime.add(@t0, 61, :second),
        DateTime.add(@t0, 61, :second),
        {:error, :no_runnable_job},
        failure_threshold: 1,
        backoff_ms: 60_000
      )

    assert idle.status == "idle"
    assert idle.consecutive_failures == 0
    assert idle.alert_status == "ok"
    assert is_nil(idle.backoff_until)

    {:ok, %{run: lock_run, state: locked}} =
      SchedulerRuns.record(
        :rebalance,
        :scheduled,
        DateTime.add(@t0, 62, :second),
        DateTime.add(@t0, 62, :second),
        {:error, :lock_unavailable}
      )

    assert lock_run.status == "skipped"
    assert locked.consecutive_failures == 0
    assert locked.status == "idle"
    assert locked.last_run_id == idle.last_run_id
  end

  test "lock unavailable after ok writes a skipped run but preserves effective ok state" do
    {:ok, %{run: ok_run, state: ok_state}} =
      SchedulerRuns.record(
        :rebalance,
        :scheduled,
        @t0,
        @t0,
        {:ok, %{status: :ok, phase: :copy, job_id: "job-ok"}}
      )

    {:ok, %{run: lock_run, state: preserved}} =
      SchedulerRuns.record(
        :rebalance,
        :scheduled,
        DateTime.add(@t0, 1, :second),
        DateTime.add(@t0, 1, :second),
        {:error, :lock_unavailable}
      )

    assert lock_run.status == "skipped"
    assert lock_run.result_kind == "error"
    assert lock_run.consecutive_failures_after == 0

    assert preserved.status == "ok"
    assert preserved.last_run_id == ok_run.id
    assert preserved.last_summary == ok_state.last_summary
    assert preserved.last_error_reason == ok_state.last_error_reason

    lock_run_id = lock_run.id
    ok_run_id = ok_run.id

    assert [%{id: ^lock_run_id}, %{id: ^ok_run_id}] =
             SchedulerRuns.list_runs(scheduler: :rebalance, limit: 2)
  end

  test "lock unavailable preserves existing alert and backoff state" do
    {:ok, %{state: failed}} =
      SchedulerRuns.record(
        :rebalance,
        :scheduled,
        @t0,
        @t0,
        {:error, :boom},
        failure_threshold: 1,
        backoff_ms: 60_000
      )

    {:ok, %{run: lock_loser, state: preserved}} =
      SchedulerRuns.record(
        :rebalance,
        :scheduled,
        DateTime.add(@t0, 1, :second),
        DateTime.add(@t0, 1, :second),
        {:error, :lock_unavailable},
        failure_threshold: 1,
        backoff_ms: 60_000
      )

    assert lock_loser.status == "skipped"
    assert lock_loser.consecutive_failures_after == 1
    assert lock_loser.backoff_until == failed.backoff_until
    assert preserved.status == "failed"
    assert preserved.last_run_id == failed.last_run_id
    assert preserved.consecutive_failures == 1
    assert preserved.alert_status == "alert"
    assert preserved.backoff_until == failed.backoff_until
  end

  test "alert sink failures are captured on the run and never raised" do
    {:ok, %{run: run, state: state}} =
      SchedulerRuns.record(
        :fresh_drive_heal,
        :scheduled,
        @t0,
        @t0,
        {:error, :boom},
        failure_threshold: 1,
        alert_sink: fn _run, _state -> raise "sink-boom" end
      )

    assert state.alert_status == "alert"
    assert run.summary["alert_emit_error"] =~ "sink-boom"
  end

  test "alert sink returned errors are captured on the run" do
    {:ok, %{run: run, state: state}} =
      SchedulerRuns.record(
        :fresh_drive_heal,
        :scheduled,
        @t0,
        @t0,
        {:error, :boom},
        failure_threshold: 1,
        alert_sink: fn _run, _state -> {:error, :notify_down} end
      )

    assert state.alert_status == "alert"
    assert run.summary["alert_emit_error"] =~ "notify_down"
  end

  test "summaries redact sensitive keys and auth-like text" do
    {:ok, %{run: run, state: state}} =
      SchedulerRuns.record(
        :fresh_drive_heal,
        :manual,
        @t0,
        @t0,
        {:ok,
         %{
           status: :ok,
           reason: %{
             secret_access_key: "super-secret",
             authorization: "AWS4-HMAC-SHA256 Credential=AKIA/20260614/us-east-1/s3/aws4_request",
             nested: %{raw_serial: "SERIAL-123", safe: "visible"}
           }
         }}
      )

    assert get_in(run.summary, ["reason", "secret_access_key"]) == "[REDACTED]"
    assert get_in(run.summary, ["reason", "nested", "raw_serial"]) == "[REDACTED]"
    assert get_in(run.summary, ["reason", "nested", "safe"]) == "visible"
    assert get_in(run.summary, ["reason", "authorization"]) == "[REDACTED]"

    assert get_in(state.last_summary, ["reason", "secret_access_key"]) == "[REDACTED]"
  end

  test "error summaries and reasons redact structured sensitive fields" do
    {:ok, %{run: run, state: state}} =
      SchedulerRuns.record(
        :rebalance,
        :manual,
        @t0,
        @t0,
        {:error,
         {
           :failed_request,
           %{
             bucket: "public-bucket",
             key: "customer/object.txt",
             secret_access_key: "super-secret",
             body: "object-bytes",
             authorization: "AWS4-HMAC-SHA256 Credential=AKIA/20260614/us-east-1/s3/aws4_request"
           }
         }}
      )

    [_, details] = run.summary["error"]
    assert details["bucket"] == "public-bucket"
    assert details["key"] == "customer/object.txt"
    assert details["secret_access_key"] == "[REDACTED]"
    assert details["body"] == "[REDACTED]"
    assert details["authorization"] == "[REDACTED]"

    refute run.error_reason =~ "super-secret"
    refute run.error_reason =~ "object-bytes"
    refute run.error_reason =~ "AKIA"
    refute state.last_error_reason =~ "super-secret"
  end

  test "lists and renders recent scheduler evidence" do
    {:ok, %{run: older}} =
      SchedulerRuns.record(:rebalance, :manual, @t0, @t0, {:ok, %{status: :ok}})

    {:ok, %{run: newer}} =
      SchedulerRuns.record(
        :rebalance,
        :manual,
        DateTime.add(@t0, 1, :second),
        DateTime.add(@t0, 1, :second),
        {:error, :no_runnable_job}
      )

    assert [^newer] = SchedulerRuns.list_runs(scheduler: "rebalance", limit: 1)
    assert [state] = SchedulerRuns.list_states(scheduler: "rebalance")
    assert state.scheduler == "rebalance"

    view = SchedulerRuns.to_view(newer)
    assert view.scheduler == "rebalance"
    assert view.status == "idle"
    assert view.started_at == "2026-06-14T00:00:01.000000Z"

    assert SchedulerRuns.to_view(older).status == "ok"
  end

  test "cadence report ignores manual runs when proving scheduled automation health" do
    {:ok, _recorded} =
      SchedulerRuns.record(:rebalance, :manual, @t0, @t0, {:ok, %{status: :ok}})

    {:ok, report} =
      SchedulerRuns.cadence_report(
        scheduler: :rebalance,
        now: DateTime.add(@t0, 30, :second),
        expected_interval_ms: 10_000,
        stale_after_ms: 20_000,
        since_minutes: 1
      )

    assert [cadence] = report.reports
    assert cadence.health == "not_started"
    assert cadence.reason == "no_scheduled_runs"
    assert cadence.state_status == "ok"
    assert cadence.scheduled_runs == 0
    assert cadence.effective_scheduled_runs == 0
    refute cadence.healthy?
  end

  test "cadence report does not count skipped scheduled runs as healthy heartbeat" do
    {:ok, _locked} =
      SchedulerRuns.record(
        :fresh_drive_heal,
        :scheduled,
        @t0,
        @t0,
        {:error, :lock_unavailable}
      )

    {:ok, stale_report} =
      SchedulerRuns.cadence_report(
        scheduler: :fresh_drive_heal,
        now: DateTime.add(@t0, 30, :second),
        expected_interval_ms: 10_000,
        stale_after_ms: 20_000,
        since_minutes: 1
      )

    assert [stale] = stale_report.reports
    assert stale.health == "stale"
    assert stale.reason == "no_effective_scheduled_run"
    assert stale.scheduled_runs == 1
    assert stale.skipped_scheduled_runs == 1
    assert stale.effective_scheduled_runs == 0
    refute stale.healthy?

    {:ok, _idle} =
      SchedulerRuns.record(
        :fresh_drive_heal,
        :scheduled,
        DateTime.add(@t0, 25, :second),
        DateTime.add(@t0, 25, :second),
        {:error, :no_runnable_job}
      )

    {:ok, healthy_report} =
      SchedulerRuns.cadence_report(
        scheduler: :fresh_drive_heal,
        now: DateTime.add(@t0, 30, :second),
        expected_interval_ms: 10_000,
        stale_after_ms: 20_000,
        since_minutes: 1
      )

    assert [healthy] = healthy_report.reports
    assert healthy.health == "ok"
    assert healthy.reason == "recent_effective_scheduled_run"
    assert healthy.scheduled_runs == 2
    assert healthy.skipped_scheduled_runs == 1
    assert healthy.effective_scheduled_runs == 1
    assert healthy.healthy?
  end

  test "cadence report prioritizes alert and backoff over recent scheduled evidence" do
    {:ok, %{state: failed}} =
      SchedulerRuns.record(
        :rebalance,
        :scheduled,
        @t0,
        @t0,
        {:error, :boom},
        failure_threshold: 1,
        backoff_ms: 60_000
      )

    {:ok, report} =
      SchedulerRuns.cadence_report(
        scheduler: :rebalance,
        now: DateTime.add(@t0, 1, :second),
        expected_interval_ms: 10_000,
        stale_after_ms: 20_000,
        since_minutes: 1
      )

    assert failed.alert_status == "alert"
    assert [cadence] = report.reports
    assert cadence.health == "alert"
    assert cadence.reason == "scheduler_alert"
    assert cadence.state_status == "failed"
    assert cadence.alert_status == "alert"
    assert cadence.backoff_until == failed.backoff_until
    assert cadence.effective_scheduled_runs == 1
    refute cadence.healthy?
  end

  test "cadence report does not let manual recovery turn latest scheduled failure green" do
    {:ok, %{run: failed_run}} =
      SchedulerRuns.record(
        :rebalance,
        :scheduled,
        @t0,
        @t0,
        {:error, :boom},
        failure_threshold: 3
      )

    {:ok, %{state: manual_recovery}} =
      SchedulerRuns.record(
        :rebalance,
        :manual,
        DateTime.add(@t0, 1, :second),
        DateTime.add(@t0, 1, :second),
        {:ok, %{status: :ok}},
        failure_threshold: 3
      )

    {:ok, report} =
      SchedulerRuns.cadence_report(
        scheduler: :rebalance,
        now: DateTime.add(@t0, 2, :second),
        expected_interval_ms: 10_000,
        stale_after_ms: 20_000,
        since_minutes: 1
      )

    assert manual_recovery.status == "ok"
    assert [cadence] = report.reports
    assert cadence.health == "failed"
    assert cadence.reason == "latest_scheduled_failed"
    assert cadence.last_effective_scheduled_run_id == failed_run.id
    assert cadence.last_effective_scheduled_status == "failed"
    assert is_nil(cadence.last_healthy_scheduled_run_id)
    refute cadence.healthy?
  end

  test "rollup persists scheduled and manual windows without changing cadence semantics" do
    {:ok, %{run: scheduled_ok}} =
      SchedulerRuns.record(
        :rebalance,
        :scheduled,
        @t0,
        DateTime.add(@t0, 5, :second),
        {:ok, %{status: :ok, phase: :copy, job_id: "job-rollup", moved: 1}}
      )

    {:ok, %{run: scheduled_skipped}} =
      SchedulerRuns.record(
        :rebalance,
        :scheduled,
        DateTime.add(@t0, 10, :second),
        DateTime.add(@t0, 11, :second),
        {:error, :lock_unavailable}
      )

    {:ok, %{run: manual_ok}} =
      SchedulerRuns.record(
        :rebalance,
        :manual,
        DateTime.add(@t0, 20, :second),
        DateTime.add(@t0, 21, :second),
        {:ok, %{status: :ok, phase: :source_cleanup, job_id: "job-rollup"}}
      )

    {:ok, report} =
      SchedulerRuns.rollup(
        scheduler: :rebalance,
        from: @t0,
        until: DateTime.add(@t0, 60, :second),
        window_ms: 60_000,
        now: DateTime.add(@t0, 120, :second)
      )

    assert report.status == :ok
    assert report.windows == 1
    assert length(report.rollups) == 2

    assert [manual, scheduled] =
             SchedulerRuns.list_rollups(scheduler: :rebalance, limit: 10)
             |> Enum.sort_by(& &1.trigger)

    assert manual.trigger == "manual"
    assert manual.run_count == 1
    assert manual.ok_count == 1
    assert manual.effective_count == 1
    assert manual.healthy_count == 1
    assert manual.last_run_id == manual_ok.id
    assert manual.last_phase == "source_cleanup"
    assert manual.last_job_id == "job-rollup"

    assert scheduled.trigger == "scheduled"
    assert scheduled.run_count == 2
    assert scheduled.ok_count == 1
    assert scheduled.skipped_count == 1
    assert scheduled.effective_count == 1
    assert scheduled.healthy_count == 1
    assert scheduled.first_run_id == scheduled_ok.id
    assert scheduled.last_run_id == scheduled_skipped.id
    assert scheduled.last_status == "skipped"
    assert scheduled.last_effective_run_id == scheduled_ok.id
    assert scheduled.last_healthy_run_id == scheduled_ok.id
    assert scheduled.source_digest
  end

  test "rollup keeps scheduled failure separate from later manual recovery" do
    {:ok, %{run: failed_run}} =
      SchedulerRuns.record(
        :fresh_drive_heal,
        :scheduled,
        @t0,
        @t0,
        {:error, :boom},
        failure_threshold: 3
      )

    {:ok, %{run: manual_ok}} =
      SchedulerRuns.record(
        :fresh_drive_heal,
        :manual,
        DateTime.add(@t0, 1, :second),
        DateTime.add(@t0, 1, :second),
        {:ok, %{status: :ok}},
        failure_threshold: 3
      )

    {:ok, _report} =
      SchedulerRuns.rollup(
        scheduler: :fresh_drive_heal,
        from: @t0,
        until: DateTime.add(@t0, 60, :second),
        window_ms: 60_000,
        now: DateTime.add(@t0, 120, :second)
      )

    scheduled = hd(SchedulerRuns.list_rollups(scheduler: :fresh_drive_heal, trigger: :scheduled))
    manual = hd(SchedulerRuns.list_rollups(scheduler: :fresh_drive_heal, trigger: :manual))

    assert scheduled.last_run_id == failed_run.id
    assert scheduled.last_status == "failed"
    assert scheduled.failed_count == 1
    assert scheduled.healthy_count == 0

    assert manual.last_run_id == manual_ok.id
    assert manual.last_status == "ok"
    assert manual.healthy_count == 1
  end

  test "rollup writes empty windows and reruns idempotently" do
    window_start = DateTime.add(@t0, 60, :second)
    window_end = DateTime.add(@t0, 120, :second)

    {:ok, %{rollups: [empty]}} =
      SchedulerRuns.rollup(
        scheduler: :rebalance,
        trigger: :scheduled,
        from: window_start,
        until: window_end,
        window_ms: 60_000,
        now: DateTime.add(@t0, 180, :second)
      )

    assert empty.run_count == 0
    assert [stored_empty] = SchedulerRuns.list_rollups(scheduler: :rebalance, trigger: :scheduled)
    assert stored_empty.run_count == 0
    empty_id = stored_empty.id
    empty_digest = stored_empty.source_digest

    {:ok, %{run: late_run}} =
      SchedulerRuns.record(
        :rebalance,
        :scheduled,
        DateTime.add(@t0, 70, :second),
        DateTime.add(@t0, 71, :second),
        {:ok, %{status: :ok}}
      )

    {:ok, _report} =
      SchedulerRuns.rollup(
        scheduler: :rebalance,
        trigger: :scheduled,
        from: window_start,
        until: window_end,
        window_ms: 60_000,
        now: DateTime.add(@t0, 180, :second)
      )

    assert [updated] = SchedulerRuns.list_rollups(scheduler: :rebalance, trigger: :scheduled)
    assert updated.id == empty_id
    assert updated.run_count == 1
    assert updated.last_run_id == late_run.id
    assert updated.source_digest != empty_digest
  end

  test "rollup rejects open or unaligned windows" do
    assert {:error, {:open_rollup_window, _until}} =
             SchedulerRuns.rollup(
               scheduler: :rebalance,
               trigger: :scheduled,
               from: @t0,
               until: DateTime.add(@t0, 60, :second),
               window_ms: 60_000,
               now: DateTime.add(@t0, 30, :second)
             )

    assert {:error, {:invalid_rollup_range, :from_not_aligned}} =
             SchedulerRuns.rollup(
               scheduler: :rebalance,
               trigger: :scheduled,
               from: DateTime.add(@t0, 1, :second),
               until: DateTime.add(@t0, 61, :second),
               window_ms: 60_000,
               now: DateTime.add(@t0, 120, :second)
             )

    assert {:error, {:invalid_rollup_range, :from_not_aligned}} =
             SchedulerRuns.rollup(
               scheduler: :rebalance,
               trigger: :scheduled,
               from: DateTime.add(@t0, 1, :microsecond),
               until: DateTime.add(@t0, 60_000_001, :microsecond),
               window_ms: 60_000,
               now: DateTime.add(@t0, 120, :second)
             )

    assert {:error, {:invalid_rollup_range, :invalid_window_ms}} =
             SchedulerRuns.rollup(
               scheduler: :rebalance,
               trigger: :scheduled,
               from: @t0,
               until: DateTime.add(@t0, 60, :second),
               window_ms: 0,
               now: DateTime.add(@t0, 120, :second)
             )

    assert {:error, {:invalid_scheduler, "bad"}} =
             SchedulerRuns.rollup(
               scheduler: :bad,
               trigger: :scheduled,
               from: @t0,
               until: DateTime.add(@t0, 60, :second),
               window_ms: 60_000,
               dry_run: true,
               now: DateTime.add(@t0, 120, :second)
             )
  end

  test "rollup last summary stays redacted and bounded" do
    {:ok, _recorded} =
      SchedulerRuns.record(
        :rebalance,
        :manual,
        @t0,
        @t0,
        {:error,
         {
           :failed_request,
           %{
             secret_access_key: "super-secret",
             authorization: "AWS4-HMAC-SHA256 Credential=AKIA/20260614/us-east-1/s3/aws4_request",
             body: "object-bytes",
             safe: "visible"
           }
         }}
      )

    {:ok, _report} =
      SchedulerRuns.rollup(
        scheduler: :rebalance,
        trigger: :manual,
        from: @t0,
        until: DateTime.add(@t0, 60, :second),
        window_ms: 60_000,
        now: DateTime.add(@t0, 120, :second)
      )

    assert [rollup] = SchedulerRuns.list_rollups(scheduler: :rebalance, trigger: :manual)
    [_, details] = rollup.last_summary["error"]
    assert details["secret_access_key"] == "[REDACTED]"
    assert details["authorization"] == "[REDACTED]"
    assert details["body"] == "[REDACTED]"
    assert details["safe"] == "visible"
    refute inspect(rollup) =~ "super-secret"
    refute inspect(rollup) =~ "object-bytes"
    refute inspect(rollup) =~ "AKIA"
  end

  test "prune requires verified rollup and preserves newer state evidence" do
    {:ok, %{run: old_run}} =
      SchedulerRuns.record(
        :rebalance,
        :scheduled,
        @t0,
        DateTime.add(@t0, 5, :second),
        {:ok, %{status: :ok, phase: :copy, job_id: "job-prune-old"}}
      )

    {:ok, %{run: protected_newer}} =
      SchedulerRuns.record(
        :rebalance,
        :scheduled,
        DateTime.add(@t0, 120, :second),
        DateTime.add(@t0, 121, :second),
        {:ok, %{status: :ok, phase: :copy, job_id: "job-prune-new"}}
      )

    {:ok, _rollup} =
      SchedulerRuns.rollup(
        scheduler: :rebalance,
        trigger: :scheduled,
        from: @t0,
        until: DateTime.add(@t0, 60, :second),
        window_ms: 60_000,
        now: DateTime.add(@t0, 180, :second)
      )

    {:ok, preflight} =
      SchedulerRuns.prune_preflight(
        scheduler: :rebalance,
        trigger: :scheduled,
        from: @t0,
        until: DateTime.add(@t0, 60, :second),
        window_ms: 60_000,
        now: DateTime.add(@t0, 180, :second)
      )

    assert preflight.status == :preflight
    assert preflight.candidate_runs == 1
    assert preflight.pruned_runs == 0
    assert Repo.get(SchedulerRun, old_run.id)

    assert {:error, :prune_confirmation_required} =
             SchedulerRuns.prune(
               scheduler: :rebalance,
               trigger: :scheduled,
               from: @t0,
               until: DateTime.add(@t0, 60, :second),
               window_ms: 60_000,
               now: DateTime.add(@t0, 180, :second)
             )

    {:ok, pruned} =
      SchedulerRuns.prune(
        scheduler: :rebalance,
        trigger: :scheduled,
        from: @t0,
        until: DateTime.add(@t0, 60, :second),
        window_ms: 60_000,
        confirm?: true,
        now: DateTime.add(@t0, 180, :second),
        node: :prune_test_node
      )

    assert pruned.status == :ok
    assert pruned.pruned_runs == 1
    refute Repo.get(SchedulerRun, old_run.id)
    assert Repo.get(SchedulerRun, protected_newer.id)

    [rollup] = SchedulerRuns.list_rollups(scheduler: :rebalance, trigger: :scheduled)
    assert rollup.pruned_run_count == 1
    assert rollup.pruned_source_digest == rollup.source_digest
    assert rollup.pruned_by_node == "prune_test_node"
    assert rollup.pruned_at

    rollup_id = rollup.id

    assert {:error, {:rollup_window_already_pruned, ^rollup_id}} =
             SchedulerRuns.rollup(
               scheduler: :rebalance,
               trigger: :scheduled,
               from: @t0,
               until: DateTime.add(@t0, 60, :second),
               window_ms: 60_000,
               now: DateTime.add(@t0, 180, :second)
             )

    {:ok, already} =
      SchedulerRuns.prune(
        scheduler: :rebalance,
        trigger: :scheduled,
        from: @t0,
        until: DateTime.add(@t0, 60, :second),
        window_ms: 60_000,
        confirm?: true,
        now: DateTime.add(@t0, 180, :second)
      )

    assert [%{status: :already_pruned}] = already.prunes
    assert already.pruned_runs == 0

    assert {:error,
            {:scheduler_run_window_pruned, ^rollup_id, "rebalance", "scheduled", @t0, 60_000}} =
             SchedulerRuns.record(
               :rebalance,
               :scheduled,
               DateTime.add(@t0, 30, :second),
               DateTime.add(@t0, 31, :second),
               {:ok, %{status: :ok, phase: :copy, job_id: "job-prune-late"}}
             )

    refute Enum.any?(
             SchedulerRuns.list_runs(scheduler: :rebalance, limit: 10),
             &(&1.job_id == "job-prune-late")
           )
  end

  test "prune fails closed without matching rollup or with stale digest" do
    {:ok, _old} =
      SchedulerRuns.record(
        :fresh_drive_heal,
        :manual,
        @t0,
        DateTime.add(@t0, 5, :second),
        {:ok, %{status: :ok}}
      )

    {:ok, _newer} =
      SchedulerRuns.record(
        :fresh_drive_heal,
        :manual,
        DateTime.add(@t0, 120, :second),
        DateTime.add(@t0, 121, :second),
        {:ok, %{status: :ok}}
      )

    assert {:error, {:missing_rollup, "fresh_drive_heal", "manual", _window_started_at, 60_000}} =
             SchedulerRuns.prune_preflight(
               scheduler: :fresh_drive_heal,
               trigger: :manual,
               from: @t0,
               until: DateTime.add(@t0, 60, :second),
               window_ms: 60_000,
               now: DateTime.add(@t0, 180, :second)
             )

    {:ok, _rollup} =
      SchedulerRuns.rollup(
        scheduler: :fresh_drive_heal,
        trigger: :manual,
        from: @t0,
        until: DateTime.add(@t0, 60, :second),
        window_ms: 60_000,
        now: DateTime.add(@t0, 180, :second)
      )

    {:ok, _late_same_window} =
      SchedulerRuns.record(
        :fresh_drive_heal,
        :manual,
        DateTime.add(@t0, 10, :second),
        DateTime.add(@t0, 11, :second),
        {:ok, %{status: :ok}}
      )

    assert {:error, {:rollup_run_count_mismatch, _rollup_id, 1, 2}} =
             SchedulerRuns.prune(
               scheduler: :fresh_drive_heal,
               trigger: :manual,
               from: @t0,
               until: DateTime.add(@t0, 60, :second),
               window_ms: 60_000,
               confirm?: true,
               now: DateTime.add(@t0, 180, :second)
             )
  end

  test "prune refuses current windows and protected scheduler state rows" do
    {:ok, %{run: protected_run}} =
      SchedulerRuns.record(
        :rebalance,
        :scheduled,
        @t0,
        DateTime.add(@t0, 5, :second),
        {:error, :boom}
      )

    {:ok, _rollup} =
      SchedulerRuns.rollup(
        scheduler: :rebalance,
        trigger: :scheduled,
        from: @t0,
        until: DateTime.add(@t0, 60, :second),
        window_ms: 60_000,
        now: DateTime.add(@t0, 120, :second)
      )

    {:ok, _empty_current_rollup} =
      SchedulerRuns.rollup(
        scheduler: :rebalance,
        trigger: :scheduled,
        from: DateTime.add(@t0, 60, :second),
        until: DateTime.add(@t0, 120, :second),
        window_ms: 60_000,
        now: DateTime.add(@t0, 180, :second)
      )

    assert {:error, {:open_rollup_window, _finished}} =
             SchedulerRuns.prune_preflight(
               scheduler: :rebalance,
               trigger: :scheduled,
               from: DateTime.add(@t0, 60, :second),
               until: DateTime.add(@t0, 120, :second),
               window_ms: 60_000,
               now: DateTime.add(@t0, 90, :second)
             )

    assert {:error, {:protected_scheduler_run, [protected_id]}} =
             SchedulerRuns.prune(
               scheduler: :rebalance,
               trigger: :scheduled,
               from: @t0,
               until: DateTime.add(@t0, 60, :second),
               window_ms: 60_000,
               confirm?: true,
               now: DateTime.add(@t0, 180, :second)
             )

    assert protected_id == protected_run.id
    assert Repo.get(SchedulerRun, protected_run.id)
  end

  test "prune is all-or-nothing across a range" do
    {:ok, %{run: first_window_run}} =
      SchedulerRuns.record(
        :rebalance,
        :manual,
        @t0,
        DateTime.add(@t0, 5, :second),
        {:ok, %{status: :ok}}
      )

    {:ok, _latest_manual} =
      SchedulerRuns.record(
        :rebalance,
        :manual,
        DateTime.add(@t0, 120, :second),
        DateTime.add(@t0, 121, :second),
        {:ok, %{status: :ok}}
      )

    {:ok, _rollup_first_only} =
      SchedulerRuns.rollup(
        scheduler: :rebalance,
        trigger: :manual,
        from: @t0,
        until: DateTime.add(@t0, 60, :second),
        window_ms: 60_000,
        now: DateTime.add(@t0, 240, :second)
      )

    assert {:error, {:missing_rollup, "rebalance", "manual", _second_window, 60_000}} =
             SchedulerRuns.prune(
               scheduler: :rebalance,
               trigger: :manual,
               from: @t0,
               until: DateTime.add(@t0, 120, :second),
               window_ms: 60_000,
               confirm?: true,
               now: DateTime.add(@t0, 240, :second)
             )

    assert Repo.get(SchedulerRun, first_window_run.id)
    assert [rollup] = SchedulerRuns.list_rollups(scheduler: :rebalance, trigger: :manual)
    assert is_nil(rollup.pruned_at)
  end

  test "cadence and prune protection share deterministic latest run ordering" do
    finished_at = DateTime.add(@t0, 10, :second)

    {:ok, %{run: older_tie}} =
      SchedulerRuns.record(
        :rebalance,
        :scheduled,
        @t0,
        finished_at,
        {:ok, %{status: :ok}}
      )

    {:ok, %{run: newer_tie}} =
      SchedulerRuns.record(
        :rebalance,
        :scheduled,
        DateTime.add(@t0, 1, :second),
        finished_at,
        {:error, :boom},
        failure_threshold: 3
      )

    {:ok, report} =
      SchedulerRuns.cadence_report(
        scheduler: :rebalance,
        now: DateTime.add(@t0, 30, :second),
        expected_interval_ms: 60_000,
        stale_after_ms: 120_000,
        since_minutes: 1
      )

    assert [cadence] = report.reports
    assert cadence.last_scheduled_run_id == newer_tie.id
    assert cadence.last_effective_scheduled_run_id == newer_tie.id
    assert cadence.last_healthy_scheduled_run_id == older_tie.id

    {:ok, _rollup} =
      SchedulerRuns.rollup(
        scheduler: :rebalance,
        trigger: :scheduled,
        from: @t0,
        until: DateTime.add(@t0, 60, :second),
        window_ms: 60_000,
        now: DateTime.add(@t0, 180, :second)
      )

    assert {:error, {:protected_scheduler_run, protected_ids}} =
             SchedulerRuns.prune(
               scheduler: :rebalance,
               trigger: :scheduled,
               from: @t0,
               until: DateTime.add(@t0, 60, :second),
               window_ms: 60_000,
               confirm?: true,
               now: DateTime.add(@t0, 180, :second)
             )

    assert newer_tie.id in protected_ids
    assert older_tie.id in protected_ids
  end

  test "cadence reports scheduled node participation and lock losers" do
    next_action = "mix maxio.rebalance.verify_closure --job-id job-blocked --json"

    {:ok, _ok} =
      SchedulerRuns.record(
        :rebalance,
        :scheduled,
        @t0,
        DateTime.add(@t0, 1, :second),
        {:ok, %{status: :ok, phase: :copy, job_id: "job-ok"}},
        node: :node_a
      )

    {:ok, _skipped} =
      SchedulerRuns.record(
        :rebalance,
        :scheduled,
        DateTime.add(@t0, 2, :second),
        DateTime.add(@t0, 3, :second),
        {:error, :lock_unavailable},
        node: :node_b
      )

    {:ok, %{run: blocked_run, state: blocked_state}} =
      SchedulerRuns.record(
        :rebalance,
        :scheduled,
        DateTime.add(@t0, 4, :second),
        DateTime.add(@t0, 5, :second),
        {:ok,
         %{
           status: :blocked,
           phase: :rebalance_closure,
           job_id: "job-blocked",
           blockers: [:routing_mismatch],
           next_action: next_action
         }},
        node: :node_c
      )

    assert blocked_run.summary["next_action"] == next_action
    assert blocked_state.last_summary["next_action"] == next_action

    {:ok, report} =
      SchedulerRuns.cadence_report(
        scheduler: :rebalance,
        now: DateTime.add(@t0, 10, :second),
        since_minutes: 1,
        expected_interval_ms: 60_000,
        stale_after_ms: 120_000
      )

    assert [cadence] = report.reports
    assert cadence.scheduled_nodes == ["node_a", "node_b", "node_c"]
    assert cadence.effective_scheduled_nodes == ["node_a", "node_c"]
    assert cadence.healthy_scheduled_nodes == ["node_a"]
    assert cadence.skipped_scheduled_nodes == ["node_b"]
    assert cadence.lock_loser_nodes == ["node_b"]
    assert cadence.lock_loser_count == 1
    assert cadence.last_effective_scheduled_node == "node_c"
  end

  test "cadence ignores future-dated scheduled rows" do
    report_now = DateTime.add(@t0, 10, :second)

    {:ok, _future} =
      SchedulerRuns.record(
        :fresh_drive_heal,
        :scheduled,
        DateTime.add(report_now, 60, :second),
        DateTime.add(report_now, 61, :second),
        {:ok, %{status: :ok}},
        node: :future_node
      )

    {:ok, report} =
      SchedulerRuns.cadence_report(
        scheduler: :fresh_drive_heal,
        now: report_now,
        since_minutes: 10,
        expected_interval_ms: 60_000,
        stale_after_ms: 120_000
      )

    assert [cadence] = report.reports
    assert cadence.health == "not_started"
    assert cadence.scheduled_runs == 0
    assert cadence.scheduled_nodes == []
    refute cadence.last_scheduled_run_id
  end

  test "next_action summary redacts CLI-style sensitive arguments" do
    {:ok, %{run: run, state: state}} =
      SchedulerRuns.record(
        :rebalance,
        :scheduled,
        @t0,
        DateTime.add(@t0, 1, :second),
        {:ok,
         %{
           status: :blocked,
           phase: :rebalance_closure,
           job_id: "job-secret",
           blockers: [:manual_repair],
           next_action: "mix repair --token super-secret-value --access-key AKIASECRET"
         }}
      )

    assert run.summary["next_action"] =~ "--token [REDACTED]"
    assert run.summary["next_action"] =~ "--access-key [REDACTED]"
    refute run.summary["next_action"] =~ "super-secret-value"
    refute run.summary["next_action"] =~ "AKIASECRET"
    refute inspect(state.last_summary) =~ "super-secret-value"
  end

  test "retention is default-off for destructive pruning but dry-run still plans" do
    retention_now = DateTime.add(@t0, 2 * @day_seconds, :second)

    {:ok, %{run: old_run}} =
      SchedulerRuns.record(
        :rebalance,
        :scheduled,
        @t0,
        DateTime.add(@t0, 5, :second),
        {:ok, %{status: :ok}}
      )

    {:ok, _newer} =
      SchedulerRuns.record(
        :rebalance,
        :scheduled,
        DateTime.add(@t0, @day_seconds + 60, :second),
        DateTime.add(@t0, @day_seconds + 65, :second),
        {:ok, %{status: :ok}}
      )

    {:ok, _rollup} =
      SchedulerRuns.rollup(
        scheduler: :rebalance,
        trigger: :scheduled,
        from: @t0,
        until: DateTime.add(@t0, @day_seconds, :second),
        window_ms: @day_ms,
        now: retention_now
      )

    {:ok, plan} =
      SchedulerRuns.retention_plan(
        scheduler: :rebalance,
        trigger: :scheduled,
        retain_days: 1,
        window_ms: @day_ms,
        now: retention_now
      )

    assert plan.status == :preflight
    assert plan.ready?
    assert plan.enabled? == false
    assert plan.cutoff == DateTime.add(@t0, @day_seconds, :second)
    assert plan.candidate_runs == 1
    assert plan.pruned_runs == 0
    assert Repo.get(SchedulerRun, old_run.id)

    assert {:error, :scheduler_ledger_retention_disabled} =
             SchedulerRuns.retention_prune(
               scheduler: :rebalance,
               trigger: :scheduled,
               retain_days: 1,
               window_ms: @day_ms,
               now: retention_now,
               confirm?: true
             )

    assert Repo.get(SchedulerRun, old_run.id)
  end

  test "retention prune delegates deletion to verified prune" do
    retention_now = DateTime.add(@t0, 2 * @day_seconds, :second)

    {:ok, %{run: old_run}} =
      SchedulerRuns.record(
        :fresh_drive_heal,
        :manual,
        @t0,
        DateTime.add(@t0, 5, :second),
        {:ok, %{status: :ok}}
      )

    {:ok, _newer} =
      SchedulerRuns.record(
        :fresh_drive_heal,
        :manual,
        DateTime.add(@t0, @day_seconds + 60, :second),
        DateTime.add(@t0, @day_seconds + 65, :second),
        {:ok, %{status: :ok}}
      )

    {:ok, _rollup} =
      SchedulerRuns.rollup(
        scheduler: :fresh_drive_heal,
        trigger: :manual,
        from: @t0,
        until: DateTime.add(@t0, @day_seconds, :second),
        window_ms: @day_ms,
        now: retention_now
      )

    {:ok, report} =
      SchedulerRuns.retention_prune(
        scheduler: :fresh_drive_heal,
        trigger: :manual,
        retain_days: 1,
        window_ms: @day_ms,
        now: retention_now,
        enabled: true,
        confirm?: true,
        node: :retention_test_node
      )

    assert report.status == :ok
    assert report.ready?
    assert report.enabled?
    assert report.candidate_runs == 1
    assert report.pruned_runs == 1
    refute Repo.get(SchedulerRun, old_run.id)

    [rollup] = SchedulerRuns.list_rollups(scheduler: :fresh_drive_heal, trigger: :manual)
    assert rollup.pruned_run_count == 1
    assert rollup.pruned_by_node == "retention_test_node"
  end

  test "retention reports missing rollups in dry-run and fails closed for prune" do
    retention_now = DateTime.add(@t0, 2 * @day_seconds, :second)

    {:ok, %{run: old_run}} =
      SchedulerRuns.record(
        :rebalance,
        :manual,
        @t0,
        DateTime.add(@t0, 5, :second),
        {:ok, %{status: :ok}}
      )

    {:ok, _newer} =
      SchedulerRuns.record(
        :rebalance,
        :manual,
        DateTime.add(@t0, @day_seconds + 60, :second),
        DateTime.add(@t0, @day_seconds + 65, :second),
        {:ok, %{status: :ok}}
      )

    {:ok, plan} =
      SchedulerRuns.retention_plan(
        scheduler: :rebalance,
        trigger: :manual,
        retain_days: 1,
        window_ms: @day_ms,
        now: retention_now
      )

    assert plan.status == :blocked
    refute plan.ready?
    assert plan.candidate_runs == 1
    assert [missing] = plan.missing_rollups
    assert DateTime.compare(missing.window_started_at, @t0) == :eq
    assert missing.window_ms == @day_ms

    assert {:error, {:missing_retention_rollups, [_missing]}} =
             SchedulerRuns.retention_prune(
               scheduler: :rebalance,
               trigger: :manual,
               retain_days: 1,
               window_ms: @day_ms,
               now: retention_now,
               enabled: true,
               confirm?: true
             )

    assert Repo.get(SchedulerRun, old_run.id)
  end

  test "retention floors non-aligned cutoff and keeps partial cutoff window" do
    retention_now = DateTime.add(@t0, @day_seconds + 90, :second)

    {:ok, %{run: old_run}} =
      SchedulerRuns.record(
        :rebalance,
        :scheduled,
        @t0,
        DateTime.add(@t0, 5, :second),
        {:ok, %{status: :ok}}
      )

    {:ok, %{run: partial_window_run}} =
      SchedulerRuns.record(
        :rebalance,
        :scheduled,
        DateTime.add(@t0, 70, :second),
        DateTime.add(@t0, 75, :second),
        {:ok, %{status: :ok}}
      )

    {:ok, _newer} =
      SchedulerRuns.record(
        :rebalance,
        :scheduled,
        DateTime.add(@t0, @day_seconds + 120, :second),
        DateTime.add(@t0, @day_seconds + 125, :second),
        {:ok, %{status: :ok}}
      )

    {:ok, _rollup} =
      SchedulerRuns.rollup(
        scheduler: :rebalance,
        trigger: :scheduled,
        from: @t0,
        until: DateTime.add(@t0, 60, :second),
        window_ms: 60_000,
        now: retention_now
      )

    {:ok, report} =
      SchedulerRuns.retention_prune(
        scheduler: :rebalance,
        trigger: :scheduled,
        retain_days: 1,
        window_ms: 60_000,
        now: retention_now,
        enabled: true,
        confirm?: true
      )

    assert report.cutoff == DateTime.add(@t0, 60, :second)
    assert report.windows == 1
    assert report.pruned_runs == 1
    refute Repo.get(SchedulerRun, old_run.id)
    assert Repo.get(SchedulerRun, partial_window_run.id)
  end
end
