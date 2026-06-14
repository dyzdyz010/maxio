defmodule Mix.Tasks.Maxio.Rebalance.PhysicalRemove do
  @shortdoc "Quarantine Maxio layout roots for a verified decommission job"
  @moduledoc """
  Quarantine Maxio-owned layout roots on the stored removed endpoint manifest.

      mix maxio.rebalance.physical_remove --job-id <uuid> --confirm-job-id <uuid>
      mix maxio.rebalance.physical_remove <uuid> --confirm-job-id <uuid> --json
      mix maxio.rebalance.physical_remove <uuid> --confirm-job-id <uuid> --hardware-evidence

  This command requires deployment verification to be complete and reruns the
  read-only physical-removal preflight under the runtime topology mutation lock.
  It moves known Maxio layout roots into `.maxio-removal-quarantine/<id>` on the
  same drive. It does not delete whole drive roots, hard-delete quarantine
  contents, mutate topology, rewrite deployment config, or run automatically.
  `--hardware-evidence` persists a sanitized, read-only hardware evidence
  snapshot in the job results and is not a destructive gate.
  """
  use Mix.Task

  alias Maxio.Cluster.Rebalance.PhysicalRemoval

  @impl true
  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          job_id: :string,
          confirm_job_id: :string,
          hardware_evidence: :boolean,
          drive_hardware_evidence: :boolean,
          json: :boolean
        ]
      )

    job_id = Keyword.get(opts, :job_id) || List.first(rest)
    extra = if job_id && rest == [job_id], do: [], else: rest

    if extra != [] or invalid != [] do
      unexpected = extra ++ Enum.map(invalid, &elem(&1, 0))
      Mix.raise("#{usage()} (unexpected: #{inspect(unexpected)})")
    end

    confirm_job_id = Keyword.get(opts, :confirm_job_id)

    if is_nil(job_id) or confirm_job_id != job_id do
      Mix.raise(usage())
    end

    Mix.Task.run("app.start")

    case PhysicalRemoval.apply(job_id,
           confirm_job_id: confirm_job_id,
           drive_hardware_evidence: hardware_evidence_requested?(opts)
         ) do
      {:ok, report} -> print_or_json(opts, report)
      {:error, reason} -> Mix.raise(error_message(reason))
    end
  end

  defp usage do
    "usage: mix maxio.rebalance.physical_remove " <>
      "[JOB_ID|--job-id <uuid>] --confirm-job-id <same uuid> [--hardware-evidence] [--json]"
  end

  defp hardware_evidence_requested?(opts) do
    Keyword.get(opts, :hardware_evidence, false) or
      Keyword.get(opts, :drive_hardware_evidence, false)
  end

  defp print_or_json(opts, report) do
    if Keyword.get(opts, :json, false) do
      IO.puts(Jason.encode!(json_ready(report)))
    else
      evidence = report.drive_hardware_evidence

      IO.puts(
        "[maxio rebalance.physical_remove] job_id=#{report.job_id} " <>
          "status=#{report.status} target_set_id=#{report.target_set_id} " <>
          "quarantine_id=#{report.quarantine_id} endpoints=#{report.endpoints} " <>
          "roots_quarantined=#{report.roots_quarantined} " <>
          "markers_written=#{report.markers_written} errors=#{report.errors} " <>
          "drive_hardware_evidence_status=#{evidence_value(evidence, :status)} " <>
          "drive_hardware_evidence_ok=#{evidence_value(evidence, :ok, 0)} " <>
          "drive_hardware_evidence_errors=#{evidence_value(evidence, :errors, 0)} " <>
          "drive_hardware_evidence_gate=false " <>
          "physical_removal=layout_quarantine topology_mutation=false " <>
          "deployment_config_mutation=false"
      )
    end
  end

  defp error_message(:physical_removal_confirmation_required), do: usage()

  defp error_message({:physical_removal_preflight_blocked, report}),
    do: "physical removal preflight blocked: #{inspect(report.blockers)}"

  defp error_message({:physical_removal_failed, report}),
    do: "physical removal failed: #{inspect(report.results)}"

  defp error_message(reason), do: "physical removal failed: #{inspect(reason)}"

  defp evidence_value(%{} = evidence, key, default \\ nil) do
    Map.get(evidence, to_string(key), Map.get(evidence, key, default))
  end

  defp json_ready(nil), do: nil
  defp json_ready(value) when is_boolean(value), do: value
  defp json_ready(value) when is_atom(value), do: Atom.to_string(value)
  defp json_ready(value) when is_tuple(value), do: value |> Tuple.to_list() |> json_ready()
  defp json_ready(value) when is_list(value), do: Enum.map(value, &json_ready/1)

  defp json_ready(%{} = value),
    do: Map.new(value, fn {key, item} -> {to_string(key), json_ready(item)} end)

  defp json_ready(value), do: value
end
