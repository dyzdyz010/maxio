defmodule Maxio.S3.Inventory.ReportRuns do
  @moduledoc """
  Persistent idempotency ledger for scheduled S3 Inventory reports.

  One row is kept per `{bucket, inventory_id, report_date}`. A successful row is
  terminal for that report date; failed rows may be reclaimed, and skipped rows
  are terminal only while the normalized configuration hash stays unchanged.
  """

  import Ecto.Query

  alias Maxio.Repo
  alias Maxio.S3.Inventory
  alias Maxio.S3.Inventory.ReportRun

  @default_lease_ms 3_600_000
  @summary_report_keys [
    :source_bucket,
    :inventory_id,
    :destination_bucket,
    :manifest_key,
    :data_key,
    :rows,
    :objects_written
  ]
  @complete_update_fields [
    :status,
    :lease_until,
    :finished_at,
    :duration_ms,
    :manifest_key,
    :data_key,
    :checksum_key,
    :symlink_key,
    :rows_written,
    :objects_written,
    :summary,
    :error_reason
  ]

  @type claim_result ::
          {:ok, ReportRun.t()}
          | {:skip, :already_completed | :already_skipped | :running, ReportRun.t()}
          | {:error, term()}

  @spec claim(map(), keyword()) :: claim_result()
  def claim(attrs, opts \\ []) when is_map(attrs) do
    repo = Keyword.get(opts, :repo, Repo)
    now = Map.fetch!(attrs, :now)
    lease_ms = positive_integer(Map.get(attrs, :lease_ms), @default_lease_ms)

    attrs =
      attrs
      |> Map.put(
        :config_hash,
        Map.get(attrs, :config_hash) || config_hash(Map.fetch!(attrs, :config))
      )
      |> Map.put(:lease_until, DateTime.add(now, lease_ms, :millisecond))
      |> Map.put_new_lazy(:run_id, fn -> stable_run_id(attrs) end)
      |> Map.put_new_lazy(:file_id, fn -> stable_file_id(attrs) end)

    case repo.transaction(fn -> do_claim(repo, attrs) end) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, {:inventory_report_claim_failed, Exception.message(error)}}
  end

  @spec complete(ReportRun.t(), map(), DateTime.t(), DateTime.t(), keyword()) ::
          {:ok, ReportRun.t()}
          | {:skip, :stale_completion, ReportRun.t() | nil}
          | {:error, term()}
  def complete(%ReportRun{} = run, summary, started_at, finished_at, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)
    status = status_for_summary(summary)
    report = first_report(summary)

    attrs = %{
      status: status,
      lease_until: nil,
      finished_at: finished_at,
      duration_ms: duration_ms(started_at, finished_at),
      manifest_key: report && Map.get(report, :manifest_key),
      data_key: report && Map.get(report, :data_key),
      checksum_key: report && Map.get(report, :checksum_key),
      symlink_key: report && Map.get(report, :symlink_key),
      rows_written: Map.get(summary, :rows_written, 0),
      objects_written: Map.get(summary, :objects_written, 0),
      summary: summary_payload(summary),
      error_reason: error_reason(summary, status)
    }

    changeset = ReportRun.changeset(run, attrs)

    if changeset.valid? do
      complete_claim(repo, run, changeset)
    else
      {:error, changeset}
    end
  rescue
    error -> {:error, {:inventory_report_complete_failed, Exception.message(error)}}
  end

  @spec get(String.t(), String.t(), Date.t(), keyword()) :: ReportRun.t() | nil
  def get(bucket, inventory_id, %Date{} = report_date, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)
    repo.get_by(ReportRun, bucket: bucket, inventory_id: inventory_id, report_date: report_date)
  end

  @spec list(keyword()) :: [ReportRun.t()]
  def list(opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)
    bucket = Keyword.get(opts, :bucket)
    inventory_id = Keyword.get(opts, :inventory_id)
    limit = positive_integer(Keyword.get(opts, :limit), 50)

    ReportRun
    |> maybe_filter(:bucket, bucket)
    |> maybe_filter(:inventory_id, inventory_id)
    |> order_by([r], desc: r.started_at)
    |> limit(^limit)
    |> repo.all()
  end

  @spec config_hash(map()) :: String.t()
  def config_hash(config) when is_map(config) do
    config
    |> Inventory.normalize_config()
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @spec status_for_summary(map()) :: String.t()
  def status_for_summary(summary) when is_map(summary) do
    cond do
      Map.get(summary, :errors, []) != [] -> "failed"
      Map.get(summary, :reports_written, 0) > 0 -> "ok"
      Map.get(summary, :configs_unsupported_format, 0) > 0 -> "skipped"
      Map.get(summary, :configs_skipped_disabled, 0) > 0 -> "skipped"
      true -> "skipped"
    end
  end

  defp do_claim(repo, attrs) do
    bucket = Map.fetch!(attrs, :bucket)
    inventory_id = Map.fetch!(attrs, :inventory_id)
    report_date = Map.fetch!(attrs, :report_date)

    case fetch_for_update(repo, bucket, inventory_id, report_date) do
      nil -> insert_claim(repo, attrs)
      %ReportRun{} = run -> reclaim_or_skip(repo, run, attrs)
    end
  end

  defp fetch_for_update(repo, bucket, inventory_id, report_date) do
    ReportRun
    |> where([r], r.bucket == ^bucket)
    |> where([r], r.inventory_id == ^inventory_id)
    |> where([r], r.report_date == ^report_date)
    |> lock("FOR UPDATE")
    |> repo.one()
  end

  defp insert_claim(repo, attrs) do
    insert_attrs =
      attrs
      |> Map.take([
        :bucket,
        :inventory_id,
        :report_date,
        :frequency,
        :config_hash,
        :trigger,
        :run_id,
        :file_id,
        :lease_until
      ])
      |> Map.merge(%{
        trigger: trigger_name(Map.fetch!(attrs, :trigger)),
        status: "running",
        attempts: 1,
        started_at: Map.fetch!(attrs, :now),
        duration_ms: 0,
        rows_written: 0,
        objects_written: 0,
        summary: %{}
      })

    %ReportRun{}
    |> ReportRun.changeset(insert_attrs)
    |> repo.insert(mode: :savepoint)
    |> case do
      {:ok, run} ->
        {:ok, run}

      {:error, changeset} ->
        if unique_report_constraint?(changeset) do
          bucket = Map.fetch!(attrs, :bucket)
          inventory_id = Map.fetch!(attrs, :inventory_id)
          report_date = Map.fetch!(attrs, :report_date)

          case fetch_for_update(repo, bucket, inventory_id, report_date) do
            %ReportRun{} = run -> reclaim_or_skip(repo, run, attrs)
            nil -> {:error, changeset}
          end
        else
          {:error, changeset}
        end
    end
  end

  defp reclaim_or_skip(_repo, %ReportRun{status: "ok"} = run, _attrs),
    do: {:skip, :already_completed, run}

  defp reclaim_or_skip(_repo, %ReportRun{status: "skipped", config_hash: hash} = run, %{
         config_hash: hash
       }),
       do: {:skip, :already_skipped, run}

  defp reclaim_or_skip(
         repo,
         %ReportRun{status: "running", lease_until: lease_until} = run,
         %{
           now: now
         } = attrs
       )
       when not is_nil(lease_until) do
    if DateTime.compare(lease_until, now) == :gt do
      {:skip, :running, run}
    else
      update_claim(repo, run, attrs)
    end
  end

  defp reclaim_or_skip(repo, %ReportRun{} = run, attrs), do: update_claim(repo, run, attrs)

  defp update_claim(repo, %ReportRun{} = run, attrs) do
    update_attrs = %{
      frequency: Map.fetch!(attrs, :frequency),
      config_hash: Map.fetch!(attrs, :config_hash),
      trigger: trigger_name(Map.fetch!(attrs, :trigger)),
      status: "running",
      attempts: run.attempts + 1,
      run_id: Map.fetch!(attrs, :run_id),
      file_id: Map.fetch!(attrs, :file_id),
      lease_until: Map.fetch!(attrs, :lease_until),
      started_at: Map.fetch!(attrs, :now),
      finished_at: nil,
      duration_ms: 0,
      manifest_key: nil,
      data_key: nil,
      checksum_key: nil,
      symlink_key: nil,
      rows_written: 0,
      objects_written: 0,
      summary: %{},
      error_reason: nil
    }

    run
    |> ReportRun.changeset(update_attrs)
    |> repo.update()
  end

  defp complete_claim(repo, %ReportRun{} = run, changeset) do
    completed = Ecto.Changeset.apply_changes(changeset)

    update_attrs =
      completed
      |> Map.take(@complete_update_fields)
      |> Map.put(:updated_at, DateTime.utc_now())
      |> Enum.to_list()

    query =
      ReportRun
      |> where([r], r.id == ^run.id)
      |> where([r], r.status == "running")
      |> where([r], r.attempts == ^run.attempts)
      |> where([r], r.lease_until == ^run.lease_until)

    case repo.update_all(query, set: update_attrs) do
      {1, _rows} -> {:ok, repo.get!(ReportRun, run.id)}
      {0, _rows} -> {:skip, :stale_completion, repo.get(ReportRun, run.id)}
    end
  end

  defp unique_report_constraint?(%Ecto.Changeset{} = changeset) do
    Enum.any?(changeset.errors, fn {_field, {_message, opts}} ->
      opts[:constraint] == :unique and
        opts[:constraint_name] == "s3_inventory_report_runs_unique_report_index"
    end)
  end

  defp first_report(summary) do
    summary
    |> Map.get(:reports, [])
    |> List.first()
  end

  defp summary_payload(summary) do
    %{
      "dry_run" => Map.get(summary, :dry_run, false),
      "buckets_scanned" => Map.get(summary, :buckets_scanned, 0),
      "configs_seen" => Map.get(summary, :configs_seen, 0),
      "configs_matched" => Map.get(summary, :configs_matched, 0),
      "configs_skipped_disabled" => Map.get(summary, :configs_skipped_disabled, 0),
      "configs_unsupported_format" => Map.get(summary, :configs_unsupported_format, 0),
      "reports_attempted" => Map.get(summary, :reports_attempted, 0),
      "reports_written" => Map.get(summary, :reports_written, 0),
      "objects_written" => Map.get(summary, :objects_written, 0),
      "rows_written" => Map.get(summary, :rows_written, 0),
      "errors" =>
        summary
        |> Map.get(:errors, [])
        |> Enum.map(&json_value/1),
      "reports" =>
        summary
        |> Map.get(:reports, [])
        |> Enum.map(&report_payload/1)
    }
  end

  defp report_payload(report) do
    Enum.reduce(@summary_report_keys, %{}, fn key, acc ->
      if Map.has_key?(report, key) do
        Map.put(acc, Atom.to_string(key), json_value(Map.get(report, key)))
      else
        acc
      end
    end)
  end

  defp json_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp json_value(%Date{} = value), do: Date.to_iso8601(value)
  defp json_value(%Time{} = value), do: Time.to_iso8601(value)

  defp json_value(value) when is_list(value), do: Enum.map(value, &json_value/1)

  defp json_value(value) when is_map(value) do
    Map.new(value, fn {key, map_value} -> {json_key(key), json_value(map_value)} end)
  end

  defp json_value(value) when is_tuple(value), do: inspect(value)
  defp json_value(value), do: value

  defp json_key(key) when is_binary(key), do: key
  defp json_key(key) when is_atom(key), do: Atom.to_string(key)
  defp json_key(key), do: inspect(key)

  defp error_reason(summary, "failed") do
    summary
    |> Map.get(:errors, [])
    |> List.first()
    |> case do
      nil -> "failed"
      error -> inspect(error)
    end
  end

  defp error_reason(summary, "skipped") do
    cond do
      Map.get(summary, :configs_unsupported_format, 0) > 0 -> "unsupported_format"
      Map.get(summary, :configs_skipped_disabled, 0) > 0 -> "disabled"
      true -> "no_report_written"
    end
  end

  defp error_reason(_summary, _status), do: nil

  defp maybe_filter(query, _field, nil), do: query
  defp maybe_filter(query, _field, ""), do: query

  defp maybe_filter(query, field, value) do
    where(query, [r], field(r, ^field) == ^value)
  end

  defp duration_ms(started_at, finished_at) do
    max(DateTime.diff(finished_at, started_at, :millisecond), 0)
  end

  defp trigger_name(trigger) when trigger in [:manual, "manual"], do: "manual"
  defp trigger_name(trigger) when trigger in [:scheduled, "scheduled"], do: "scheduled"
  defp trigger_name(trigger), do: to_string(trigger)

  defp stable_run_id(attrs) do
    digest =
      [:bucket, :inventory_id, :report_date]
      |> Enum.map(&Map.fetch!(attrs, &1))
      |> Enum.join(":")
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.url_encode64(padding: false)
      |> binary_part(0, 20)

    "run-" <> digest
  end

  defp stable_file_id(attrs), do: Map.get(attrs, :run_id) || stable_run_id(attrs)

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value, default), do: default
end
