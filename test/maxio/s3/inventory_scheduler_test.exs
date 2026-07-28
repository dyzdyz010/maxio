defmodule Maxio.S3.InventorySchedulerTest do
  use Maxio.DataCase, async: false

  import ExUnit.CaptureIO

  alias Maxio.S3.Endpoint
  alias Maxio.S3.Inventory
  alias Maxio.S3.Inventory.{ReportRun, ReportRuns, Runner, Scheduler}
  alias Maxio.Test.SigV4Request

  @data_dir Path.join(System.tmp_dir!(), "maxio_inventory_scheduler")
  @now ~U[2026-06-30 12:00:00Z]

  setup do
    File.rm_rf(@data_dir)
    File.mkdir_p!(@data_dir)

    prev_s3 = Application.get_env(:maxio, :s3)
    prev_backend = Application.get_env(:maxio, :storage_backend)
    prev_inventory_scheduler = Application.get_env(:maxio, :inventory_report_scheduler)
    Application.put_env(:maxio, :s3, Keyword.put(prev_s3, :data_dir, @data_dir))
    Mix.Task.reenable("maxio.inventory.schedule")

    on_exit(fn ->
      Application.put_env(:maxio, :s3, prev_s3)
      Application.put_env(:maxio, :storage_backend, prev_backend)
      Application.put_env(:maxio, :inventory_report_scheduler, prev_inventory_scheduler)
      File.rm_rf(@data_dir)
      Mix.Task.reenable("maxio.inventory.schedule")
    end)

    :ok
  end

  test "runner writes one due report per report date and skips completed reruns" do
    assert create_bucket("sched-src") == 200
    assert create_bucket("sched-dest") == 200
    assert put_object("sched-src", "docs/a.txt", "alpha") == 200

    put_inventory_config!("sched-src", daily_config("sched-dest"))

    first =
      Runner.run_due(
        bucket: "sched-src",
        id: "daily",
        now: @now,
        report_date: ~D[2026-06-30]
      )

    assert first.errors == []
    assert first.claims_created == 1
    assert first.reports_written == 1
    assert first.rows_written == 1
    assert [%{status: "ok", report_date: ~D[2026-06-30], manifest_key: manifest_key}] = first.runs
    assert is_binary(manifest_key)

    run = ReportRuns.get("sched-src", "daily", ~D[2026-06-30])
    assert %ReportRun{status: "ok", attempts: 1, run_id: run_id, file_id: file_id} = run
    assert is_binary(run_id)
    assert file_id == run_id

    second =
      Runner.run_due(
        bucket: "sched-src",
        id: "daily",
        now: @now,
        report_date: ~D[2026-06-30]
      )

    assert second.errors == []
    assert second.claims_created == 0
    assert second.claims_skipped_completed == 1
    assert second.reports_written == 0

    next_day =
      Runner.run_due(
        bucket: "sched-src",
        id: "daily",
        now: DateTime.add(@now, 86_400, :second),
        report_date: ~D[2026-07-01]
      )

    assert next_day.errors == []
    assert next_day.claims_created == 1
    assert next_day.reports_written == 1
    assert %ReportRun{status: "ok"} = ReportRuns.get("sched-src", "daily", ~D[2026-07-01])
  end

  test "unsupported format is recorded once as skipped until config changes" do
    assert create_bucket("sched-orc") == 200
    assert create_bucket("sched-orc-dest") == 200

    put_inventory_config!(
      "sched-orc",
      daily_config("sched-orc-dest")
      |> put_in(["Destination", "S3BucketDestination", "Format"], "ORC")
    )

    first =
      Runner.run_due(
        bucket: "sched-orc",
        id: "daily",
        now: @now,
        report_date: ~D[2026-06-30]
      )

    assert first.errors == []
    assert first.claims_created == 1
    assert first.reports_written == 0

    assert %ReportRun{status: "skipped", error_reason: "unsupported_format"} =
             ReportRuns.get("sched-orc", "daily", ~D[2026-06-30])

    second =
      Runner.run_due(
        bucket: "sched-orc",
        id: "daily",
        now: @now,
        report_date: ~D[2026-06-30]
      )

    assert second.claims_created == 0
    assert second.claims_skipped_unchanged == 1
  end

  test "failed run can retry same report date with stable run and file ids" do
    assert create_bucket("sched-fail") == 200
    assert create_bucket("sched-fail-dest") == 200
    assert put_object("sched-fail", "docs/a.txt", "alpha") == 200

    put_inventory_config!("sched-fail", daily_config("sched-fail-dest"))

    with_storage_backend(Maxio.Test.StorageInventoryManifestFailBackend, fn ->
      failed =
        Runner.run_due(
          bucket: "sched-fail",
          id: "daily",
          now: @now,
          report_date: ~D[2026-06-30]
        )

      assert failed.errors != []
    end)

    failed_run = ReportRuns.get("sched-fail", "daily", ~D[2026-06-30])

    assert %ReportRun{status: "failed", attempts: 1, run_id: run_id, file_id: file_id} =
             failed_run

    retry =
      Runner.run_due(
        bucket: "sched-fail",
        id: "daily",
        now: DateTime.add(@now, 60, :second),
        report_date: ~D[2026-06-30]
      )

    assert retry.errors == []
    assert retry.claims_created == 1
    assert retry.reports_written == 1

    completed = ReportRuns.get("sched-fail", "daily", ~D[2026-06-30])
    assert %ReportRun{status: "ok", attempts: 2, run_id: ^run_id, file_id: ^file_id} = completed
  end

  test "weekly schedules use the most recent UTC Sunday as report date" do
    assert create_bucket("sched-weekly") == 200
    assert create_bucket("sched-weekly-dest") == 200
    assert put_object("sched-weekly", "docs/a.txt", "alpha") == 200

    put_inventory_config!("sched-weekly", weekly_config("sched-weekly-dest"))

    summary =
      Runner.run_due(
        bucket: "sched-weekly",
        id: "weekly",
        now: ~U[2026-06-29 10:00:00Z]
      )

    assert summary.errors == []
    assert [%{report_date: ~D[2026-06-28]}] = summary.runs
    assert %ReportRun{status: "ok"} = ReportRuns.get("sched-weekly", "weekly", ~D[2026-06-28])
  end

  test "ledger completion is fenced by claimed attempt and lease" do
    attrs =
      claim_attrs("ledger-stale", "daily", ~D[2026-06-30],
        now: @now,
        lease_ms: 1
      )

    assert {:ok, first} = ReportRuns.claim(attrs)

    reclaimed_now = DateTime.add(@now, 1, :second)

    assert {:ok, second} =
             attrs
             |> Map.put(:now, reclaimed_now)
             |> Map.put(:lease_ms, 60_000)
             |> ReportRuns.claim()

    assert second.attempts == 2

    assert {:ok, completed} =
             ReportRuns.complete(
               second,
               completed_report_summary(),
               second.started_at,
               DateTime.add(second.started_at, 1, :second)
             )

    assert completed.status == "ok"

    assert {:skip, :stale_completion, current} =
             ReportRuns.complete(
               first,
               failed_report_summary(),
               first.started_at,
               DateTime.add(first.started_at, 2, :second)
             )

    assert current.status == "ok"
    assert current.attempts == 2
    assert ReportRuns.get("ledger-stale", "daily", ~D[2026-06-30]).status == "ok"
  end

  test "concurrent first claims collapse to one running row" do
    attrs = claim_attrs("ledger-race", "daily", ~D[2026-06-30], now: @now)
    parent = self()

    tasks =
      for _ <- 1..2 do
        Task.async(fn ->
          send(parent, {:ready, self()})

          receive do
            :go -> ReportRuns.claim(attrs)
          after
            5_000 -> flunk("claim task was not released")
          end
        end)
      end

    Enum.each(tasks, fn task ->
      Ecto.Adapters.SQL.Sandbox.allow(Maxio.Repo, self(), task.pid)
      pid = task.pid
      assert_receive {:ready, ^pid}
    end)

    Enum.each(tasks, &send(&1.pid, :go))
    results = Enum.map(tasks, &Task.await(&1, 10_000))

    assert Enum.count(results, &match?({:ok, %ReportRun{}}, &1)) == 1
    assert Enum.count(results, &match?({:skip, :running, %ReportRun{}}, &1)) == 1
  end

  test "scheduler starts disabled and run_now invokes configured runner" do
    parent = self()

    runner = fn opts ->
      send(parent, {:runner_started, self(), opts})

      receive do
        :finish -> scheduler_summary(%{configs_due: 1})
      after
        5_000 -> scheduler_summary(%{errors: [%{reason: "timeout"}]})
      end
    end

    pid = start_supervised!({Scheduler, name: nil, enabled: false, runner: runner})
    task = Task.async(fn -> Scheduler.run_now(pid, bucket: "manual") end)

    assert_receive {:runner_started, runner_pid, opts}
    assert %{enabled: false, scheduled?: false, running?: true} = Scheduler.status(pid)
    assert Keyword.get(opts, :bucket) == "manual"
    assert Keyword.get(opts, :trigger) == :manual

    send(runner_pid, :finish)

    assert {:ok, summary} = Task.await(task)
    assert summary.configs_due == 1
    assert %{running?: false, last_result: {:ok, %{configs_due: 1}}} = Scheduler.status(pid)
  end

  test "scheduler rejects overlapping manual run while a pass is in flight" do
    parent = self()

    runner = fn opts ->
      send(parent, {:runner_blocked, self(), opts})

      receive do
        :finish -> scheduler_summary(%{configs_due: 1})
      after
        5_000 -> scheduler_summary(%{errors: [%{reason: "timeout"}]})
      end
    end

    pid = start_supervised!({Scheduler, name: nil, enabled: false, runner: runner})
    task = Task.async(fn -> Scheduler.run_now(pid, bucket: "first") end)

    assert_receive {:runner_blocked, runner_pid, _opts}
    assert {:error, {:already_running, :manual}} = Scheduler.run_now(pid, bucket: "second")

    send(runner_pid, :finish)
    assert {:ok, summary} = Task.await(task)
    assert summary.configs_due == 1
  end

  test "scheduler clears running state if worker receives an exit signal" do
    parent = self()

    runner = fn _opts ->
      send(parent, {:runner_waiting, self()})

      receive do
        :finish -> scheduler_summary(%{configs_due: 1})
      after
        5_000 -> scheduler_summary(%{errors: [%{reason: "timeout"}]})
      end
    end

    pid = start_supervised!({Scheduler, name: nil, enabled: false, runner: runner})
    task = Task.async(fn -> Scheduler.run_now(pid, bucket: "manual") end)

    assert_receive {:runner_waiting, runner_pid}
    Process.exit(runner_pid, :kill)

    assert {:error, {:caught, :exit, :killed}} = Task.await(task)

    assert %{running?: false, last_result: {:error, {:caught, :exit, :killed}}} =
             Scheduler.status(pid)
  end

  test "scheduler starts disabled and run_now invokes configured runner legacy summary" do
    parent = self()

    runner = fn opts ->
      send(parent, {:runner_called, opts})
      scheduler_summary(%{configs_due: 1})
    end

    pid = start_supervised!({Scheduler, name: nil, enabled: false, runner: runner})

    assert %{enabled: false, scheduled?: false, running?: false} = Scheduler.status(pid)
    assert {:ok, summary} = Scheduler.run_now(pid, bucket: "manual")
    assert summary.configs_due == 1
    assert_receive {:runner_called, opts}
    assert Keyword.get(opts, :bucket) == "manual"
    assert Keyword.get(opts, :trigger) == :manual
  end

  test "enabled scheduler tick uses scheduled trigger and reschedules" do
    parent = self()

    runner = fn opts ->
      send(parent, {:scheduled_runner_called, opts})
      scheduler_summary(%{configs_due: 1})
    end

    pid =
      start_supervised!(
        {Scheduler,
         name: nil,
         enabled: true,
         singleton?: false,
         initial_delay_ms: 60_000,
         interval_ms: 60_000,
         runner: runner}
      )

    token = :sys.get_state(pid).timer_token
    send(pid, {:run_due, token})
    _ = :sys.get_state(pid)

    assert_receive {:scheduled_runner_called, opts}
    assert Keyword.get(opts, :trigger) == :scheduled
    assert %{scheduled?: true, last_result: {:ok, %{configs_due: 1}}} = Scheduler.status(pid)
  end

  test "mix schedule task prints json dry-run summary without claiming ledger" do
    assert create_bucket("sched-task") == 200
    assert create_bucket("sched-task-dest") == 200

    put_inventory_config!("sched-task", daily_config("sched-task-dest"))

    output =
      capture_io(fn ->
        Mix.Task.run("maxio.inventory.schedule", [
          "--bucket",
          "sched-task",
          "--id",
          "daily",
          "--report-date",
          "2026-06-30",
          "--dry-run",
          "--json"
        ])
      end)

    decoded = Jason.decode!(output)
    assert decoded["dry_run"] == true
    assert decoded["configs_due"] == 1
    assert decoded["claims_created"] == 0

    assert decoded["runs"] == [
             %{
               "bucket" => "sched-task",
               "inventory_id" => "daily",
               "report_date" => "2026-06-30",
               "status" => "dry_run"
             }
           ]

    assert ReportRuns.get("sched-task", "daily", ~D[2026-06-30]) == nil
  end

  test "mix schedule dry-run restores enabled scheduler config without claiming ledger" do
    Application.put_env(:maxio, :inventory_report_scheduler,
      enabled: true,
      initial_delay_ms: 0,
      interval_ms: 60_000
    )

    assert create_bucket("sched-dry-config") == 200
    assert create_bucket("sched-dry-config-dest") == 200

    put_inventory_config!("sched-dry-config", daily_config("sched-dry-config-dest"))

    output =
      capture_io(fn ->
        Mix.Task.run("maxio.inventory.schedule", [
          "--bucket",
          "sched-dry-config",
          "--id",
          "daily",
          "--report-date",
          "2026-06-30",
          "--dry-run",
          "--json"
        ])
      end)

    assert Jason.decode!(output)["dry_run"] == true
    assert Application.get_env(:maxio, :inventory_report_scheduler)[:enabled] == true
    assert ReportRuns.get("sched-dry-config", "daily", ~D[2026-06-30]) == nil
  end

  defp call(conn), do: Endpoint.call(conn, Endpoint.init([]))

  defp create_bucket(bucket) do
    SigV4Request.signed_conn(:put, "/#{bucket}") |> call() |> Map.fetch!(:status)
  end

  defp put_object(bucket, key, body) do
    SigV4Request.signed_conn(:put, "/#{bucket}/#{key}", body: body)
    |> call()
    |> Map.fetch!(:status)
  end

  defp put_inventory_config!(bucket, config), do: :ok = Inventory.put_config(bucket, config)

  defp daily_config(destination_bucket) do
    %{
      "Id" => "daily",
      "Destination" => destination(destination_bucket),
      "IsEnabled" => true,
      "Filter" => %{"Prefix" => "docs/"},
      "IncludedObjectVersions" => "Current",
      "Schedule" => %{"Frequency" => "Daily"}
    }
  end

  defp weekly_config(destination_bucket) do
    %{
      "Id" => "weekly",
      "Destination" => destination(destination_bucket),
      "IsEnabled" => true,
      "Filter" => %{"Prefix" => "docs/"},
      "IncludedObjectVersions" => "Current",
      "Schedule" => %{"Frequency" => "Weekly"}
    }
  end

  defp destination(bucket) do
    %{
      "S3BucketDestination" => %{
        "Bucket" => "arn:aws:s3:::" <> bucket,
        "Format" => "CSV",
        "Prefix" => "reports/"
      }
    }
  end

  defp scheduler_summary(overrides) do
    Map.merge(
      %{
        dry_run: false,
        trigger: :manual,
        buckets_scanned: 0,
        configs_seen: 0,
        configs_due: 0,
        configs_skipped_disabled: 0,
        claims_created: 0,
        claims_skipped_completed: 0,
        claims_skipped_running: 0,
        claims_skipped_unchanged: 0,
        reports_written: 0,
        objects_written: 0,
        rows_written: 0,
        runs: [],
        errors: []
      },
      overrides
    )
  end

  defp claim_attrs(bucket, inventory_id, report_date, opts) do
    now = Keyword.fetch!(opts, :now)

    %{
      bucket: bucket,
      inventory_id: inventory_id,
      report_date: report_date,
      frequency: "Daily",
      config: daily_config("ledger-dest"),
      trigger: :manual,
      now: now,
      lease_ms: Keyword.get(opts, :lease_ms, 60_000)
    }
  end

  defp completed_report_summary do
    %{
      dry_run: false,
      reports_written: 1,
      objects_written: 4,
      rows_written: 1,
      reports: [
        %{
          manifest_key: "reports/manifest.json",
          data_key: "reports/data.csv.gz",
          checksum_key: "reports/manifest.checksum",
          symlink_key: "reports/symlink.txt",
          rows: 1,
          objects_written: 4
        }
      ],
      errors: []
    }
  end

  defp failed_report_summary do
    %{
      dry_run: false,
      reports_written: 0,
      objects_written: 0,
      rows_written: 0,
      reports: [],
      errors: [%{reason: "stale failure"}]
    }
  end

  defp with_storage_backend(backend, fun) do
    previous = Application.get_env(:maxio, :storage_backend)
    Application.put_env(:maxio, :storage_backend, backend)

    try do
      fun.()
    after
      Application.put_env(:maxio, :storage_backend, previous)
    end
  end
end
