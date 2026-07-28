defmodule Mix.Tasks.Maxio.Inventory.Schedule do
  @shortdoc "Run due S3 Inventory report schedules"
  @moduledoc """
  Runs one due S3 Inventory schedule pass through the persistent report ledger.

      mix maxio.inventory.schedule
      mix maxio.inventory.schedule --bucket photos --id daily
      mix maxio.inventory.schedule --report-date 2026-06-30 --json
      mix maxio.inventory.schedule --dry-run

  This task is idempotent for each `{bucket, inventory_id, report_date}`. Use
  `mix maxio.inventory.run` when an explicit force-run outside the scheduler
  ledger is required.
  """

  use Mix.Task

  alias Maxio.S3.Inventory.Runner
  alias Maxio.S3.Inventory.Scheduler

  @impl true
  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          bucket: :string,
          id: :string,
          report_date: :string,
          dry_run: :boolean,
          max_keys: :integer,
          json: :boolean
        ],
        aliases: [b: :bucket]
      )

    if rest != [] or invalid != [] do
      unexpected = rest ++ Enum.map(invalid, &elem(&1, 0))

      Mix.raise(
        "usage: mix maxio.inventory.schedule [--bucket BUCKET] [--id ID] " <>
          "[--report-date YYYY-MM-DD] [--dry-run] [--max-keys N] [--json] " <>
          "(unexpected: #{inspect(unexpected)})"
      )
    end

    validate_opts!(opts)
    dry_run? = Keyword.get(opts, :dry_run, false)

    with_inventory_scheduler_disabled(dry_run?, fn ->
      Mix.Task.run("app.start")
      ensure_dry_run_scheduler_not_enabled!(dry_run?)

      summary =
        Runner.run_due(
          []
          |> maybe_put(:bucket, Keyword.get(opts, :bucket))
          |> maybe_put(:id, Keyword.get(opts, :id))
          |> maybe_put(:report_date, Keyword.get(opts, :report_date))
          |> maybe_put(:max_keys, Keyword.get(opts, :max_keys))
          |> Keyword.put(:trigger, :manual)
          |> Keyword.put(:dry_run, dry_run?)
        )

      print_summary(summary, opts)

      if summary.errors != [] do
        Mix.raise("inventory schedule run failed with #{length(summary.errors)} errors")
      end
    end)
  end

  defp validate_opts!(opts) do
    if Keyword.get(opts, :id) not in [nil, ""] and Keyword.get(opts, :bucket) in [nil, ""] do
      Mix.raise("--id requires --bucket")
    end

    validate_report_date!(Keyword.get(opts, :report_date))
    validate_max_keys!(Keyword.get(opts, :max_keys))
  end

  defp validate_report_date!(nil), do: :ok

  defp validate_report_date!(date) do
    case Date.from_iso8601(date) do
      {:ok, _date} -> :ok
      {:error, _reason} -> Mix.raise("--report-date must be YYYY-MM-DD, got #{inspect(date)}")
    end
  end

  defp validate_max_keys!(nil), do: :ok
  defp validate_max_keys!(value) when is_integer(value) and value > 0, do: :ok

  defp validate_max_keys!(value),
    do: Mix.raise("--max-keys must be a positive integer, got #{inspect(value)}")

  defp print_summary(summary, opts) do
    if Keyword.get(opts, :json, false) do
      IO.puts(Jason.encode!(summary))
    else
      print_text(summary)
    end
  end

  defp print_text(summary) do
    mode = if summary.dry_run, do: "dry-run", else: "write"

    IO.puts(
      "[maxio inventory.schedule] mode=#{mode} buckets=#{summary.buckets_scanned} " <>
        "configs_seen=#{summary.configs_seen} due=#{summary.configs_due} " <>
        "claims=#{summary.claims_created} completed_skips=#{summary.claims_skipped_completed} " <>
        "running_skips=#{summary.claims_skipped_running} unchanged_skips=#{summary.claims_skipped_unchanged} " <>
        "written=#{summary.reports_written} objects_written=#{summary.objects_written} " <>
        "rows=#{summary.rows_written} errors=#{length(summary.errors)}"
    )

    Enum.each(summary.runs, fn run ->
      IO.puts(
        "[maxio inventory.schedule] run bucket=#{safe(run.bucket)} id=#{safe(run.inventory_id)} " <>
          "date=#{safe(run.report_date)} status=#{safe(run.status)} reason=#{safe(run.reason)} " <>
          "manifest=#{safe(run.manifest_key)} data=#{safe(run.data_key)}"
      )
    end)

    Enum.each(summary.errors, fn error ->
      IO.puts(
        "[maxio inventory.schedule] error bucket=#{safe(Map.get(error, :bucket))} " <>
          "id=#{safe(Map.get(error, :inventory_id))} reason=#{safe(Map.get(error, :reason))}"
      )
    end)
  end

  defp with_inventory_scheduler_disabled(false, fun), do: fun.()

  defp with_inventory_scheduler_disabled(true, fun) do
    previous = Application.get_env(:maxio, :inventory_report_scheduler, [])

    Application.put_env(
      :maxio,
      :inventory_report_scheduler,
      Keyword.put(previous, :enabled, false)
    )

    try do
      fun.()
    after
      Application.put_env(:maxio, :inventory_report_scheduler, previous)
    end
  end

  defp ensure_dry_run_scheduler_not_enabled!(false), do: :ok

  defp ensure_dry_run_scheduler_not_enabled!(true) do
    case Process.whereis(Scheduler) do
      nil ->
        :ok

      pid ->
        if Scheduler.status(pid).enabled do
          Mix.raise("--dry-run refuses to run while inventory_report_scheduler is enabled")
        end
    end
  end

  defp safe(nil), do: inspect("")
  defp safe(value), do: inspect(to_string(value), printable_limit: 200)

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
