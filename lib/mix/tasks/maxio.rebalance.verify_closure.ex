defmodule Mix.Tasks.Maxio.Rebalance.VerifyClosure do
  @shortdoc "Verify and persist rebalance closure audit evidence"
  @moduledoc """
  Verify and persist rebalance placement closure audit evidence.

      mix maxio.rebalance.verify_closure JOB_ID
      mix maxio.rebalance.verify_closure --job-id <uuid> --json
      mix maxio.rebalance.verify_closure <uuid> --audit-page-size 1000

  This task writes audit evidence on the rebalance job row. It does not move
  data, delete shards, mutate topology, quarantine roots, or purge files.
  """
  use Mix.Task

  alias Maxio.Cluster.Rebalance.Closure

  @impl true
  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          job_id: :string,
          audit_page_size: :integer,
          json: :boolean
        ]
      )

    if invalid != [] or length(rest) > 1 do
      unexpected = rest ++ Enum.map(invalid, &elem(&1, 0))

      Mix.raise(
        "usage: mix maxio.rebalance.verify_closure [JOB_ID|--job-id <uuid>] " <>
          "[--audit-page-size N] [--json] (unexpected: #{inspect(unexpected)})"
      )
    end

    Mix.Task.run("app.start")

    job_id = Keyword.get(opts, :job_id) || List.first(rest)

    if is_nil(job_id) do
      Mix.raise("rebalance closure verification requires JOB_ID or --job-id <uuid>")
    end

    verify_opts =
      []
      |> maybe_put(:audit_page_size, Keyword.get(opts, :audit_page_size))

    case Closure.verify_once(job_id, verify_opts) do
      {:ok, report} -> print_or_json(report, opts)
      {:error, reason} -> Mix.raise("rebalance closure verification failed: #{inspect(reason)}")
    end
  end

  defp print_or_json(report, opts) do
    if Keyword.get(opts, :json, false) do
      IO.puts(Jason.encode!(json_ready(report)))
    else
      IO.puts(
        "[maxio rebalance.verify_closure] job_id=#{report.job_id} " <>
          "status=#{report.status} closure_status=#{report.rebalance_closure_status} " <>
          "topology_mutation=#{report.topology_mutation} physical_removal=#{report.physical_removal} " <>
          "rebalance_complete=#{report.rebalance_complete?} " <>
          "versions_scanned=#{report.versions_scanned} " <>
          "routing_mismatches=#{report.routing_mismatches} " <>
          "missing_placements=#{report.missing_placements} " <>
          "unknown_placements=#{report.unknown_placements} " <>
          "stale_topology_hashes=#{report.stale_topology_hashes} " <>
          "active_multipart_uploads=#{report.active_multipart_uploads} " <>
          "blockers=#{inspect(report.blockers)}"
      )
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp json_ready(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp json_ready(%{} = value) do
    Map.new(value, fn {key, item} -> {to_string(key), json_ready(item)} end)
  end

  defp json_ready(values) when is_list(values), do: Enum.map(values, &json_ready/1)
  defp json_ready(value) when is_boolean(value) or is_nil(value), do: value
  defp json_ready(value) when is_atom(value), do: Atom.to_string(value)
  defp json_ready(value), do: value
end
