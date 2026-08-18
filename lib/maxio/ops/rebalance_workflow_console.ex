defmodule Maxio.Ops.RebalanceWorkflowConsole do
  @moduledoc """
  Read-only console projection for rebalance/decommission workflow evidence.

  This module intentionally stays outside the execution path. It reads recent
  jobs, selects at most one job for the heavier workflow summary, and returns a
  bounded view model for the LiveView.
  """

  alias Maxio.Cluster.Rebalance.Job
  alias Maxio.Cluster.Rebalance.Jobs
  alias Maxio.Cluster.Rebalance.Workflow

  @default_limit 20
  @max_job_id_length 128
  @max_text_length 512
  @allowed_job_id ~r/^[A-Za-z0-9][A-Za-z0-9_-]*$/

  @type selection_notice :: %{
          reason: String.t(),
          requested: String.t() | nil,
          selected: String.t() | nil
        }

  @type load_result :: %{
          status: String.t(),
          jobs: [map()],
          selected_job: map() | nil,
          workflow: map() | nil,
          selection_notice: selection_notice() | nil
        }

  @spec load(map(), keyword()) :: load_result()
  def load(params \\ %{}, opts \\ []) when is_map(params) do
    jobs = Jobs.list(limit: positive_integer(Keyword.get(opts, :limit), @default_limit))
    {selected_job, selection_notice} = select_job(jobs, Map.get(params, "job_id"))

    %{
      status: status(jobs),
      jobs: Enum.map(jobs, &job_row/1),
      selected_job: maybe_job_row(selected_job),
      workflow: workflow_summary(selected_job, Keyword.get(opts, :workflow_opts, [])),
      selection_notice: selection_notice
    }
  end

  @spec job_row(Job.t()) :: map()
  def job_row(%Job{} = job) do
    job
    |> Jobs.to_view()
    |> Map.take([
      :id,
      :kind,
      :status,
      :data_movement_status,
      :target_set_id,
      :destination_set_id,
      :source_cleanup_status,
      :rebalance_closure_status,
      :topology_removal_status,
      :topology_removal_cluster_status,
      :topology_removal_deployment_status,
      :physical_removal_status,
      :physical_removal_purge_status,
      :plan_status,
      :plan_scanned,
      :plan_bytes,
      :plan_placement_fallbacks,
      :progress_scanned,
      :progress_moved,
      :progress_errors,
      :source_cleanup_scanned,
      :source_cleanup_deleted,
      :source_cleanup_errors,
      :started_at,
      :finished_at,
      :requested_by
    ])
  end

  defp select_job([], requested) do
    case normalize_requested_job_id(requested) do
      :none -> {nil, nil}
      {:invalid, reason, value} -> {nil, notice(reason, value, nil)}
      {:ok, value} -> {nil, notice("not_found", value, nil)}
    end
  end

  defp select_job([latest | _] = jobs, requested) do
    case normalize_requested_job_id(requested) do
      :none ->
        {latest, nil}

      {:invalid, reason, value} ->
        {latest, notice(reason, value, latest.id)}

      {:ok, value} ->
        case Enum.find(jobs, &(&1.id == value)) do
          %Job{} = job -> {job, nil}
          nil -> {latest, notice("not_found", value, latest.id)}
        end
    end
  end

  defp normalize_requested_job_id(nil), do: :none

  defp normalize_requested_job_id(value) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" ->
        {:invalid, "blank_job_id", trimmed}

      String.length(trimmed) > @max_job_id_length ->
        {:invalid, "job_id_too_long", display_text(trimmed)}

      not Regex.match?(@allowed_job_id, trimmed) ->
        {:invalid, "invalid_job_id", display_text(trimmed)}

      true ->
        {:ok, trimmed}
    end
  end

  defp normalize_requested_job_id(value), do: {:invalid, "invalid_job_id", inspect(value)}

  defp workflow_summary(nil, _opts), do: nil

  defp workflow_summary(%Job{} = job, opts) do
    job
    |> Workflow.summary(opts)
    |> normalize_workflow_summary()
  rescue
    error ->
      workflow_error(job, Exception.message(error))
  catch
    kind, reason ->
      workflow_error(job, "#{kind}: #{inspect(reason)}")
  end

  defp normalize_workflow_summary(summary) when is_map(summary) do
    %{
      available?: true,
      status: text(summary[:status]),
      phase: text(summary[:phase]),
      gate_status: text(summary[:gate_status]),
      next_action: text(summary[:next_action]),
      destructive_next_action?: Map.get(summary, :destructive_next_action?) == true,
      job_id: text(summary[:job_id]),
      job_kind: text(summary[:job_kind]),
      target_set_id: value(summary[:target_set_id]),
      destination_set_id: value(summary[:destination_set_id]),
      removed_pool_ids: value(summary[:removed_pool_ids]),
      set_retired?: bool(summary[:set_retired?]),
      pool_retired?: bool(summary[:pool_retired?]),
      rebalance_complete?: bool(summary[:rebalance_complete?]),
      blockers: text_list(summary[:blockers]),
      warnings: text_list(summary[:warnings]),
      runtime_topology_rows: topology_rows(summary[:runtime_topology]),
      deployment_topology_rows: topology_rows(summary[:deployment_topology]),
      rebalance_audit_rows: rebalance_audit_rows(summary[:rebalance_audit]),
      rebalance_audit_examples: rebalance_audit_examples(summary[:rebalance_audit]),
      rebalance_closure_rows: rebalance_closure_rows(summary[:rebalance_closure]),
      job: summary[:job]
    }
  end

  defp workflow_error(%Job{} = job, reason) do
    %{
      available?: false,
      status: "error",
      phase: "summary_error",
      gate_status: "error",
      next_action: nil,
      destructive_next_action?: false,
      job_id: job.id,
      job_kind: job.kind,
      target_set_id: value(job.target_set_id),
      destination_set_id: value(job.destination_set_id),
      removed_pool_ids: "-",
      set_retired?: "false",
      pool_retired?: "false",
      rebalance_complete?: "false",
      blockers: ["workflow_summary_error: #{display_text(reason)}"],
      warnings: [],
      runtime_topology_rows: [],
      deployment_topology_rows: [],
      rebalance_audit_rows: [],
      rebalance_audit_examples: [],
      rebalance_closure_rows: [],
      job: Jobs.to_view(job)
    }
  end

  defp topology_rows(topology) when is_map(topology) do
    [
      row("source", topology[:source]),
      row("status", topology[:status]),
      row("reason", topology[:reason]),
      row("topology_hash", topology[:topology_hash]),
      row("set_ids", topology[:set_ids]),
      row("pool_ids", topology[:pool_ids]),
      row("target_set_configured?", topology[:target_set_configured?]),
      row("removed_pool_ids_configured?", topology[:removed_pool_ids_configured?])
    ]
    |> present_rows()
  end

  defp topology_rows(_topology), do: []

  defp rebalance_audit_rows(audit) when is_map(audit) do
    [
      row("status", audit[:status]),
      row("reason", audit[:reason]),
      row("topology_hash", audit[:topology_hash]),
      row("versions_scanned", audit[:versions_scanned]),
      row("routing_mismatches", audit[:routing_mismatches]),
      row("missing_placements", audit[:missing_placements]),
      row("unknown_placements", audit[:unknown_placements]),
      row("stale_topology_hashes", audit[:stale_topology_hashes]),
      row("active_multipart_uploads", audit[:active_multipart_uploads]),
      row("missing_multipart_upload_placements", audit[:missing_multipart_upload_placements]),
      row("unknown_multipart_upload_placements", audit[:unknown_multipart_upload_placements]),
      row(
        "stale_multipart_upload_topology_hashes",
        audit[:stale_multipart_upload_topology_hashes]
      ),
      row("active_job_id", audit[:active_job_id]),
      row("authoritative_source", audit[:authoritative_source]),
      row("blockers", audit[:blockers])
    ]
    |> present_rows()
  end

  defp rebalance_audit_rows(_audit), do: []

  defp rebalance_audit_examples(%{examples: examples}) when is_list(examples) do
    examples
    |> Enum.take(5)
    |> Enum.map(&normalize_example/1)
  end

  defp rebalance_audit_examples(_audit), do: []

  defp rebalance_closure_rows(closure) when is_map(closure) do
    [
      row("status", closure[:status]),
      row("checked_at", closure[:checked_at]),
      row("verified_at", closure[:verified_at]),
      row("topology_hash", closure[:topology_hash]),
      row("blockers", closure[:blockers]),
      row("error_reason", closure[:error_reason])
    ]
    |> present_rows()
  end

  defp rebalance_closure_rows(_closure), do: []

  defp normalize_example(example) when is_map(example) do
    example
    |> Enum.take(8)
    |> Enum.map(fn {key, value} -> row(to_string(key), value) end)
    |> present_rows()
  end

  defp normalize_example(other), do: [row("value", other)]

  defp row(label, nil), do: %{label: label, value: nil}
  defp row(label, value), do: %{label: label, value: value(value)}

  defp present_rows(rows), do: Enum.reject(rows, &is_nil(&1.value))

  defp maybe_job_row(nil), do: nil
  defp maybe_job_row(%Job{} = job), do: job_row(job)

  defp status([]), do: "not_started"
  defp status(_jobs), do: "ok"

  defp notice(reason, requested, selected) do
    %{reason: reason, requested: display_text(requested), selected: selected}
  end

  defp positive_integer(value, _fallback) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value, fallback), do: fallback

  defp bool(true), do: "true"
  defp bool(false), do: "false"
  defp bool(_other), do: "-"

  defp text(nil), do: nil
  defp text(value), do: display_text(value)

  defp text_list(values) when is_list(values),
    do: values |> Enum.map(&display_text/1) |> Enum.take(20)

  defp text_list(nil), do: []
  defp text_list(value), do: [display_text(value)]

  defp value(nil), do: nil

  defp value(values) when is_list(values) do
    values
    |> Enum.map(&display_text/1)
    |> Enum.take(8)
    |> Enum.join(", ")
  end

  defp value(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp value(%{} = map) do
    map
    |> Enum.take(8)
    |> Enum.map(fn {key, value} -> "#{key}=#{display_text(value)}" end)
    |> Enum.join(", ")
    |> empty_to_dash()
  end

  defp value(value) when is_binary(value), do: display_text(value)

  defp value(value) when is_integer(value) or is_float(value) or is_boolean(value),
    do: to_string(value)

  defp value(value), do: value |> inspect() |> display_text()

  defp display_text(value) when is_binary(value) do
    value
    |> String.replace(~r/[\r\n\t]+/, " ")
    |> String.slice(0, @max_text_length)
  end

  defp display_text(value), do: value |> inspect() |> display_text()

  defp empty_to_dash(""), do: "-"
  defp empty_to_dash(value), do: value
end
