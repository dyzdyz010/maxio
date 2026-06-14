defmodule Mix.Tasks.Maxio.Rebalance.PhysicalRemovalPreflight do
  @shortdoc "Preflight a verified decommission job for later physical removal"
  @moduledoc """
  Run the read-only post-deployment safety preflight before any later physical
  removal of a decommissioned set's stored endpoint roots.

      mix maxio.rebalance.physical_removal_preflight [JOB_ID|--job-id <uuid>]
      mix maxio.rebalance.physical_removal_preflight --job-id <uuid> --json
      mix maxio.rebalance.physical_removal_preflight --job-id <uuid> --hardware-evidence

  The command uses the target endpoint manifest captured before topology
  removal. It does not infer removed endpoints from current topology and never
  deletes files. `--hardware-evidence` attaches a sanitized, read-only hardware
  evidence snapshot and is not a destructive gate.
  """
  use Mix.Task

  alias Maxio.Cluster.Rebalance.{Jobs, TopologyMutation}

  @impl true
  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          job_id: :string,
          hardware_evidence: :boolean,
          drive_hardware_evidence: :boolean,
          json: :boolean
        ]
      )

    job_id = Keyword.get(opts, :job_id) || List.first(rest)
    extra = if job_id && rest == [job_id], do: [], else: rest

    if extra != [] or invalid != [] do
      unexpected = extra ++ Enum.map(invalid, &elem(&1, 0))

      Mix.raise(
        "usage: mix maxio.rebalance.physical_removal_preflight " <>
          "[JOB_ID|--job-id <uuid>] [--hardware-evidence] [--json] " <>
          "(unexpected: #{inspect(unexpected)})"
      )
    end

    Mix.Task.run("app.start")

    with {:ok, job_id} <- resolve_job_id(job_id),
         {:ok, report} <-
           TopologyMutation.physical_removal_preflight(job_id,
             drive_hardware_evidence: hardware_evidence_requested?(opts)
           ) do
      print_or_json(opts, report)
    else
      {:error, reason} -> Mix.raise(error_message(reason))
    end
  end

  defp resolve_job_id(job_id) when is_binary(job_id), do: {:ok, job_id}

  defp resolve_job_id(nil) do
    case Jobs.latest(kind: "decommission") do
      nil -> {:error, :not_found}
      job -> {:ok, job.id}
    end
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
        "[maxio rebalance.physical_removal_preflight] job_id=#{report.job_id} " <>
          "status=#{report.status} target_set_id=#{report.target_set_id} " <>
          "destination_set_id=#{report.destination_set_id} removable=#{report.removable} " <>
          "blockers=#{inspect(report.blockers)} endpoints=#{report.endpoints} " <>
          "endpoint_errors=#{report.endpoint_errors} physical_residuals=#{report.physical_residuals} " <>
          "physical_bucket_roots=#{report.physical_bucket_roots} " <>
          "physical_version_roots=#{report.physical_version_roots} " <>
          "bucket_markers=#{report.bucket_markers} " <>
          "drive_hardware_evidence_status=#{evidence.status} " <>
          "drive_hardware_evidence_ok=#{evidence.ok} " <>
          "drive_hardware_evidence_errors=#{evidence.errors} " <>
          "drive_hardware_evidence_gate=false physical_removal=false"
      )
    end
  end

  defp error_message(:not_found), do: "no decommission job found"

  defp error_message({:unsupported_job_kind, kind}),
    do: "physical_removal_preflight only supports decommission jobs, got kind=#{inspect(kind)}"

  defp error_message(reason),
    do: "rebalance physical removal preflight failed: #{inspect(reason)}"

  defp json_ready(nil), do: nil
  defp json_ready(value) when is_boolean(value), do: value
  defp json_ready(value) when is_atom(value), do: Atom.to_string(value)
  defp json_ready(value) when is_tuple(value), do: value |> Tuple.to_list() |> json_ready()
  defp json_ready(value) when is_list(value), do: Enum.map(value, &json_ready/1)

  defp json_ready(%{} = value),
    do: Map.new(value, fn {key, item} -> {to_string(key), json_ready(item)} end)

  defp json_ready(value), do: value
end
