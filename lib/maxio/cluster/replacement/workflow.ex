defmodule Maxio.Cluster.Replacement.Workflow do
  @moduledoc """
  Operator-safe replacement workflow runbook.

  This module is a thin composition layer over existing replacement primitives:

    * `Maxio.Cluster.DriveHealth.probe_topology/1`
    * `Maxio.Cluster.FreshDriveHeal.Scheduler.run_now/1`
    * `Maxio.Cluster.Rebalance.Scheduler.run_steps/1`, through the fresh-drive scheduler
    * `Maxio.Cluster.Rebalance.Workflow.summary/2`

  The default mode is read-only audit. Mutating steps require explicit options.
  It never invokes decommission, topology mutation, deployment finalization,
  physical removal, or purge.
  """

  alias Maxio.Cluster.DriveHealth
  alias Maxio.Cluster.FreshDriveHeal
  alias Maxio.Cluster.Rebalance
  alias Maxio.Cluster.Rebalance.Jobs
  alias Maxio.Cluster.Replacement.AutomationProfile

  @fresh_drive_keys [
    :bucket,
    :scan_versions,
    :max_objects,
    :dry_run,
    :page_size,
    :topology,
    :transport,
    :lock_nodes,
    :lock_ttl_ms,
    :lock_timeout_ms,
    :lock_heartbeat_ms,
    :max_objects_per_sec,
    :object_burst,
    :sleep_between_batches_ms,
    :adaptive_io,
    :max_live_requests,
    :io_pause_ms,
    :io_max_pause_ms,
    :io_load_source,
    :io_load_fun,
    :throttle_sleep_fun,
    :throttle_now_fun,
    :no_throttle,
    :drive_offline_after_ms,
    :drive_health_now_fun,
    :drive_health_now_ms
  ]

  @probe_keys [
    :topology,
    :transport,
    :drive_offline_after_ms,
    :drive_health_now_fun,
    :drive_health_now_ms
  ]

  @workflow_keys [:audit_page_size, :page_size, :authoritative_source, :deployment_topology]

  @doc """
  Run a replacement workflow audit or explicitly requested bounded steps.

  Options:

    * `:probe` - refresh drive health observations before the report.
    * `:heal` - run the fresh-drive heal scheduler bridge.
    * `:rebalance_if_needed` - with `:heal`, enqueue a rebalance job after a clean marker clear.
    * `:advance_steps` - with `:heal`, bounded-drain only the job created in this workflow run.
    * `:verify_closure` - implies a bounded advance if `:advance_steps` is absent and enables closure verification.

  Test injection options:

    * `:probe_fun` - function/1, defaults to `DriveHealth.probe_topology/1`.
    * `:snapshot_fun` - function/0, defaults to `DriveHealth.snapshot/0`.
    * `:fresh_scheduler` - function/1, defaults to `FreshDriveHeal.Scheduler.run_now/1`.
    * `:latest_job_fun` - function/0, defaults to latest ordinary rebalance job.
    * `:rebalance_workflow` - function/2, defaults to `Rebalance.Workflow.summary/2`.
  """
  @spec run(keyword()) :: {:ok, map()} | {:error, term()}
  def run(opts \\ []) when is_list(opts) do
    with :ok <- validate(opts) do
      before = drive_health_summary(snapshot_fun(opts).())
      probe = maybe_probe(opts)
      after_probe = drive_health_summary(snapshot_fun(opts).())
      heal = maybe_heal(opts)
      job_id = workflow_job_id(heal) || fallback_rebalance_job_id(heal, opts)
      rebalance_workflow = maybe_rebalance_workflow(job_id, opts)

      report =
        %{
          status: overall_status(probe, heal, rebalance_workflow, opts),
          phase: phase(probe, heal, opts),
          mutating?: mutating?(opts),
          probe: probe,
          drive_health_before: before,
          drive_health_after: after_probe,
          heal: heal,
          rebalance_enqueue: Map.get(heal, :rebalance_enqueue, not_requested()),
          rebalance_advance: Map.get(heal, :rebalance_advance, not_requested()),
          rebalance_workflow: rebalance_workflow,
          automation_profile:
            AutomationProfile.status(Keyword.get(opts, :automation_profile_opts, [])),
          job_id: job_id,
          blockers: blockers(probe, heal, rebalance_workflow),
          next_action: next_action(before, after_probe, heal, rebalance_workflow, opts)
        }

      {:ok, report}
    end
  end

  defp validate(opts) do
    advance_steps = Keyword.get(opts, :advance_steps)
    heal? = flag?(opts, :heal)
    rebalance? = flag?(opts, :rebalance_if_needed)
    verify? = flag?(opts, :verify_closure)
    advance? = not is_nil(advance_steps) or verify?

    cond do
      not is_nil(advance_steps) and not positive_integer?(advance_steps) ->
        {:error, {:invalid_advance_steps, advance_steps}}

      advance? and not heal? ->
        {:error, :advance_requires_heal}

      rebalance? and not heal? ->
        {:error, :rebalance_requires_heal}

      true ->
        :ok
    end
  end

  defp maybe_probe(opts) do
    if flag?(opts, :probe) do
      case safe_call(probe_fun(opts), probe_opts(opts)) do
        {:ok, summary} -> %{status: :ok, summary: summary}
        {:error, reason} -> %{status: :failed, reason: inspect(reason)}
      end
    else
      not_requested()
    end
  end

  defp maybe_heal(opts) do
    if flag?(opts, :heal) do
      case safe_call(fresh_scheduler(opts), fresh_scheduler_opts(opts)) do
        {:ok, report} when is_map(report) -> report
        {:ok, other} -> %{status: :failed, reason: inspect({:bad_fresh_scheduler_result, other})}
        {:error, reason} -> %{status: :failed, reason: inspect(reason)}
      end
    else
      not_requested()
    end
  end

  defp safe_call(fun, arg) when is_function(fun, 1) do
    fun.(arg)
  rescue
    e -> {:error, {:crashed, Exception.message(e)}}
  catch
    kind, reason -> {:error, {:caught, kind, reason}}
  end

  defp probe_opts(opts) do
    opts
    |> Keyword.take(@probe_keys)
    |> rename(:drive_offline_after_ms, :offline_after_ms)
    |> rename(:drive_health_now_fun, :now_fun)
    |> rename(:drive_health_now_ms, :now_ms)
    |> Keyword.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp fresh_scheduler_opts(opts) do
    advance_steps = advance_steps(opts)
    rebalance? = flag?(opts, :rebalance_if_needed) or not is_nil(advance_steps)

    opts
    |> Keyword.take(@fresh_drive_keys)
    |> Keyword.put(:probe_drive_health, false)
    |> Keyword.put(:auto_rebalance_after_heal, rebalance?)
    |> Keyword.put(:auto_advance_rebalance_after_heal, not is_nil(advance_steps))
    |> maybe_put(:rebalance_advance_max_steps, advance_steps)
    |> maybe_put(:rebalance_start_opts, rebalance_start_opts(opts))
    |> maybe_put(:rebalance_advance_opts, rebalance_advance_opts(opts))
    |> Keyword.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp rebalance_start_opts(opts) do
    opts
    |> Keyword.get(:rebalance_start_opts, [])
    |> Keyword.merge(Keyword.take(opts, [:topology, :page_size, :include_drive_stats]))
    |> Keyword.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp rebalance_advance_opts(opts) do
    opts
    |> Keyword.get(:rebalance_advance_opts, [])
    |> Keyword.merge(Keyword.take(opts, [:topology, :transport, :page_size, :audit_page_size]))
    |> Keyword.put(:auto_rebalance_closure, flag?(opts, :verify_closure))
    |> Keyword.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp maybe_rebalance_workflow(nil, _opts), do: %{status: :not_found}

  defp maybe_rebalance_workflow(job_id, opts) when is_binary(job_id) do
    case rebalance_workflow_fun(opts).(job_id, workflow_opts(opts)) do
      {:ok, report} when is_map(report) ->
        report

      {:error, reason} ->
        %{status: :unavailable, job_id: job_id, reason: inspect(reason)}

      other ->
        %{status: :unavailable, job_id: job_id, reason: inspect({:bad_workflow_result, other})}
    end
  rescue
    e -> %{status: :unavailable, job_id: job_id, reason: Exception.message(e)}
  catch
    kind, reason -> %{status: :unavailable, job_id: job_id, reason: inspect({kind, reason})}
  end

  defp workflow_opts(opts), do: Keyword.take(opts, @workflow_keys)

  defp workflow_job_id(%{
         rebalance_enqueue: %{status: :created, kind: "rebalance", job_id: enqueue_id},
         rebalance_advance: %{job_id: advance_id}
       })
       when is_binary(enqueue_id) and enqueue_id == advance_id,
       do: advance_id

  defp workflow_job_id(%{
         rebalance_enqueue: %{status: :created, kind: "rebalance", job_id: enqueue_id},
         rebalance_advance: %{job_id: advance_id}
       })
       when is_binary(enqueue_id) and is_binary(advance_id),
       do: nil

  defp workflow_job_id(%{rebalance_enqueue: %{status: :created, kind: "rebalance", job_id: id}})
       when is_binary(id),
       do: id

  defp workflow_job_id(_heal), do: nil

  defp fallback_rebalance_job_id(%{status: status}, _opts)
       when status not in [:not_requested, "not_requested"],
       do: nil

  defp fallback_rebalance_job_id(_heal, opts), do: latest_rebalance_job_id(opts)

  defp latest_rebalance_job_id(opts) do
    case latest_job_fun(opts).() do
      nil -> nil
      %{id: id, kind: "rebalance"} when is_binary(id) -> id
      _other -> nil
    end
  end

  defp overall_status(%{status: :failed}, _heal, _workflow, _opts), do: :failed
  defp overall_status(_probe, %{status: :failed}, _workflow, _opts), do: :failed

  defp overall_status(_probe, %{rebalance_advance: %{status: :failed}}, _workflow, _opts),
    do: :failed

  defp overall_status(_probe, %{rebalance_advance: %{status: :blocked}}, _workflow, _opts),
    do: :blocked

  defp overall_status(_probe, %{rebalance_enqueue: %{status: :failed}}, _workflow, _opts),
    do: :blocked

  defp overall_status(_probe, %{status: status}, _workflow, _opts)
       when status in [:incomplete, :partial, :partial_scope, :waiting],
       do: :blocked

  defp overall_status(_probe, _heal, %{status: "blocked"}, _opts), do: :blocked
  defp overall_status(_probe, _heal, %{status: :unavailable}, _opts), do: :blocked

  defp overall_status(_probe, heal, _workflow, opts) do
    cond do
      rebalance_advance_job_mismatch?(heal) -> :blocked
      rebalance_enqueue_blocked?(heal, opts) -> :blocked
      rebalance_advance_blocked?(heal, opts) -> :blocked
      mutating?(opts) -> :ok
      true -> :audit
    end
  end

  defp phase(_probe, %{rebalance_advance: %{status: status}}, _opts)
       when status not in [:not_requested, "not_requested"],
       do: :rebalance_advanced

  defp phase(_probe, %{rebalance_enqueue: %{status: status}}, _opts)
       when status not in [:not_requested, "not_requested"],
       do: :rebalance_enqueued

  defp phase(_probe, %{status: status}, _opts)
       when status not in [:not_requested, "not_requested"],
       do: :healed

  defp phase(%{status: status}, _heal, _opts)
       when status not in [:not_requested, "not_requested"],
       do: :probed

  defp phase(_probe, _heal, _opts), do: :audit

  defp blockers(probe, heal, workflow) do
    []
    |> maybe_block(probe[:status] == :failed, "drive_probe_failed")
    |> maybe_block(heal[:status] == :failed, "fresh_drive_heal_failed")
    |> maybe_block(
      heal[:status] in [:incomplete, :partial, :partial_scope, :waiting],
      "fresh_drive_heal_#{heal[:status]}"
    )
    |> maybe_block(rebalance_advance_job_mismatch?(heal), "rebalance_advance_job_mismatch")
    |> enqueue_blockers(heal)
    |> advance_blockers(heal)
    |> append_blockers(get_in(heal, [:rebalance_advance, :blockers]))
    |> append_blockers(Map.get(workflow, :blockers))
  end

  defp rebalance_advance_job_mismatch?(%{
         rebalance_enqueue: %{status: :created, kind: "rebalance", job_id: enqueue_id},
         rebalance_advance: %{job_id: advance_id}
       })
       when is_binary(enqueue_id) and is_binary(advance_id),
       do: enqueue_id != advance_id

  defp rebalance_advance_job_mismatch?(_heal), do: false

  defp rebalance_enqueue_blocked?(heal, opts) do
    flag?(opts, :rebalance_if_needed) and
      get_in(heal, [:rebalance_enqueue, :status]) in [:failed, :skipped, :not_eligible]
  end

  defp rebalance_advance_blocked?(heal, opts) do
    advance_steps(opts) != nil and
      get_in(heal, [:rebalance_advance, :status]) in [:failed, :skipped, :not_eligible]
  end

  defp enqueue_blockers(blockers, %{rebalance_enqueue: %{status: status} = enqueue})
       when status in [:failed, :skipped, :not_eligible] do
    [status_blocker("rebalance_enqueue", enqueue) | blockers]
  end

  defp enqueue_blockers(blockers, _heal), do: blockers

  defp advance_blockers(blockers, %{rebalance_advance: %{status: status} = advance})
       when status in [:failed, :skipped, :not_eligible] do
    [status_blocker("rebalance_advance", advance) | blockers]
  end

  defp advance_blockers(blockers, _heal), do: blockers

  defp status_blocker(prefix, %{reason: reason}) when not is_nil(reason),
    do: "#{prefix}_#{normalize_blocker_reason(reason)}"

  defp status_blocker(prefix, %{status: status}), do: "#{prefix}_#{status}"

  defp normalize_blocker_reason(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp normalize_blocker_reason(reason) do
    reason
    |> inspect()
    |> String.replace(~r/[^A-Za-z0-9_]+/, "_")
    |> String.trim("_")
  end

  defp next_action(
         _before,
         _after_probe,
         %{
           rebalance_enqueue: %{status: :created, kind: "rebalance", job_id: enqueue_id},
           rebalance_advance: %{job_id: advance_id}
         },
         workflow,
         _opts
       )
       when is_binary(enqueue_id) and is_binary(advance_id) do
    if enqueue_id == advance_id, do: workflow_next_action(workflow, enqueue_id), else: "none"
  end

  defp next_action(
         _before,
         _after_probe,
         %{rebalance_enqueue: %{status: :created, kind: "rebalance", job_id: job_id}},
         workflow,
         _opts
       )
       when is_binary(job_id) do
    workflow_next_action(workflow, job_id)
  end

  defp next_action(_before, _after_probe, _heal, %{next_action: next}, _opts)
       when is_binary(next) and next != "none",
       do: next

  defp next_action(
         _before,
         %{heal_required: required},
         %{status: :not_requested},
         _workflow,
         _opts
       )
       when required > 0,
       do: "mix maxio.replacement.workflow --heal --rebalance-if-needed"

  defp next_action(_before, _after_probe, _heal, _workflow, _opts), do: "none"

  defp workflow_next_action(%{next_action: next}, _job_id)
       when is_binary(next) and next != "none",
       do: next

  defp workflow_next_action(%{next_action: "none"}, _job_id), do: "none"

  defp workflow_next_action(_workflow, job_id),
    do: "mix maxio.rebalance.workflow --job-id #{job_id}"

  defp drive_health_summary(statuses) when is_list(statuses) do
    %{
      endpoints: length(statuses),
      online: Enum.count(statuses, &(Map.get(&1, :status) == :online)),
      suspect: Enum.count(statuses, &(Map.get(&1, :status) == :suspect)),
      offline: Enum.count(statuses, &(Map.get(&1, :status) == :offline)),
      heal_required: Enum.count(statuses, &Map.get(&1, :heal_required?, false)),
      identity_replacements:
        Enum.count(statuses, &Map.get(&1, :identity_replacement_detected?, false)),
      identity_heal_required: Enum.count(statuses, &Map.get(&1, :identity_heal_required?, false)),
      identity_errors: Enum.count(statuses, &Map.get(&1, :identity_error?, false))
    }
  end

  defp drive_health_summary(_statuses) do
    %{
      endpoints: 0,
      online: 0,
      suspect: 0,
      offline: 0,
      heal_required: 0,
      identity_replacements: 0,
      identity_heal_required: 0,
      identity_errors: 0
    }
  end

  defp advance_steps(opts) do
    case Keyword.get(opts, :advance_steps) do
      value when is_integer(value) and value > 0 -> value
      nil -> if(flag?(opts, :verify_closure), do: 3)
      _other -> nil
    end
  end

  defp mutating?(opts) do
    flag?(opts, :probe) or flag?(opts, :heal) or flag?(opts, :rebalance_if_needed) or
      not is_nil(Keyword.get(opts, :advance_steps)) or flag?(opts, :verify_closure)
  end

  defp not_requested, do: %{status: :not_requested}

  defp maybe_block(blockers, true, blocker), do: [blocker | blockers]
  defp maybe_block(blockers, false, _blocker), do: blockers

  defp append_blockers(blockers, values) when is_list(values), do: values ++ blockers
  defp append_blockers(blockers, _values), do: blockers

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp rename(opts, from, to) do
    case Keyword.pop(opts, from) do
      {nil, opts} -> opts
      {value, opts} -> Keyword.put(opts, to, value)
    end
  end

  defp flag?(opts, key), do: Keyword.get(opts, key, false) == true
  defp positive_integer?(value), do: is_integer(value) and value > 0

  defp probe_fun(opts), do: Keyword.get(opts, :probe_fun, &DriveHealth.probe_topology/1)
  defp snapshot_fun(opts), do: Keyword.get(opts, :snapshot_fun, &DriveHealth.snapshot/0)

  defp fresh_scheduler(opts),
    do: Keyword.get(opts, :fresh_scheduler, &FreshDriveHeal.Scheduler.run_now/1)

  defp latest_job_fun(opts) do
    Keyword.get(opts, :latest_job_fun, fn -> Jobs.latest(kind: "rebalance") end)
  end

  defp rebalance_workflow_fun(opts),
    do: Keyword.get(opts, :rebalance_workflow, &Rebalance.Workflow.summary/2)
end
