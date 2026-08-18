defmodule Maxio.Cluster.DriveHardwareEvidence do
  @moduledoc """
  Read-only hardware/device identity evidence for configured drive roots.

  This module is an operator evidence lane. It reports mount/device/sysfs facts
  when available, hashes raw hardware identifiers by default, and never writes
  state or participates in heal, quorum, placement, or destructive gates.
  """

  alias Maxio.Cluster.{Topology, Transport}

  @type endpoint :: {node(), String.t()}
  @type evidence :: %{
          optional(:smart) => map(),
          status: :ok,
          endpoint: endpoint() | nil,
          set_id: term() | nil,
          endpoint_index: non_neg_integer() | nil,
          drive: String.t(),
          mount_root: String.t(),
          mount_source: String.t() | nil,
          fs_type: String.t() | nil,
          major_minor: String.t() | nil,
          block_device: String.t() | nil,
          parent_device: String.t() | nil,
          rotational?: boolean() | nil,
          model: String.t() | nil,
          serial_hash: String.t() | nil,
          wwid_hash: String.t() | nil,
          source: atom(),
          confidence: :high | :medium | :low,
          observed_at_ms: integer(),
          destructive_gate?: false
        }
  @type error_evidence :: %{
          status: :error,
          endpoint: endpoint() | nil,
          set_id: term() | nil,
          endpoint_index: non_neg_integer() | nil,
          drive: String.t(),
          node: node() | nil,
          reason: term(),
          observed_at_ms: integer(),
          destructive_gate?: false
        }
  @type summary :: %{
          status: :ok | :partial | :no_topology,
          topology_sets: non_neg_integer(),
          endpoints: non_neg_integer(),
          ok: non_neg_integer(),
          errors: non_neg_integer(),
          destructive_gate?: false,
          samples: [evidence() | error_evidence()]
        }

  @doc "Return hardware/device evidence for one local drive root."
  @spec local(String.t(), keyword()) :: {:ok, evidence()} | {:error, term()}
  def local(drive_root, opts \\ []) when is_binary(drive_root) do
    observed_at_ms = now_ms(opts)

    try do
      provider = provider(opts)

      drive_root
      |> provider.()
      |> normalize_provider_result(drive_root, observed_at_ms, opts)
    rescue
      e -> {:error, {:exception, Exception.message(e)}}
    catch
      kind, reason -> {:error, {kind, reason}}
    end
  end

  @doc "Return hardware/device evidence for one endpoint through the configured transport."
  @spec sample_endpoint(endpoint(), keyword()) :: evidence() | error_evidence()
  def sample_endpoint({node, drive} = endpoint, opts \\ []) when is_binary(drive) do
    observed_at_ms = now_ms(opts)
    transport = Keyword.get(opts, :transport) || Transport.impl(opts)
    set_id = Keyword.get(opts, :set_id)
    endpoint_index = Keyword.get(opts, :endpoint_index)

    result =
      try do
        transport.drive_hardware_evidence(node, drive, hardware_evidence_opts(opts, node))
      rescue
        e -> {:error, {:exception, Exception.message(e)}}
      catch
        kind, reason -> {:error, {kind, reason}}
      end

    case result do
      {:ok, sample} ->
        sample
        |> Map.put(:endpoint, normalize_endpoint(endpoint))
        |> Map.put(:set_id, set_id)
        |> Map.put(:endpoint_index, endpoint_index)

      {:error, reason} ->
        error_sample(
          endpoint,
          set_id,
          endpoint_index,
          sanitize_reason(reason, opts),
          observed_at_ms
        )
    end
  end

  @doc "Probe a bounded endpoint list and summarize per-endpoint hardware/device evidence."
  @spec sample_endpoints([endpoint()], keyword()) :: summary()
  def sample_endpoints(endpoints, opts \\ []) when is_list(endpoints) do
    set_id = Keyword.get(opts, :set_id)
    topology_sets = Keyword.get(opts, :topology_sets, 0)

    samples =
      endpoints
      |> Enum.with_index()
      |> Enum.map(fn {endpoint, endpoint_index} ->
        sample_endpoint(
          endpoint,
          opts
          |> Keyword.put(:set_id, set_id)
          |> Keyword.put(:endpoint_index, endpoint_index)
        )
      end)

    summarize(samples, topology_sets)
  end

  @doc "Probe every endpoint in a topology and summarize per-endpoint evidence."
  @spec sample_topology(keyword()) :: summary()
  def sample_topology(opts \\ []) do
    case topology_view(opts) do
      :no_topology ->
        empty_summary(:no_topology)

      view ->
        set_ids = all_set_ids(view)

        samples =
          for set_id <- set_ids,
              {endpoint, endpoint_index} <- endpoints(view, set_id) |> Enum.with_index() do
            sample_endpoint(
              endpoint,
              opts
              |> Keyword.put(:set_id, set_id)
              |> Keyword.put(:endpoint_index, endpoint_index)
            )
          end

        summarize(samples, length(set_ids))
    end
  end

  @doc "Probe one local drive path and wrap it in the same summary shape as topology probes."
  @spec sample_local_drive(String.t(), keyword()) :: summary()
  def sample_local_drive(drive_root, opts \\ []) do
    sample =
      case local(drive_root, opts) do
        {:ok, sample} ->
          sample

        {:error, reason} ->
          error_sample(nil, nil, nil, sanitize_reason(reason, opts), now_ms(opts), drive_root)
      end

    summarize([sample], 0)
  end

  @doc "Default Linux provider using mountinfo plus sysfs block-device metadata."
  @spec default_provider(String.t()) :: {:ok, map()} | {:error, term()}
  def default_provider(drive_root) when is_binary(drive_root) do
    case :os.type() do
      {:unix, :linux} ->
        with {:ok, mountinfo} <- File.read("/proc/self/mountinfo"),
             {:ok, mount} <- mount_for_path(drive_root, mountinfo) do
          {:ok,
           Map.merge(
             %{
               mount_root: mount.mount_root,
               mount_source: mount.mount_source,
               fs_type: mount.fs_type,
               major_minor: mount.major_minor,
               source: :linux_sysfs
             },
             sysfs_identity(mount)
           )}
        end

      os_type ->
        {:error, {:unsupported_os, os_type}}
    end
  end

  defp normalize_provider_result({:ok, %{} = raw}, drive_root, observed_at_ms, opts) do
    serial = maybe_string(fetch_any(raw, [:serial, "serial"]))
    wwid = maybe_string(fetch_any(raw, [:wwid, "wwid"]))

    sample = %{
      status: :ok,
      endpoint: nil,
      set_id: nil,
      endpoint_index: nil,
      drive: Path.expand(drive_root),
      mount_root: string_or_default(fetch_any(raw, [:mount_root, "mount_root"]), drive_root),
      mount_source: maybe_string(fetch_any(raw, [:mount_source, "mount_source"])),
      fs_type: maybe_string(fetch_any(raw, [:fs_type, "fs_type"])),
      major_minor: maybe_string(fetch_any(raw, [:major_minor, "major_minor", :device_id])),
      block_device: maybe_string(fetch_any(raw, [:block_device, "block_device", :device_name])),
      parent_device: maybe_string(fetch_any(raw, [:parent_device, "parent_device"])),
      rotational?: rotational(fetch_any(raw, [:rotational?, "rotational?", :rotational])),
      model: maybe_string(fetch_any(raw, [:model, "model"])),
      serial_hash: identity_hash(fetch_any(raw, [:serial_hash, "serial_hash"]), serial),
      wwid_hash: identity_hash(fetch_any(raw, [:wwid_hash, "wwid_hash"]), wwid),
      source: source(raw),
      confidence: confidence(raw, serial, wwid),
      observed_at_ms: observed_at_ms,
      destructive_gate?: false
    }

    sample =
      if Keyword.get(opts, :show_raw, false) do
        sample
        |> maybe_put(:serial, serial)
        |> maybe_put(:wwid, wwid)
      else
        sample
      end

    {:ok, maybe_attach_smart(sample, opts)}
  end

  defp normalize_provider_result({:error, reason}, _drive_root, _observed_at_ms, _opts),
    do: {:error, reason}

  defp normalize_provider_result(other, _drive_root, _observed_at_ms, _opts),
    do: {:error, {:invalid_provider_result, other}}

  defp provider(opts) do
    configured =
      opts
      |> Keyword.get(:provider)
      |> case do
        nil -> Application.get_env(:maxio, :drive_hardware_evidence, [])[:provider]
        provider -> provider
      end

    case configured do
      fun when is_function(fun, 1) ->
        fun

      {module, function} when is_atom(module) and is_atom(function) ->
        &apply(module, function, [&1])

      nil ->
        &default_provider/1

      other ->
        fn _drive_root -> {:error, {:invalid_provider, other}} end
    end
  end

  defp mount_for_path(drive_root, mountinfo) do
    normalized_drive = normalize_path(Path.expand(drive_root))

    mountinfo
    |> String.split("\n", trim: true)
    |> Enum.filter(&String.contains?(&1, " - "))
    |> Enum.flat_map(&parse_mountinfo_line/1)
    |> Enum.filter(fn mount ->
      mount_matches?(normalized_drive, normalize_path(mount.mount_root))
    end)
    |> Enum.max_by(fn mount -> String.length(normalize_path(mount.mount_root)) end, fn -> nil end)
    |> case do
      nil -> {:error, :mount_not_found}
      mount -> {:ok, mount}
    end
  end

  defp parse_mountinfo_line(line) do
    case String.split(line, " - ", parts: 2) do
      [left, right] ->
        left_fields = String.split(left)
        right_fields = String.split(right)

        with major_minor when is_binary(major_minor) <- Enum.at(left_fields, 2),
             mount_root when is_binary(mount_root) <- Enum.at(left_fields, 4),
             [major, minor] <- String.split(major_minor, ":", parts: 2),
             {major, ""} <- Integer.parse(major),
             {minor, ""} <- Integer.parse(minor) do
          [
            %{
              major: major,
              minor: minor,
              major_minor: "#{major}:#{minor}",
              mount_root: unescape_mount_path(mount_root),
              fs_type: maybe_unescape(Enum.at(right_fields, 0)),
              mount_source: maybe_unescape(Enum.at(right_fields, 1))
            }
          ]
        else
          _other -> []
        end

      _other ->
        []
    end
  end

  defp sysfs_identity(%{major_minor: major_minor, mount_source: mount_source}) do
    sys_path = "/sys/dev/block/#{major_minor}"

    {block_device, parent_device} =
      case File.read_link(sys_path) do
        {:ok, link} ->
          sys_path
          |> Path.dirname()
          |> Path.expand(link)
          |> block_devices_from_sysfs_target()

        {:error, _reason} ->
          {device_name_from_mount_source(mount_source), nil}
      end

    parent_or_block = parent_device || block_device

    %{}
    |> maybe_put(:block_device, block_device)
    |> maybe_put(:parent_device, parent_device)
    |> maybe_put(:rotational?, read_rotational(block_device, parent_or_block))
    |> maybe_put(:model, read_sysfs_identity_file(:model, block_device, parent_or_block))
    |> maybe_put(:serial, read_sysfs_identity_file(:serial, block_device, parent_or_block))
    |> maybe_put(:wwid, read_sysfs_identity_file(:wwid, block_device, parent_or_block))
  end

  defp block_devices_from_sysfs_target(target) do
    parts = Path.split(target)

    names =
      case Enum.drop_while(parts, &(&1 != "block")) do
        ["block" | rest] -> Enum.take(rest, 2)
        _other -> []
      end

    case names do
      [parent, block] -> {block, parent}
      [block] -> {block, block}
      [] -> {nil, nil}
    end
  end

  defp device_name_from_mount_source(nil), do: nil

  defp device_name_from_mount_source(source) do
    if String.starts_with?(source, "/dev/"), do: Path.basename(source), else: nil
  end

  defp read_rotational(block_device, parent_device) do
    [
      sysfs_block_path(parent_device, "queue/rotational"),
      sysfs_class_path(block_device, "queue/rotational")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.find_value(fn path ->
      case read_trimmed(path) do
        "0" -> false
        "1" -> true
        _other -> nil
      end
    end)
  end

  defp read_sysfs_identity_file(name, block_device, parent_device) do
    [
      sysfs_class_path(block_device, "device/#{name}"),
      sysfs_class_path(parent_device, "device/#{name}"),
      sysfs_block_path(parent_device, "device/#{name}")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.find_value(&read_trimmed/1)
  end

  defp sysfs_class_path(nil, _rel), do: nil
  defp sysfs_class_path(device, rel), do: Path.join(["/sys/class/block", device, rel])

  defp sysfs_block_path(nil, _rel), do: nil
  defp sysfs_block_path(device, rel), do: Path.join(["/sys/block", device, rel])

  defp read_trimmed(path) do
    case File.read(path) do
      {:ok, value} ->
        value
        |> String.trim()
        |> case do
          "" -> nil
          trimmed -> trimmed
        end

      {:error, _reason} ->
        nil
    end
  end

  defp topology_view(opts) do
    case Keyword.fetch(opts, :topology) do
      {:ok, nil} -> :no_topology
      {:ok, topology} -> {:injected, topology}
      :error -> if Topology.configured?(), do: {:configured, nil}, else: :no_topology
    end
  end

  defp all_set_ids({:configured, nil}), do: Topology.all_set_ids()
  defp all_set_ids({:injected, topology}), do: Topology.all_set_ids_from(topology)

  defp endpoints({:configured, nil}, set_id), do: Topology.endpoints(set_id)
  defp endpoints({:injected, topology}, set_id), do: Topology.endpoints_from(topology, set_id)

  defp hardware_evidence_opts(opts, node) do
    base =
      Keyword.take(opts, [
        :show_raw,
        :now_ms,
        :now_fun,
        :smart,
        :smartctl_path,
        :smart_timeout_ms,
        :smartctl_timeout_ms,
        :smart_nocheck
      ])

    if node == Node.self() do
      provider =
        Keyword.get(opts, :provider) ||
          Application.get_env(:maxio, :drive_hardware_evidence, [])[:provider]

      maybe_put_opt(base, :provider, provider)
      |> maybe_put_opt(:smart_runner, smart_runner(opts))
    else
      base
    end
  end

  defp maybe_attach_smart(sample, opts) do
    if smart_requested?(opts) do
      attach_smart(sample, opts)
    else
      sample
    end
  end

  defp smart_requested?(opts) do
    Keyword.get_lazy(opts, :smart, fn ->
      Application.get_env(:maxio, :drive_hardware_evidence, [])[:smart] || false
    end)
  end

  defp attach_smart(sample, opts) do
    case smart_device(sample) do
      {:ok, device} ->
        Map.put(sample, :smart, smart_evidence(run_smartctl(device, opts), device, opts))

      {:error, reason} ->
        Map.put(sample, :smart, unavailable_smart_evidence(nil, reason))
    end
  end

  defp smart_device(sample) do
    cond do
      present?(Map.get(sample, :parent_device)) ->
        {:ok, "/dev/#{Map.fetch!(sample, :parent_device)}"}

      present?(Map.get(sample, :block_device)) ->
        {:ok, "/dev/#{Map.fetch!(sample, :block_device)}"}

      dev_path?(Map.get(sample, :mount_source)) ->
        {:ok, Map.fetch!(sample, :mount_source)}

      true ->
        {:error, :no_block_device}
    end
  end

  defp dev_path?(value), do: is_binary(value) and String.starts_with?(value, "/dev/")

  defp run_smartctl(device, opts) do
    runner = smart_runner(opts)

    cond do
      is_function(runner, 1) ->
        normalize_smartctl_result(runner.(device))

      is_function(runner, 2) ->
        normalize_smartctl_result(runner.(device, smartctl_args(device, opts)))

      true ->
        run_system_smartctl(device, opts)
    end
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp smart_runner(opts) do
    Keyword.get_lazy(opts, :smart_runner, fn ->
      Keyword.get_lazy(opts, :smartctl_fun, fn ->
        env = Application.get_env(:maxio, :drive_hardware_evidence, [])
        env[:smart_runner] || env[:smartctl_fun]
      end)
    end)
  end

  defp run_system_smartctl(device, opts) do
    task =
      Task.async(fn ->
        smartctl_path(opts)
        |> System.cmd(smartctl_args(device, opts), stderr_to_stdout: true)
        |> case do
          {output, exit_status} -> {:ok, output, exit_status}
        end
      end)

    case Task.yield(task, smart_timeout_ms(opts)) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> normalize_smartctl_result(result)
      nil -> {:error, :timeout}
      {:exit, reason} -> {:error, {:exit, reason}}
    end
  rescue
    e in ErlangError ->
      case e.original do
        :enoent -> {:error, :smartctl_unavailable}
        reason -> {:error, {:smartctl_error, reason}}
      end
  end

  defp smartctl_path(opts) do
    Keyword.get_lazy(opts, :smartctl_path, fn ->
      Application.get_env(:maxio, :drive_hardware_evidence, [])[:smartctl_path] || "smartctl"
    end)
  end

  defp smart_timeout_ms(opts) do
    Keyword.get_lazy(opts, :smart_timeout_ms, fn ->
      Keyword.get_lazy(opts, :smartctl_timeout_ms, fn ->
        env = Application.get_env(:maxio, :drive_hardware_evidence, [])
        env[:smart_timeout_ms] || env[:smartctl_timeout_ms] || 5_000
      end)
    end)
  end

  defp smartctl_args(device, opts), do: ["-j", "-a"] ++ smart_nocheck_args(opts) ++ [device]

  defp smart_nocheck_args(opts) do
    case smart_nocheck(opts) do
      :never -> []
      mode -> ["-n", Atom.to_string(mode)]
    end
  end

  defp smart_nocheck(opts) do
    Keyword.get_lazy(opts, :smart_nocheck, fn ->
      Application.get_env(:maxio, :drive_hardware_evidence, [])[:smart_nocheck] || :standby
    end)
    |> normalize_smart_nocheck()
  end

  defp normalize_smart_nocheck(value) when value in [:never, "never"], do: :never
  defp normalize_smart_nocheck(value) when value in [:sleep, "sleep"], do: :sleep
  defp normalize_smart_nocheck(value) when value in [:standby, "standby"], do: :standby
  defp normalize_smart_nocheck(value) when value in [:idle, "idle"], do: :idle
  defp normalize_smart_nocheck(_value), do: :standby

  defp normalize_smartctl_result({:ok, output}) when is_binary(output),
    do: {:ok, output, 0}

  defp normalize_smartctl_result({:ok, output, exit_status})
       when is_binary(output) and is_integer(exit_status),
       do: {:ok, output, exit_status}

  defp normalize_smartctl_result({output, exit_status})
       when is_binary(output) and is_integer(exit_status),
       do: {:ok, output, exit_status}

  defp normalize_smartctl_result({:error, reason}), do: {:error, reason}
  defp normalize_smartctl_result(other), do: {:error, {:invalid_smartctl_result, other}}

  defp smart_evidence({:ok, output, exit_status}, device, opts) do
    case Jason.decode(output) do
      {:ok, %{} = json} ->
        smart_json_evidence(json, device, exit_status, opts)

      {:ok, _other} ->
        unavailable_smart_evidence(device, :invalid_json, exit_status)

      {:error, _reason} ->
        unavailable_smart_evidence(device, :invalid_json, exit_status)
    end
  end

  defp smart_evidence({:error, reason}, device, _opts),
    do: unavailable_smart_evidence(device, reason)

  defp smart_json_evidence(json, device, exit_status, opts) do
    %{
      status: smart_status(json),
      source: :smartctl_json,
      device: device,
      exit_status: exit_status
    }
    |> maybe_put(:exit_flags, smart_exit_flags(exit_status))
    |> maybe_put(:smart_status_passed?, smart_status_passed?(json))
    |> maybe_put(:smart_support_available?, smart_available?(json))
    |> maybe_put(:smart_support_enabled?, smart_enabled?(json))
    |> maybe_put(:model_name, smart_model_name(json))
    |> maybe_put(:firmware_version, smart_firmware_version(json))
    |> maybe_put(:serial_hash, smart_serial_hash(json))
    |> maybe_put(:wwn_hash, smart_wwn_hash(json))
    |> maybe_put(:eui64_hash, smart_eui64_hash(json))
    |> maybe_put(:nguid_hash, smart_nguid_hash(json))
    |> maybe_put(:temperature_celsius, smart_temperature_celsius(json))
    |> maybe_put(:power_on_hours, smart_power_on_hours(json))
    |> maybe_put(:power_cycle_count, smart_power_cycle_count(json))
    |> maybe_put(:reallocated_sector_count, smart_reallocated_sectors(json))
    |> maybe_put(:current_pending_sector, smart_pending_sectors(json))
    |> maybe_put(:offline_uncorrectable, smart_uncorrectable_sectors(json))
    |> maybe_put(:udma_crc_error_count, smart_udma_crc_error_count(json))
    |> maybe_put(:critical_warning, smart_critical_warning(json))
    |> maybe_put(:percentage_used, smart_percentage_used(json))
    |> maybe_put(:available_spare, smart_available_spare(json))
    |> maybe_put(:media_errors, smart_media_errors(json))
    |> maybe_put(:unsafe_shutdowns, smart_unsafe_shutdowns(json))
    |> maybe_put(:error_log_count, smart_error_log_entries(json))
    |> maybe_put(:self_test_failure_count, smart_self_test_failure_count(json))
    |> maybe_put(:latest_self_test_status, smart_latest_self_test_status(json))
    |> maybe_put_raw_smart_identity(json, opts)
  end

  defp unavailable_smart_evidence(device, reason, exit_status \\ nil) do
    %{
      status: unavailable_smart_status(reason),
      source: :smartctl_json,
      error: sanitize_smart_error(reason)
    }
    |> maybe_put(:device, device)
    |> maybe_put(:exit_status, exit_status)
  end

  defp smart_status(json) do
    case fetch_path(json, ["smart_status", "passed"]) do
      true -> :passed
      false -> :failed
      _other -> :unknown
    end
  end

  defp smart_status_passed?(json) do
    case fetch_path(json, ["smart_status", "passed"]) do
      value when is_boolean(value) -> value
      _other -> nil
    end
  end

  defp smart_exit_flags(0), do: nil

  defp smart_exit_flags(exit_status) when is_integer(exit_status) and exit_status > 0 do
    [
      {0, :command_line_parse_error},
      {1, :device_open_failed},
      {2, :command_failed},
      {3, :disk_failing},
      {4, :prefail_attributes_below_threshold},
      {5, :smart_status_failed_in_past},
      {6, :device_error_log_contains_records},
      {7, :self_test_log_contains_errors}
    ]
    |> Enum.filter(fn {bit, _flag} -> Bitwise.band(exit_status, Bitwise.bsl(1, bit)) != 0 end)
    |> Enum.map(fn {_bit, flag} -> flag end)
  end

  defp smart_exit_flags(_exit_status), do: nil

  defp smart_available?(json) do
    case fetch_path(json, ["smart_support", "available"]) do
      value when is_boolean(value) -> value
      _other -> nil
    end
  end

  defp smart_enabled?(json) do
    case fetch_path(json, ["smart_support", "enabled"]) do
      value when is_boolean(value) -> value
      _other -> nil
    end
  end

  defp smart_temperature_celsius(json) do
    fetch_path(json, ["temperature", "current"])
    |> non_negative_integer()
  end

  defp smart_power_on_hours(json) do
    fetch_path(json, ["power_on_time", "hours"])
    |> non_negative_integer()
  end

  defp smart_power_cycle_count(json) do
    fetch_path(json, ["power_cycle_count"])
    |> non_negative_integer()
  end

  defp smart_model_name(json) do
    [
      fetch_path(json, ["model_name"]),
      fetch_path(json, ["device", "model_name"]),
      fetch_path(json, ["model_family"])
    ]
    |> Enum.find_value(&maybe_string/1)
  end

  defp smart_firmware_version(json) do
    [
      fetch_path(json, ["firmware_version"]),
      fetch_path(json, ["device", "firmware_version"])
    ]
    |> Enum.find_value(&maybe_string/1)
  end

  defp smart_serial_hash(json), do: hash_smart_identity(smart_serial_number(json))
  defp smart_wwn_hash(json), do: hash_smart_identity(smart_wwn(json))
  defp smart_eui64_hash(json), do: hash_smart_identity(fetch_path(json, ["eui64"]))
  defp smart_nguid_hash(json), do: hash_smart_identity(fetch_path(json, ["nguid"]))

  defp smart_serial_number(json) do
    [
      fetch_path(json, ["serial_number"]),
      fetch_path(json, ["device", "serial_number"])
    ]
    |> Enum.find_value(&maybe_string/1)
  end

  defp smart_wwn(json) do
    case fetch_path(json, ["wwn"]) do
      %{} = wwn ->
        [
          fetch_path(wwn, ["naa"]),
          fetch_path(wwn, ["oui"]),
          fetch_path(wwn, ["id"])
        ]
        |> Enum.reject(&is_nil/1)
        |> case do
          [] -> nil
          parts -> Enum.map_join(parts, ":", &to_string/1)
        end

      value ->
        maybe_string(value)
    end
  end

  defp hash_smart_identity(value) do
    case maybe_string(value) do
      nil -> nil
      "" -> nil
      normalized -> :crypto.hash(:sha256, normalized) |> Base.encode16(case: :lower)
    end
  end

  defp smart_reallocated_sectors(json) do
    ata_smart_attr(json, ["Reallocated_Sector_Ct", "Reallocated_Event_Count"])
  end

  defp smart_pending_sectors(json) do
    ata_smart_attr(json, ["Current_Pending_Sector"])
  end

  defp smart_uncorrectable_sectors(json) do
    ata_smart_attr(json, ["Offline_Uncorrectable"])
  end

  defp smart_udma_crc_error_count(json) do
    ata_smart_attr(json, ["UDMA_CRC_Error_Count"])
  end

  defp smart_critical_warning(json) do
    fetch_path(json, ["nvme_smart_health_information_log", "critical_warning"])
    |> non_negative_integer()
  end

  defp smart_percentage_used(json) do
    fetch_path(json, ["nvme_smart_health_information_log", "percentage_used"])
    |> non_negative_integer()
  end

  defp smart_available_spare(json) do
    fetch_path(json, ["nvme_smart_health_information_log", "available_spare"])
    |> non_negative_integer()
  end

  defp smart_media_errors(json) do
    fetch_path(json, ["nvme_smart_health_information_log", "media_errors"])
    |> non_negative_integer()
  end

  defp smart_unsafe_shutdowns(json) do
    fetch_path(json, ["nvme_smart_health_information_log", "unsafe_shutdowns"])
    |> non_negative_integer()
  end

  defp smart_error_log_entries(json) do
    [
      fetch_path(json, ["ata_smart_error_log", "summary", "count"]),
      fetch_path(json, ["nvme_smart_health_information_log", "num_err_log_entries"])
    ]
    |> Enum.find_value(&non_negative_integer/1)
  end

  defp smart_self_test_failure_count(json) do
    json
    |> fetch_path(["ata_smart_self_test_log", "standard", "table"])
    |> case do
      table when is_list(table) ->
        Enum.count(table, fn
          %{"status" => %{"passed" => false}} -> true
          _other -> false
        end)

      _other ->
        nil
    end
  end

  defp smart_latest_self_test_status(json) do
    json
    |> fetch_path(["ata_smart_self_test_log", "standard", "table"])
    |> case do
      [%{"status" => %{"string" => status}} | _rest] -> maybe_string(status)
      _other -> nil
    end
  end

  defp maybe_put_raw_smart_identity(evidence, json, opts) do
    if Keyword.get(opts, :show_raw, false) do
      evidence
      |> maybe_put(:serial_number, smart_serial_number(json))
      |> maybe_put(:wwn, smart_wwn(json))
      |> maybe_put(:eui64, maybe_string(fetch_path(json, ["eui64"])))
      |> maybe_put(:nguid, maybe_string(fetch_path(json, ["nguid"])))
    else
      evidence
    end
  end

  defp ata_smart_attr(json, names) do
    json
    |> fetch_path(["ata_smart_attributes", "table"])
    |> case do
      table when is_list(table) ->
        table
        |> Enum.find_value(fn
          %{"name" => name} = attr ->
            if name in names do
              attr
              |> fetch_path(["raw", "value"])
              |> non_negative_integer()
            end

          _other ->
            nil
        end)

      _other ->
        nil
    end
  end

  defp fetch_path(value, []), do: value

  defp fetch_path(%{} = map, [key | rest]) do
    case Map.fetch(map, key) do
      {:ok, value} -> fetch_path(value, rest)
      :error -> nil
    end
  end

  defp fetch_path(_value, _path), do: nil

  defp non_negative_integer(value) when is_integer(value) and value >= 0, do: value

  defp non_negative_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer >= 0 -> integer
      _other -> nil
    end
  end

  defp non_negative_integer(_value), do: nil

  defp unavailable_smart_status(:timeout), do: :timeout
  defp unavailable_smart_status(:invalid_json), do: :invalid_json
  defp unavailable_smart_status(:permission_denied), do: :permission_denied

  defp unavailable_smart_status({:exit_status, exit_status, _output}) when exit_status != 0,
    do: :unavailable

  defp unavailable_smart_status(_reason), do: :unavailable

  defp sanitize_smart_error(reason)
       when is_atom(reason) or is_integer(reason) or is_boolean(reason),
       do: reason

  defp sanitize_smart_error({:exit_status, exit_status, _output}) when is_integer(exit_status),
    do: {:exit_status, exit_status}

  defp sanitize_smart_error({:exception, _message}), do: {:exception, "[redacted]"}

  defp sanitize_smart_error(reason) when is_tuple(reason) do
    reason
    |> Tuple.to_list()
    |> Enum.map(&sanitize_smart_error/1)
    |> List.to_tuple()
  end

  defp sanitize_smart_error(reason) when is_list(reason),
    do: Enum.map(reason, &sanitize_smart_error/1)

  defp sanitize_smart_error(reason) when is_binary(reason), do: "[redacted]"
  # nil 由首个 is_atom/1 子句原样返回，无需单列。
  defp sanitize_smart_error(%{} = reason), do: redact_reason(reason)
  defp sanitize_smart_error(_reason), do: :redacted

  defp summarize(samples, set_count) do
    ok_samples = Enum.filter(samples, &sample_ok?/1)
    errors = length(samples) - length(ok_samples)

    status =
      cond do
        samples == [] -> :no_topology
        errors == 0 -> :ok
        true -> :partial
      end

    %{
      status: status,
      topology_sets: set_count,
      endpoints: length(samples),
      ok: length(ok_samples),
      errors: errors,
      destructive_gate?: false,
      samples: samples
    }
  end

  defp empty_summary(status) do
    %{
      status: status,
      topology_sets: 0,
      endpoints: 0,
      ok: 0,
      errors: 0,
      destructive_gate?: false,
      samples: []
    }
  end

  defp error_sample(endpoint, set_id, endpoint_index, reason, observed_at_ms, drive \\ nil) do
    {node, drive} =
      case endpoint do
        {node, endpoint_drive} -> {node, endpoint_drive}
        nil -> {nil, drive}
      end

    %{
      status: :error,
      endpoint: if(endpoint, do: normalize_endpoint(endpoint), else: nil),
      set_id: set_id,
      endpoint_index: endpoint_index,
      drive: if(drive, do: Path.expand(drive), else: "nil"),
      node: node,
      reason: reason,
      observed_at_ms: observed_at_ms,
      destructive_gate?: false
    }
  end

  defp sanitize_reason(reason, opts) do
    if Keyword.get(opts, :show_raw, false), do: reason, else: redact_reason(reason)
  end

  defp redact_reason(reason) when is_atom(reason) or is_integer(reason) or is_boolean(reason),
    do: reason

  # nil 由上面的 is_atom/1 子句原样返回，无需单列。
  defp redact_reason(reason) when is_binary(reason), do: "[redacted]"

  defp redact_reason(reason) when is_tuple(reason) do
    reason
    |> Tuple.to_list()
    |> Enum.map(&redact_reason/1)
    |> List.to_tuple()
  end

  defp redact_reason(reason) when is_list(reason), do: Enum.map(reason, &redact_reason/1)

  defp redact_reason(%{} = reason) do
    Map.new(reason, fn {key, value} ->
      {redact_reason_key(key), redact_reason(value)}
    end)
  end

  defp redact_reason(_reason), do: :redacted

  defp redact_reason_key(key) when is_atom(key), do: key
  defp redact_reason_key(key) when is_binary(key), do: "[redacted]"
  defp redact_reason_key(key) when is_integer(key), do: key
  defp redact_reason_key(_key), do: :redacted

  defp sample_ok?(%{status: :ok}), do: true
  defp sample_ok?(_sample), do: false

  defp normalize_endpoint({node, drive}), do: {node, Path.expand(drive)}

  defp confidence(raw, serial, wwid) do
    explicit = fetch_any(raw, [:confidence, "confidence"])

    cond do
      explicit in [:high, :medium, :low] ->
        explicit

      is_binary(explicit) and explicit in ["high", "medium", "low"] ->
        String.to_existing_atom(explicit)

      present?(serial) or present?(wwid) or
        present?(fetch_any(raw, [:serial_hash, "serial_hash"])) or
          present?(fetch_any(raw, [:wwid_hash, "wwid_hash"])) ->
        :high

      present?(fetch_any(raw, [:block_device, "block_device", :device_name])) and
          present?(fetch_any(raw, [:major_minor, "major_minor", :device_id])) ->
        :medium

      true ->
        :low
    end
  end

  defp source(raw) do
    case fetch_any(raw, [:source, "source"]) do
      source when is_atom(source) -> source
      source when is_binary(source) -> existing_atom(source, :unknown)
      _other -> :unknown
    end
  end

  defp existing_atom(value, default) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> default
  end

  defp identity_hash(hash, _raw) when is_binary(hash) and hash != "" do
    case normalized_sha256(hash) do
      {:ok, normalized} -> normalized
      :error -> :crypto.hash(:sha256, hash) |> Base.encode16(case: :lower)
    end
  end

  defp identity_hash(_hash, nil), do: nil

  defp identity_hash(_hash, raw),
    do: :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)

  defp normalized_sha256(value) do
    normalized = String.downcase(value)

    if String.match?(normalized, ~r/\A[0-9a-f]{64}\z/) do
      {:ok, normalized}
    else
      :error
    end
  end

  defp rotational(value) when is_boolean(value), do: value
  defp rotational(0), do: false
  defp rotational(1), do: true
  defp rotational("0"), do: false
  defp rotational("1"), do: true
  defp rotational("false"), do: false
  defp rotational("true"), do: true
  defp rotational(_value), do: nil

  defp fetch_any(map, keys) do
    Enum.reduce_while(keys, nil, fn key, _acc ->
      case Map.fetch(map, key) do
        {:ok, nil} -> {:cont, nil}
        {:ok, value} -> {:halt, value}
        :error -> {:cont, nil}
      end
    end)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp string_or_default(nil, drive_root), do: Path.expand(drive_root)
  defp string_or_default(value, _drive_root), do: to_string(value)

  defp maybe_string(nil), do: nil
  defp maybe_string(value), do: to_string(value)

  defp present?(value), do: maybe_string(value) not in [nil, ""]

  defp mount_matches?(normalized_drive, "/"), do: String.starts_with?(normalized_drive, "/")

  defp mount_matches?(normalized_drive, mount),
    do: normalized_drive == mount or String.starts_with?(normalized_drive, mount <> "/")

  defp normalize_path(path) do
    path
    |> String.replace("\\", "/")
    |> String.trim_trailing("/")
    |> String.downcase()
    |> case do
      "" -> "/"
      mount -> mount
    end
  end

  defp maybe_unescape(nil), do: nil
  defp maybe_unescape(value), do: unescape_mount_path(value)

  defp unescape_mount_path(path) do
    Regex.replace(~r/\\([0-7]{3})/, path, fn _, octal ->
      octal |> String.to_integer(8) |> List.wrap() |> to_string()
    end)
  end

  defp now_ms(opts) do
    cond do
      is_integer(Keyword.get(opts, :now_ms)) -> Keyword.fetch!(opts, :now_ms)
      is_function(Keyword.get(opts, :now_fun), 0) -> opts |> Keyword.fetch!(:now_fun) |> apply([])
      true -> System.monotonic_time(:millisecond)
    end
  end
end
