defmodule Mix.Tasks.Maxio.Inventory.Run do
  @shortdoc "Generate S3 Inventory report objects"
  @moduledoc """
  Runs one local S3 Inventory report generation sweep.

      mix maxio.inventory.run
      mix maxio.inventory.run --bucket photos
      mix maxio.inventory.run --bucket photos --id daily --report-date 2026-06-30
      mix maxio.inventory.run --bucket photos --dry-run
      mix maxio.inventory.run --json

  The task writes CSV inventory data as `.csv.gz` objects plus the matching
  `manifest.json` and `manifest.checksum` objects into each enabled
  InventoryConfiguration destination bucket. ORC and Parquet destinations are
  reported as unsupported and skipped.
  """

  use Mix.Task

  alias Maxio.S3.Inventory.Report

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
        "usage: mix maxio.inventory.run [--bucket BUCKET] [--id ID] " <>
          "[--report-date YYYY-MM-DD] [--dry-run] [--max-keys N] [--json] " <>
          "(unexpected: #{inspect(unexpected)})"
      )
    end

    validate_opts!(opts)
    Mix.Task.run("app.start")

    summary =
      Report.run(
        []
        |> maybe_put(:bucket, Keyword.get(opts, :bucket))
        |> maybe_put(:id, Keyword.get(opts, :id))
        |> maybe_put(:now, report_datetime(opts))
        |> maybe_put(:max_keys, Keyword.get(opts, :max_keys))
        |> Keyword.put(:dry_run, Keyword.get(opts, :dry_run, false))
      )

    print_summary(summary, opts)

    if summary.errors != [] do
      Mix.raise("inventory report run failed with #{length(summary.errors)} errors")
    end
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

  defp report_datetime(opts) do
    case Keyword.get(opts, :report_date) do
      nil ->
        nil

      date ->
        {:ok, parsed} = Date.from_iso8601(date)
        DateTime.new!(parsed, ~T[00:00:00], "Etc/UTC")
    end
  end

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
      "[maxio inventory] mode=#{mode} buckets=#{summary.buckets_scanned} " <>
        "configs=#{summary.configs_matched}/#{summary.configs_seen} " <>
        "disabled=#{summary.configs_skipped_disabled} " <>
        "unsupported_format=#{summary.configs_unsupported_format} " <>
        "attempted=#{summary.reports_attempted} written=#{summary.reports_written} " <>
        "objects_written=#{summary.objects_written} rows=#{summary.rows_written} " <>
        "errors=#{length(summary.errors)}"
    )

    Enum.each(summary.reports, fn report ->
      IO.puts(
        "[maxio inventory] report bucket=#{safe(report.source_bucket)} " <>
          "id=#{safe(report.inventory_id)} destination=#{safe(report.destination_bucket)} " <>
          "rows=#{report.rows} manifest=#{safe(report.manifest_key)} data=#{safe(report.data_key)}"
      )
    end)

    Enum.each(summary.errors, fn error ->
      IO.puts(
        "[maxio inventory] error bucket=#{safe(error.bucket)} id=#{safe(error.inventory_id)} " <>
          "reason=#{safe(error.reason)}"
      )
    end)
  end

  defp safe(nil), do: inspect("")
  defp safe(value), do: inspect(to_string(value), printable_limit: 200)

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
