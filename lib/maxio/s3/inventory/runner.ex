defmodule Maxio.S3.Inventory.Runner do
  @moduledoc """
  Due-report runner for S3 Inventory automatic schedules.

  This module computes the current report date for `Daily` and `Weekly`
  configurations, claims the persistent report-run ledger, and then delegates
  all object writing to `Maxio.S3.Inventory.Report`.
  """

  require Logger

  alias Maxio.Buckets
  alias Maxio.S3.Inventory
  alias Maxio.S3.Inventory.{Report, ReportRuns}

  @default_max_keys 1_000
  @default_lease_ms 3_600_000
  @run_option_keys [:max_keys, :tmp_dir, :storage_opts]

  @type run_due_opts :: [
          bucket: String.t(),
          id: String.t(),
          now: DateTime.t(),
          report_date: Date.t() | String.t(),
          trigger: :manual | :scheduled,
          lease_ms: pos_integer(),
          dry_run: boolean(),
          max_keys: pos_integer(),
          tmp_dir: Path.t(),
          storage_opts: keyword()
        ]

  @spec run_due(run_due_opts()) :: map()
  def run_due(opts \\ []) do
    opts = normalize_opts(opts)

    opts.bucket
    |> bucket_names()
    |> Enum.reduce(new_summary(opts), fn bucket, summary -> run_bucket(bucket, summary, opts) end)
  end

  defp normalize_opts(opts) do
    now = Keyword.get(opts, :now) || DateTime.utc_now()

    %{
      bucket: blank_to_nil(Keyword.get(opts, :bucket)),
      id: blank_to_nil(Keyword.get(opts, :id)),
      now: now,
      report_date: normalize_report_date(Keyword.get(opts, :report_date)),
      trigger: Keyword.get(opts, :trigger, :manual),
      lease_ms: positive_integer(Keyword.get(opts, :lease_ms), @default_lease_ms),
      dry_run: Keyword.get(opts, :dry_run, false),
      max_keys: positive_integer(Keyword.get(opts, :max_keys), @default_max_keys),
      tmp_dir: Keyword.get(opts, :tmp_dir),
      storage_opts: Keyword.get(opts, :storage_opts, [])
    }
  end

  defp bucket_names(nil), do: Buckets.list() |> Enum.map(& &1.name)
  defp bucket_names(bucket), do: [bucket]

  defp new_summary(opts) do
    %{
      dry_run: opts.dry_run,
      trigger: opts.trigger,
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
    }
  end

  defp run_bucket(bucket, summary, opts) do
    case Buckets.lookup(bucket) do
      {:ok, _bucket} ->
        configs =
          bucket
          |> Inventory.all_configs()
          |> maybe_filter_id(opts.id)

        summary =
          summary
          |> inc(:buckets_scanned)
          |> inc(:configs_seen, length(configs))

        summary =
          if opts.id && configs == [] do
            add_error(summary, bucket, opts.id, :inventory_config_not_found)
          else
            summary
          end

        Enum.reduce(configs, summary, fn config, acc -> run_config(bucket, config, acc, opts) end)

      {:error, :not_found} ->
        add_error(summary, bucket, opts.id, :source_bucket_missing)
    end
  rescue
    err -> add_error(summary, bucket, opts.id, err)
  end

  defp maybe_filter_id(configs, nil), do: configs
  defp maybe_filter_id(configs, id), do: Enum.filter(configs, &(&1["Id"] == id))

  defp run_config(bucket, raw_config, summary, opts) do
    config = Inventory.normalize_config(raw_config)
    inventory_id = config["Id"]

    cond do
      not config["IsEnabled"] ->
        inc(summary, :configs_skipped_disabled)

      not due_for_frequency?(config["Schedule"]["Frequency"], opts.now, opts.report_date) ->
        summary

      opts.dry_run ->
        summary
        |> inc(:configs_due)
        |> append_run(%{
          bucket: bucket,
          inventory_id: inventory_id,
          report_date: due_report_date(config, opts),
          status: "dry_run"
        })

      true ->
        run_due_config(bucket, config, summary |> inc(:configs_due), opts)
    end
  end

  defp run_due_config(bucket, config, summary, opts) do
    inventory_id = config["Id"]
    frequency = config["Schedule"]["Frequency"]
    report_date = due_report_date(config, opts)
    config_hash = ReportRuns.config_hash(config)

    claim_attrs = %{
      bucket: bucket,
      inventory_id: inventory_id,
      report_date: report_date,
      frequency: frequency,
      config: config,
      config_hash: config_hash,
      trigger: opts.trigger,
      now: opts.now,
      lease_ms: opts.lease_ms
    }

    case ReportRuns.claim(claim_attrs) do
      {:ok, run} ->
        execute_claimed_run(run, bucket, inventory_id, report_date, summary, opts)

      {:skip, :already_completed, run} ->
        summary
        |> inc(:claims_skipped_completed)
        |> append_run(run_summary(run, :already_completed))

      {:skip, :already_skipped, run} ->
        summary
        |> inc(:claims_skipped_unchanged)
        |> append_run(run_summary(run, :already_skipped))

      {:skip, :running, run} ->
        summary
        |> inc(:claims_skipped_running)
        |> append_run(run_summary(run, :running))

      {:error, reason} ->
        add_error(summary, bucket, inventory_id, reason)
    end
  end

  defp execute_claimed_run(run, bucket, inventory_id, report_date, summary, opts) do
    started_at = opts.now

    try do
      report_now = DateTime.new!(report_date, ~T[00:00:00], "Etc/UTC")

      report_opts =
        opts
        |> Map.take(@run_option_keys)
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Keyword.new()
        |> Keyword.merge(
          bucket: bucket,
          id: inventory_id,
          now: report_now,
          run_id: run.run_id,
          file_id: run.file_id
        )

      report_summary = Report.run(report_opts)
      finished_at = DateTime.utc_now()

      case ReportRuns.complete(run, report_summary, started_at, finished_at) do
        {:ok, completed} ->
          summary
          |> inc(:claims_created)
          |> inc(:reports_written, report_summary.reports_written)
          |> inc(:objects_written, report_summary.objects_written)
          |> inc(:rows_written, report_summary.rows_written)
          |> append_run(run_summary(completed, :completed))
          |> append_report_errors(report_summary.errors)

        {:error, reason} ->
          add_error(summary, bucket, inventory_id, reason)

        {:skip, :stale_completion, stale_run} ->
          stale_run = stale_run || run

          summary
          |> append_run(run_summary(stale_run, :stale_completion))
      end
    rescue
      err ->
        finished_at = DateTime.utc_now()
        failed = report_error_summary(err)
        _ = ReportRuns.complete(run, failed, started_at, finished_at)
        add_error(summary, bucket, inventory_id, err)
    catch
      kind, reason ->
        finished_at = DateTime.utc_now()
        failed = report_error_summary({kind, reason})
        _ = ReportRuns.complete(run, failed, started_at, finished_at)
        add_error(summary, bucket, inventory_id, {kind, reason})
    end
  end

  defp due_for_frequency?(_frequency, _now, %Date{}), do: true
  defp due_for_frequency?("Daily", _now, nil), do: true
  defp due_for_frequency?("Weekly", _now, nil), do: true
  defp due_for_frequency?(_frequency, _now, _report_date), do: false

  defp due_report_date(_config, %{report_date: %Date{} = report_date}), do: report_date

  defp due_report_date(%{"Schedule" => %{"Frequency" => "Weekly"}}, opts) do
    date = DateTime.to_date(opts.now)
    Date.add(date, -rem(Date.day_of_week(date), 7))
  end

  defp due_report_date(_config, opts), do: DateTime.to_date(opts.now)

  defp run_summary(run, reason) do
    %{
      bucket: run.bucket,
      inventory_id: run.inventory_id,
      report_date: run.report_date,
      status: run.status,
      reason: reason,
      attempts: run.attempts,
      run_id: run.run_id,
      file_id: run.file_id,
      manifest_key: run.manifest_key,
      data_key: run.data_key,
      rows_written: run.rows_written,
      objects_written: run.objects_written
    }
  end

  defp report_error_summary(reason) do
    %{
      dry_run: false,
      reports_written: 0,
      objects_written: 0,
      rows_written: 0,
      reports: [],
      errors: [%{reason: format_reason(reason)}]
    }
  end

  defp append_report_errors(summary, []), do: summary

  defp append_report_errors(summary, errors) do
    Map.update!(summary, :errors, &(&1 ++ errors))
  end

  defp append_run(summary, run), do: Map.update!(summary, :runs, &(&1 ++ [run]))
  defp inc(summary, key, amount \\ 1), do: Map.update!(summary, key, &(&1 + amount))

  defp add_error(summary, bucket, inventory_id, reason) do
    Logger.error("inventory scheduled report failed",
      action: :inventory_report_scheduler,
      bucket: bucket,
      configuration_id: inventory_id,
      reason: format_reason(reason)
    )

    error = %{bucket: bucket, inventory_id: inventory_id, reason: format_reason(reason)}
    Map.update!(summary, :errors, &(&1 ++ [error]))
  end

  defp normalize_report_date(nil), do: nil
  defp normalize_report_date(%Date{} = date), do: date

  defp normalize_report_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      {:error, _reason} -> nil
    end
  end

  defp normalize_report_date(_value), do: nil

  defp format_reason(%{__struct__: _} = err) do
    Exception.message(err)
  rescue
    _other -> inspect(err)
  end

  defp format_reason(reason), do: inspect(reason)

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value, default), do: default
end
