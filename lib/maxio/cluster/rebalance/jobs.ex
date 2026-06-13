defmodule Maxio.Cluster.Rebalance.Jobs do
  @moduledoc """
  Persistent control plane for future rebalance/decommission data movement.

  This module creates and tracks operator jobs, but does not move shards yet.
  A start call stores a point-in-time `Maxio.Cluster.Rebalance.plan/1` snapshot
  and leaves `data_movement_status` as `not_started` so operators can see the
  exact boundary.
  """

  import Ecto.Query

  alias Maxio.Cluster.Rebalance
  alias Maxio.Cluster.Rebalance.Job
  alias Maxio.Repo
  alias Maxio.S3.Log

  @active_statuses ~w(planned running cancel_requested)
  @default_page_size 500

  @type start_opts :: keyword()

  @doc """
  Start a rebalance or decommission control-plane job.

  Passing `:decommission_set` or `:target_set_id` starts a decommission job.
  Otherwise this starts a rebalance job.
  """
  @spec start(start_opts()) :: {:ok, Job.t()} | {:error, term()}
  def start(opts \\ []) do
    case Keyword.get(opts, :decommission_set, Keyword.get(opts, :target_set_id)) do
      nil -> start_rebalance(opts)
      set_id when is_integer(set_id) -> start_decommission(set_id, opts)
      set_id -> {:error, {:invalid_target_set_id, set_id}}
    end
  end

  @doc "Start a rebalance control-plane job."
  @spec start_rebalance(start_opts()) :: {:ok, Job.t()} | {:error, term()}
  def start_rebalance(opts \\ []), do: create("rebalance", opts)

  @doc "Start a decommission control-plane job for one erasure set."
  @spec start_decommission(integer(), start_opts()) :: {:ok, Job.t()} | {:error, term()}
  def start_decommission(set_id, opts \\ []) when is_integer(set_id),
    do: create("decommission", Keyword.put(opts, :target_set_id, set_id))

  @doc "List jobs, newest first. Filters: `:kind`, `:status`, `:target_set_id`, `:limit`."
  @spec list(keyword()) :: [Job.t()]
  def list(opts \\ []) do
    Job
    |> maybe_where(:kind, Keyword.get(opts, :kind))
    |> maybe_where(:status, Keyword.get(opts, :status))
    |> maybe_where(:target_set_id, Keyword.get(opts, :target_set_id))
    |> order_by([j], desc: j.inserted_at)
    |> limit(^positive_int(Keyword.get(opts, :limit), 20))
    |> Repo.all()
  end

  @doc "Return the latest job for optional filters."
  @spec latest(keyword()) :: Job.t() | nil
  def latest(opts \\ []), do: opts |> Keyword.put(:limit, 1) |> list() |> List.first()

  @doc "Fetch a job by UUID."
  @spec get(String.t()) :: {:ok, Job.t()} | {:error, :not_found}
  def get(id) when is_binary(id) do
    case Repo.get(Job, id) do
      nil -> {:error, :not_found}
      %Job{} = job -> {:ok, job}
    end
  end

  @doc "Cancel a planned/running job by UUID."
  @spec cancel(String.t(), keyword()) :: {:ok, Job.t()} | {:error, term()}
  def cancel(id, opts \\ []) when is_binary(id) do
    with {:ok, job} <- get(id) do
      cancel_job(job, opts)
    end
  end

  @doc "Cancel the latest active job matching optional filters."
  @spec cancel_latest(keyword()) :: {:ok, Job.t()} | {:error, term()}
  def cancel_latest(opts \\ []) do
    opts
    |> active_job()
    |> case do
      nil -> {:error, :not_found}
      %Job{} = job -> cancel_job(job, opts)
    end
  end

  @doc "Return the latest active job matching optional filters."
  @spec active_job(keyword()) :: Job.t() | nil
  def active_job(opts \\ []) do
    Job
    |> where([j], j.status in ^@active_statuses)
    |> maybe_where(:kind, Keyword.get(opts, :kind))
    |> maybe_where(:target_set_id, Keyword.get(opts, :target_set_id))
    |> order_by([j], desc: j.inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  @doc "Machine-friendly map for CLI JSON output and tests."
  @spec to_view(Job.t()) :: map()
  def to_view(%Job{} = job) do
    %{
      id: job.id,
      kind: job.kind,
      status: job.status,
      data_movement_status: job.data_movement_status,
      data_movement: false,
      target_set_id: job.target_set_id,
      current_only: job.current_only,
      include_drive_stats: job.include_drive_stats,
      page_size: job.page_size,
      plan_status: job.plan_status,
      plan_scanned: job.plan_scanned,
      plan_bytes: job.plan_bytes,
      plan_placement_fallbacks: job.plan_placement_fallbacks,
      cursor_bucket: job.cursor_bucket,
      cursor_key_marker: job.cursor_key_marker,
      cursor_version_id_marker: job.cursor_version_id_marker,
      progress_scanned: job.progress_scanned,
      progress_moved: job.progress_moved,
      progress_skipped: job.progress_skipped,
      progress_errors: job.progress_errors,
      cancel_requested_at: iso8601(job.cancel_requested_at),
      started_at: iso8601(job.started_at),
      finished_at: iso8601(job.finished_at),
      requested_by: job.requested_by,
      error_reason: job.error_reason,
      inserted_at: iso8601(job.inserted_at),
      updated_at: iso8601(job.updated_at)
    }
  end

  defp create(kind, opts) do
    with :ok <- validate_kind(kind),
         :ok <- validate_scope(kind, opts),
         :ok <- ensure_no_active_job(),
         {:ok, report} <- build_plan(kind, opts),
         :ok <- ensure_topology(report),
         :ok <- ensure_safe_placement(kind, report) do
      attrs = attrs_from_report(kind, report, opts)

      %Job{}
      |> Job.changeset(attrs)
      |> Repo.insert()
      |> case do
        {:ok, job} ->
          Log.info("rebalance job created",
            action: :rebalance_job_start,
            reason:
              "id=#{job.id} kind=#{job.kind} status=#{job.status} " <>
                "target_set_id=#{inspect(job.target_set_id)} scanned=#{job.plan_scanned} " <>
                "bytes=#{job.plan_bytes} data_movement_status=#{job.data_movement_status}"
          )

          {:ok, job}

        {:error, changeset} ->
          if active_singleton_conflict?(changeset) do
            {:error, {:active_job_exists, active_job()}}
          else
            {:error, changeset}
          end
      end
    end
  end

  defp validate_kind(kind) when kind in ["rebalance", "decommission"], do: :ok
  defp validate_kind(kind), do: {:error, {:invalid_kind, kind}}

  defp validate_scope("decommission", opts) do
    if Keyword.get(opts, :current_only, false) do
      {:error, :decommission_requires_versions}
    else
      :ok
    end
  end

  defp validate_scope("rebalance", _opts), do: :ok

  defp ensure_no_active_job do
    case active_job() do
      nil -> :ok
      %Job{} = job -> {:error, {:active_job_exists, job}}
    end
  end

  defp build_plan("rebalance", opts), do: Rebalance.plan(plan_opts(opts))

  defp build_plan("decommission", opts) do
    case Keyword.fetch(opts, :target_set_id) do
      {:ok, set_id} when is_integer(set_id) ->
        Rebalance.decommission_impact(set_id, plan_opts(opts))

      {:ok, set_id} ->
        {:error, {:invalid_target_set_id, set_id}}

      :error ->
        {:error, :missing_target_set_id}
    end
  end

  defp ensure_topology(%{status: :no_topology}), do: {:error, :no_topology}
  defp ensure_topology(_report), do: :ok

  defp ensure_safe_placement("decommission", report) do
    case report.decommission.placement_fallbacks do
      0 -> :ok
      count -> {:error, {:placement_fallbacks, count}}
    end
  end

  defp ensure_safe_placement("rebalance", report) do
    case report.placement_fallbacks do
      0 -> :ok
      count -> {:error, {:placement_fallbacks, count}}
    end
  end

  defp plan_opts(opts) do
    [
      current_only: Keyword.get(opts, :current_only, false),
      page_size: positive_int(Keyword.get(opts, :page_size), @default_page_size),
      include_drive_stats: Keyword.get(opts, :include_drive_stats, true)
    ]
    |> maybe_put(:topology, Keyword.get(opts, :topology))
    |> maybe_put(:drive_stats_fun, Keyword.get(opts, :drive_stats_fun))
  end

  defp attrs_from_report(kind, report, opts) do
    %{
      kind: kind,
      status: "planned",
      data_movement_status: "not_started",
      target_set_id: target_set_id(kind, opts),
      current_only: report.current_only,
      include_drive_stats: Keyword.get(opts, :include_drive_stats, true),
      page_size: positive_int(Keyword.get(opts, :page_size), @default_page_size),
      plan_status: Atom.to_string(report.status),
      plan: json_ready(report),
      plan_scanned: plan_scanned(kind, report),
      plan_bytes: plan_bytes(kind, report),
      plan_placement_fallbacks: plan_placement_fallbacks(kind, report),
      progress_scanned: 0,
      progress_moved: 0,
      progress_skipped: 0,
      progress_errors: 0,
      started_at: now(opts),
      requested_by: Keyword.get(opts, :requested_by, "mix")
    }
  end

  defp target_set_id("decommission", opts), do: Keyword.fetch!(opts, :target_set_id)
  defp target_set_id("rebalance", _opts), do: nil

  defp plan_scanned("decommission", report), do: report.decommission.versions
  defp plan_scanned("rebalance", report), do: report.scanned

  defp plan_bytes("decommission", report), do: report.decommission.bytes
  defp plan_bytes("rebalance", report), do: report.bytes

  defp plan_placement_fallbacks("decommission", report),
    do: report.decommission.placement_fallbacks

  defp plan_placement_fallbacks("rebalance", report), do: report.placement_fallbacks

  defp cancel_job(%Job{status: status} = job, opts) when status in @active_statuses do
    finished_at = now(opts)

    job
    |> Job.changeset(%{
      status: "canceled",
      data_movement_status: "canceled",
      cancel_requested_at: finished_at,
      finished_at: finished_at
    })
    |> Repo.update()
    |> case do
      {:ok, job} ->
        Log.info("rebalance job canceled",
          action: :rebalance_job_cancel,
          reason: "id=#{job.id} kind=#{job.kind} status=#{job.status}"
        )

        {:ok, job}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp cancel_job(%Job{} = job, _opts), do: {:error, {:not_cancelable, job.status}}

  defp maybe_where(query, _field, nil), do: query

  defp maybe_where(query, field, value) do
    where(query, [j], field(j, ^field) == ^value)
  end

  defp active_singleton_conflict?(changeset) do
    Enum.any?(changeset.errors, fn
      {:status, {_message, opts}} ->
        Keyword.get(opts, :constraint_name) == "cluster_rebalance_jobs_active_singleton_index"

      _error ->
        false
    end)
  end

  defp positive_int(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_int(_value, default), do: default

  defp now(opts), do: Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp json_ready(nil), do: nil
  defp json_ready(value) when is_boolean(value), do: value
  defp json_ready(value) when is_atom(value), do: Atom.to_string(value)
  defp json_ready(value) when is_list(value), do: Enum.map(value, &json_ready/1)

  defp json_ready(%{} = value) do
    Map.new(value, fn {key, item} -> {to_string(key), json_ready(item)} end)
  end

  defp json_ready(value), do: value

  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
end
