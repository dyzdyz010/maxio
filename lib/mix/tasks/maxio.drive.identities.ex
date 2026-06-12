defmodule Mix.Tasks.Maxio.Drive.Identities do
  @shortdoc "List and optionally probe persistent cluster drive identities"
  @moduledoc """
  List the persisted software identity for configured cluster drive endpoints.

      mix maxio.drive.identities
      mix maxio.drive.identities --heal-required
      mix maxio.drive.identities --summary-only
      mix maxio.drive.identities --probe
      mix maxio.drive.identities --probe --no-create-missing
      mix maxio.drive.identities --probe --marker-file .custom-drive-id.json

  `--probe` walks the currently configured topology and observes each endpoint
  through the configured `Maxio.Cluster.Transport` implementation before
  printing the persisted inventory. By default, a probe creates missing marker
  files on reachable configured endpoints; `--no-create-missing` turns missing
  markers into explicit probe errors.
  """
  use Mix.Task

  alias Maxio.Cluster.{DriveIdentity, Topology, Transport}

  @impl true
  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          probe: :boolean,
          heal_required: :boolean,
          summary_only: :boolean,
          no_create_missing: :boolean,
          marker_file: :string
        ]
      )

    if rest != [] or invalid != [] do
      unexpected = rest ++ Enum.map(invalid, &elem(&1, 0))

      Mix.raise(
        "usage: mix maxio.drive.identities [--probe] [--no-create-missing] " <>
          "[--marker-file <name>] [--heal-required] [--summary-only] " <>
          "(unexpected: #{inspect(unexpected)})"
      )
    end

    marker_file = marker_file_opt(opts)

    Mix.Task.run("app.start")

    probe? = Keyword.get(opts, :probe, false)
    mode = if probe?, do: :probe, else: :snapshot

    {topology_sets, endpoints, probe_results} =
      if probe? do
        probe_topology(
          create_missing: not Keyword.get(opts, :no_create_missing, false),
          marker_file: marker_file
        )
      else
        {0, 0, []}
      end

    statuses = DriveIdentity.snapshot(heal_required: Keyword.get(opts, :heal_required, false))
    probe_errors = Enum.filter(probe_results, &match?({:error, _endpoint, _set_id, _idx, _}, &1))
    probe_ok = length(probe_results) - length(probe_errors)
    heal_required = Enum.count(statuses, & &1.identity_heal_required?)
    replacements = Enum.count(statuses, &(&1.previous_drive_uuid != nil))
    status = summary_status(probe?, topology_sets, probe_errors)

    IO.puts(
      "[maxio drive.identities] status=#{status} mode=#{mode} topology_sets=#{topology_sets} " <>
        "endpoints=#{endpoints} probed=#{length(probe_results)} ok=#{probe_ok} " <>
        "errors=#{length(probe_errors)} total=#{length(statuses)} " <>
        "heal_required=#{heal_required} replacements=#{replacements}"
    )

    unless Keyword.get(opts, :summary_only, false) do
      Enum.each(probe_errors, &print_probe_error/1)
      Enum.each(statuses, &print_status/1)
    end
  end

  defp probe_topology(opts) do
    if Topology.configured?() do
      transport = Transport.impl()
      set_ids = Topology.all_set_ids()

      results =
        for set_id <- set_ids,
            {endpoint, endpoint_index} <- Topology.endpoints(set_id) |> Enum.with_index() do
          probe_opts =
            [
              transport: transport,
              set_id: set_id,
              endpoint_index: endpoint_index,
              create_missing: Keyword.fetch!(opts, :create_missing)
            ]
            |> maybe_put(:marker_file, opts[:marker_file])

          case DriveIdentity.probe_endpoint(endpoint, probe_opts) do
            {:ok, status} -> {:ok, status}
            {:error, reason} -> {:error, endpoint, set_id, endpoint_index, reason}
          end
        end

      endpoints =
        Enum.reduce(set_ids, 0, fn set_id, count ->
          count + length(Topology.endpoints(set_id))
        end)

      {length(set_ids), endpoints, results}
    else
      {0, 0, []}
    end
  end

  defp summary_status(false, _topology_sets, _probe_errors), do: :ok
  defp summary_status(true, 0, _probe_errors), do: :no_topology
  defp summary_status(true, _topology_sets, []), do: :ok
  defp summary_status(true, _topology_sets, _probe_errors), do: :partial

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp marker_file_opt(opts) do
    case Keyword.get(opts, :marker_file) do
      nil ->
        nil

      name when is_binary(name) ->
        if valid_marker_file_name?(name) do
          name
        else
          Mix.raise(
            "invalid --marker-file #{inspect(name)}; expected a file name without path separators"
          )
        end
    end
  end

  defp valid_marker_file_name?(name) do
    name != "" and name not in [".", ".."] and not String.contains?(name, ["/", "\\"])
  end

  defp print_probe_error({:error, {node, drive}, set_id, endpoint_index, reason}) do
    IO.puts(
      "[maxio drive.identity] status=error node=#{inspect(node)} drive=#{inspect(Path.expand(drive))} " <>
        "set_id=#{format_value(set_id)} endpoint_index=#{format_value(endpoint_index)} " <>
        "reason=#{inspect(reason)}"
    )
  end

  defp print_status(%{endpoint: {node, drive}} = status) do
    IO.puts(
      "[maxio drive.identity] status=ok node=#{inspect(node)} drive=#{inspect(drive)} " <>
        "set_id=#{format_value(status.set_id)} " <>
        "endpoint_index=#{format_value(status.endpoint_index)} " <>
        "drive_uuid=#{status.drive_uuid} " <>
        "previous_drive_uuid=#{format_value(status.previous_drive_uuid)} " <>
        "generation=#{status.generation} " <>
        "heal_required=#{status.identity_heal_required?} " <>
        "replaced=#{status.previous_drive_uuid != nil} " <>
        "first_seen_at=#{format_value(status.first_seen_at)} " <>
        "last_seen_at=#{format_value(status.last_seen_at)} " <>
        "replacement_detected_at=#{format_value(status.replacement_detected_at)} " <>
        "healed_at=#{format_value(status.healed_at)}"
    )
  end

  defp format_value(nil), do: "nil"
  defp format_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp format_value(value), do: to_string(value)
end
