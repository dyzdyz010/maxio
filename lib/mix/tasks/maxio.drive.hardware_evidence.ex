defmodule Mix.Tasks.Maxio.Drive.HardwareEvidence do
  @shortdoc "Print read-only drive hardware/device identity evidence"
  @moduledoc """
  Print read-only hardware/device evidence for configured drive endpoints.

      mix maxio.drive.hardware_evidence
      mix maxio.drive.hardware_evidence --summary-only
      mix maxio.drive.hardware_evidence --drive /data/drive0
      mix maxio.drive.hardware_evidence --json
      mix maxio.drive.hardware_evidence --show-raw
      mix maxio.drive.hardware_evidence --smart --smartctl-path smartctl --smart-timeout-ms 5000

  This is operator evidence only. It never writes identity state, never triggers
  heal or rebalance, and never gates physical deletion. Raw serial/WWID values
  are redacted unless `--show-raw` is explicitly supplied. SMART evidence is
  disabled by default and, when enabled, only extracts an allowlist from
  `smartctl -j -a`; it never dumps raw smartctl output.
  """
  use Mix.Task

  alias Maxio.Cluster.{DriveHardwareEvidence, Topology, TopologyStore}

  @impl true
  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          summary_only: :boolean,
          drive: :string,
          json: :boolean,
          show_raw: :boolean,
          smart: :boolean,
          smartctl_path: :string,
          smart_timeout_ms: :integer,
          smart_nocheck: :string
        ]
      )

    if rest != [] or invalid != [] do
      unexpected = rest ++ Enum.map(invalid, &elem(&1, 0))

      Mix.raise(
        "usage: mix maxio.drive.hardware_evidence [--summary-only] [--drive <path>] " <>
          "[--json] [--show-raw] [--smart] [--smartctl-path <path>] " <>
          "[--smart-timeout-ms <ms>] [--smart-nocheck never|sleep|standby|idle] " <>
          "(unexpected: #{inspect(unexpected)})"
      )
    end

    validate_smart_opts!(opts)

    summary = summary(opts)

    if Keyword.get(opts, :json, false) do
      IO.puts(Jason.encode!(json_ready(summary, Keyword.get(opts, :show_raw, false))))
    else
      print_summary(summary, mode(opts))

      unless Keyword.get(opts, :summary_only, false) do
        Enum.each(summary.samples, &print_sample(&1, Keyword.get(opts, :show_raw, false)))
      end
    end
  end

  defp mode(opts), do: if(Keyword.get(opts, :drive), do: :drive, else: :topology)

  defp summary(opts) do
    sample_opts =
      [show_raw: Keyword.get(opts, :show_raw, false)]
      |> maybe_put_opt(:smart, Keyword.get(opts, :smart))
      |> maybe_put_opt(:smartctl_path, Keyword.get(opts, :smartctl_path))
      |> maybe_put_opt(:smart_timeout_ms, Keyword.get(opts, :smart_timeout_ms))
      |> maybe_put_opt(:smart_nocheck, smart_nocheck(opts))

    case Keyword.get(opts, :drive) do
      nil -> DriveHardwareEvidence.sample_topology(topology_opts(sample_opts))
      drive -> DriveHardwareEvidence.sample_local_drive(drive, sample_opts)
    end
  end

  defp topology_opts(sample_opts) do
    if Topology.configured?() do
      sample_opts
    else
      Keyword.put(sample_opts, :topology, configured_topology())
    end
  end

  defp configured_topology do
    case topology_source() do
      :config -> config_topology()
      :db -> db_topology()
      _other -> nil
    end
  end

  defp topology_source do
    case Application.get_env(:maxio, :topology_source, :config) do
      :config -> :config
      "config" -> :config
      :db -> :db
      "db" -> :db
      other -> other
    end
  end

  defp config_topology do
    case Application.get_env(:maxio, Topology) do
      nil -> nil
      cfg -> Topology.parse_and_validate!(cfg)
    end
  rescue
    _error -> nil
  end

  defp db_topology do
    with :ok <- ensure_repo_started(),
         {:ok, topology} <- TopologyStore.active_topology() do
      topology
    else
      _reason -> nil
    end
  end

  defp ensure_repo_started do
    case Process.whereis(Maxio.Repo) do
      nil ->
        case Maxio.Repo.start_link() do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, reason} -> {:error, reason}
        end

      _pid ->
        :ok
    end
  end

  defp print_summary(summary, mode) do
    IO.puts(
      "[maxio drive.hardware_evidence] status=#{summary.status} mode=#{mode} " <>
        "topology_sets=#{summary.topology_sets} endpoints=#{summary.endpoints} " <>
        "ok=#{summary.ok} errors=#{summary.errors} " <>
        "destructive_gate=#{Map.fetch!(summary, :destructive_gate?)}"
    )
  end

  defp print_sample(%{status: :ok, endpoint: endpoint} = sample, show_raw?) do
    {node, drive} = endpoint || {nil, sample.drive}

    IO.puts(
      "[maxio drive.hardware_evidence.sample] status=ok node=#{inspect(node)} " <>
        "drive=#{inspect(drive)} set_id=#{format_value(sample.set_id)} " <>
        "endpoint_index=#{format_value(sample.endpoint_index)} " <>
        "mount_root=#{inspect(sample.mount_root)} " <>
        "mount_source=#{inspect(sample.mount_source)} fs_type=#{inspect(sample.fs_type)} " <>
        "major_minor=#{inspect(sample.major_minor)} " <>
        "block_device=#{inspect(sample.block_device)} " <>
        "parent_device=#{inspect(sample.parent_device)} " <>
        "rotational=#{format_value(Map.get(sample, :rotational?))} " <>
        "model=#{inspect(sample.model)} serial_hash=#{format_value(sample.serial_hash)} " <>
        "wwid_hash=#{format_value(sample.wwid_hash)} source=#{sample.source} " <>
        "confidence=#{sample.confidence} observed_at_ms=#{sample.observed_at_ms} " <>
        "destructive_gate=#{Map.fetch!(sample, :destructive_gate?)}" <>
        smart_suffix(sample) <>
        raw_suffix(sample, show_raw?)
    )
  end

  defp print_sample(%{status: :error, endpoint: endpoint} = sample, _show_raw?) do
    {node, drive} = endpoint || {Map.get(sample, :node), sample.drive}

    IO.puts(
      "[maxio drive.hardware_evidence.sample] status=error node=#{inspect(node)} " <>
        "drive=#{inspect(drive)} set_id=#{format_value(sample.set_id)} " <>
        "endpoint_index=#{format_value(sample.endpoint_index)} " <>
        "reason=#{inspect(sample.reason)} observed_at_ms=#{sample.observed_at_ms} " <>
        "destructive_gate=#{Map.fetch!(sample, :destructive_gate?)}"
    )
  end

  defp raw_suffix(_sample, false), do: ""

  defp raw_suffix(sample, true) do
    " serial=#{inspect(Map.get(sample, :serial))} wwid=#{inspect(Map.get(sample, :wwid))}" <>
      raw_smart_suffix(sample)
  end

  defp smart_suffix(%{smart: smart}) when is_map(smart) do
    " smart_status=#{format_value(Map.get(smart, :status))} " <>
      "smart_device=#{inspect(Map.get(smart, :device))} " <>
      "smart_exit_status=#{format_value(Map.get(smart, :exit_status))}"
  end

  defp smart_suffix(_sample), do: ""

  defp raw_smart_suffix(%{smart: smart}) when is_map(smart) do
    " smart_serial=#{inspect(Map.get(smart, :serial_number))} " <>
      "smart_wwn=#{inspect(Map.get(smart, :wwn))} " <>
      "smart_eui64=#{inspect(Map.get(smart, :eui64))} " <>
      "smart_nguid=#{inspect(Map.get(smart, :nguid))}"
  end

  defp raw_smart_suffix(_sample), do: ""

  defp json_ready(value, show_raw?)

  defp json_ready(%{} = map, show_raw?) do
    map
    |> maybe_drop_raw(show_raw?)
    |> Map.new(fn {key, value} -> {to_string(key), json_ready(value, show_raw?)} end)
  end

  defp json_ready(list, show_raw?) when is_list(list),
    do: Enum.map(list, &json_ready(&1, show_raw?))

  defp json_ready(tuple, show_raw?) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> json_ready(show_raw?)

  defp json_ready(value, _show_raw?) when is_boolean(value) or is_nil(value), do: value
  defp json_ready(atom, _show_raw?) when is_atom(atom), do: to_string(atom)
  defp json_ready(value, _show_raw?), do: value

  defp maybe_drop_raw(map, true), do: map

  defp maybe_drop_raw(map, false) do
    map
    |> Map.delete(:serial)
    |> Map.delete(:wwid)
    |> update_raw_smart(:smart)
    |> Map.delete("serial")
    |> Map.delete("wwid")
    |> update_raw_smart("smart")
  end

  defp format_value(nil), do: "nil"
  defp format_value(value), do: to_string(value)

  defp validate_smart_opts!(opts) do
    if Keyword.has_key?(opts, :smart_timeout_ms) and Keyword.fetch!(opts, :smart_timeout_ms) <= 0 do
      Mix.raise("usage: --smart-timeout-ms must be a positive integer")
    end

    if Keyword.has_key?(opts, :smart_nocheck) and is_nil(smart_nocheck(opts)) do
      Mix.raise("usage: --smart-nocheck must be one of never, sleep, standby, idle")
    end
  end

  defp smart_nocheck(opts) do
    case Keyword.get(opts, :smart_nocheck) do
      nil -> nil
      "never" -> :never
      "sleep" -> :sleep
      "standby" -> :standby
      "idle" -> :idle
      _other -> nil
    end
  end

  defp update_raw_smart(map, key) do
    case Map.fetch(map, key) do
      {:ok, smart} -> Map.put(map, key, drop_raw_smart(smart))
      :error -> map
    end
  end

  defp drop_raw_smart(nil), do: nil

  defp drop_raw_smart(%{} = smart) do
    smart
    |> Map.delete(:serial_number)
    |> Map.delete(:wwn)
    |> Map.delete(:eui64)
    |> Map.delete(:nguid)
    |> Map.delete("serial_number")
    |> Map.delete("wwn")
    |> Map.delete("eui64")
    |> Map.delete("nguid")
  end

  defp drop_raw_smart(other), do: other

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)
end
