defmodule Maxio.Ops.ScanEvidenceConsole do
  @moduledoc """
  Read-only projection for scanner, reconcile, and drive-health evidence.

  This module deliberately reads only configuration, snapshots, and archived ops
  gate artifacts. It must not call scan/reconcile/heal/probe functions.
  """

  alias Maxio.{Buckets, ObjectMeta, Storage}
  alias Maxio.Cluster.{DriveHealth, DriveIdentity, Topology}
  alias Maxio.Cluster.Scrubber.Usage
  alias Maxio.Ops.Gate.Artifacts, as: GateArtifacts

  @max_text_length 256
  @max_rows 100
  @max_artifacts 10
  @max_fields 16
  @usage_default_stale_after_ms 172_800_000

  @spec load(keyword()) :: map()
  def load(opts \\ []) do
    now = Keyword.get(opts, :now) || DateTime.utc_now()
    scrubber_config = scrubber_config(opts)

    usage =
      usage_snapshots(
        bucket_names(opts),
        option(opts, :usage_snapshots, fn -> Usage.all() end),
        now,
        usage_stale_after_ms(opts, scrubber_config)
      )

    drive_health =
      drive_health(option(opts, :drive_health_snapshot, fn -> DriveHealth.snapshot() end))

    drive_identities =
      drive_identities(option(opts, :drive_identity_snapshot, fn -> DriveIdentity.snapshot() end))

    archived_evidence =
      archived_evidence(
        option(opts, :gate_artifacts, fn -> GateArtifacts.list_recent(limit: @max_artifacts) end),
        now,
        opts
      )

    %{
      status:
        rollup_status([
          usage.status,
          drive_health.status,
          drive_identities.status,
          archived_evidence.status
        ]),
      authority_rows: authority_rows(opts, scrubber_config),
      topology_rows:
        topology_rows(option(opts, :topology_snapshot, fn -> Topology.runtime_snapshot() end)),
      usage_snapshots: usage,
      drive_health: drive_health,
      drive_identities: drive_identities,
      archived_evidence: archived_evidence,
      readonly_boundary: readonly_boundary()
    }
  end

  defp authority_rows(opts, scrubber_config) do
    storage_backend = option(opts, :storage_backend, fn -> Storage.backend() end)

    drive_health_config =
      Keyword.get(opts, :drive_health_config, Application.get_env(:maxio, :drive_health, []))

    drive_identity_config =
      Keyword.get(opts, :drive_identity_config, Application.get_env(:maxio, :drive_identity, []))

    [
      row("authority-read", "authoritative_source(:read)", source_value(opts, :read)),
      row("authority-list", "authoritative_source(:list)", source_value(opts, :list)),
      row("authority-write", "authoritative_source(:write)", source_value(opts, :write)),
      row("storage-backend", "storage_backend", module_value(storage_backend)),
      row("scrubber-enabled", "scrubber.enabled", scrubber_config[:enabled]),
      row("scrubber-interval-ms", "scrubber.interval_ms", scrubber_config[:interval_ms]),
      row("scrubber-page-size", "scrubber.page_size", scrubber_config[:page_size]),
      row("scrubber-scan-versions", "scrubber.scan_versions", scrubber_config[:scan_versions]),
      row(
        "scrubber-reconcile-index",
        "scrubber.reconcile_index",
        scrubber_config[:reconcile_index]
      ),
      row(
        "scrubber-reconcile-dry-run",
        "scrubber.reconcile_index_dry_run",
        scrubber_config[:reconcile_index_dry_run]
      ),
      row(
        "scrubber-drive-health",
        "scrubber.drive_health_enabled",
        scrubber_config[:drive_health_enabled]
      ),
      row(
        "drive-offline-after-ms",
        "drive_health.offline_after_ms",
        scrubber_config[:drive_offline_after_ms]
      ),
      row(
        "drive-health-config-enabled",
        "drive_health.config_enabled",
        Keyword.get(drive_health_config, :enabled, true)
      ),
      row(
        "drive-identity-config-enabled",
        "drive_identity.config_enabled",
        Keyword.get(drive_identity_config, :enabled, true)
      )
    ]
  end

  defp topology_rows(snapshot) when is_map(snapshot) do
    [
      row("topology-node", "runtime_node", value(snapshot, :node)),
      row("topology-status", "runtime_status", value(snapshot, :runtime_status)),
      row("topology-hash", "topology_hash", value(snapshot, :topology_hash)),
      row("topology-set-ids", "set_ids", value(snapshot, :set_ids)),
      row("topology-pool-ids", "pool_ids", value(snapshot, :pool_ids))
    ]
    |> present_rows()
  end

  defp topology_rows(_snapshot), do: []

  defp usage_snapshots(bucket_names, snapshots, now, stale_after_ms) when is_map(snapshots) do
    snapshot_names = snapshots |> Map.keys() |> Enum.map(&to_string/1)

    rows =
      (bucket_names ++ snapshot_names)
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.take(@max_rows)
      |> Enum.map(fn bucket ->
        snapshot = snapshot_for_bucket(snapshots, bucket)
        usage_row(bucket, snapshot, now, stale_after_ms)
      end)

    stale_count = Enum.count(rows, &(&1.status == "stale"))
    missing_count = Enum.count(rows, &(&1.status == "missing"))

    %{
      status: usage_status(rows, stale_count, missing_count),
      stale_count: stale_count,
      missing_count: missing_count,
      rows: rows
    }
  end

  defp usage_snapshots(bucket_names, _snapshots, now, stale_after_ms),
    do: usage_snapshots(bucket_names, %{}, now, stale_after_ms)

  defp usage_row(bucket, snapshot, now, stale_after_ms)
       when is_map(snapshot) and map_size(snapshot) > 0 do
    scanned_at = value(snapshot, :scanned_at)
    age_ms = age_ms(scanned_at, now)
    status = if is_integer(age_ms) and age_ms > stale_after_ms, do: "stale", else: "ok"

    %{
      id: safe_id(bucket),
      bucket: text(bucket),
      status: status,
      object_count: int_value(value(snapshot, :object_count)),
      total_size: int_value(value(snapshot, :total_size)),
      scanned_at: datetime_value(scanned_at),
      age_ms: age_ms
    }
  end

  defp usage_row(bucket, _snapshot, _now, _stale_after_ms) do
    %{
      id: safe_id(bucket),
      bucket: text(bucket),
      status: "missing",
      object_count: 0,
      total_size: 0,
      scanned_at: nil,
      age_ms: nil
    }
  end

  defp snapshot_for_bucket(snapshots, bucket) do
    case Map.fetch(snapshots, bucket) do
      {:ok, snapshot} ->
        snapshot

      :error ->
        Enum.find_value(snapshots, %{}, fn {key, snapshot} ->
          if to_string(key) == bucket, do: snapshot
        end)
    end
  end

  defp drive_health(statuses) when is_list(statuses) do
    rows =
      statuses
      |> Enum.take(@max_rows)
      |> Enum.map(&drive_health_row/1)

    counts = %{
      total: length(rows),
      online: Enum.count(rows, &(&1.status == "online")),
      suspect: Enum.count(rows, &(&1.status == "suspect")),
      offline: Enum.count(rows, &(&1.status == "offline")),
      heal_required: Enum.count(rows, &(&1.heal_required? == "true")),
      identity_replacements: Enum.count(rows, &(&1.identity_replacement_detected? == "true")),
      identity_errors: Enum.count(rows, &(&1.identity_error? == "true"))
    }

    %{
      source: "node_local_runtime",
      status: drive_health_status(rows, counts),
      counts: counts,
      rows: rows
    }
  end

  defp drive_health(_statuses), do: drive_health([])

  defp drive_health_row(status) when is_map(status) do
    endpoint = endpoint_value(value(status, :endpoint))

    %{
      id: safe_id(endpoint),
      endpoint: endpoint,
      status: value_text(value(status, :status), "unknown"),
      failure_count: int_value(value(status, :failure_count)),
      set_id: value_text(value(status, :set_id), "-"),
      last_reason: value_text(value(status, :last_reason), "-"),
      heal_required?: bool_text(value(status, :heal_required?)),
      identity_heal_required?: bool_text(value(status, :identity_heal_required?)),
      identity_replacement_detected?: bool_text(value(status, :identity_replacement_detected?)),
      identity_error?: bool_text(value(status, :identity_error?))
    }
  end

  defp drive_health_row(_status), do: drive_health_row(%{})

  defp drive_identities(statuses) when is_list(statuses) do
    rows =
      statuses
      |> Enum.take(@max_rows)
      |> Enum.map(&drive_identity_row/1)

    counts = %{
      total: length(rows),
      heal_required: Enum.count(rows, &(&1.identity_heal_required? == "true")),
      replacements: Enum.count(rows, &(&1.replacement_detected? == "true"))
    }

    %{
      source: "postgres_persisted_drive_identity",
      status: drive_identity_status(rows, counts),
      counts: counts,
      rows: rows
    }
  end

  defp drive_identities(_statuses), do: drive_identities([])

  defp drive_identity_row(status) when is_map(status) do
    endpoint = endpoint_value(value(status, :endpoint))
    previous_uuid = value(status, :previous_drive_uuid)

    replacement_detected? =
      truthy?(value(status, :replacement_detected?)) or present?(previous_uuid) or
        present?(value(status, :replacement_detected_at))

    %{
      id: safe_id(endpoint),
      endpoint: endpoint,
      generation: int_value(value(status, :generation)),
      set_id: value_text(value(status, :set_id), "-"),
      endpoint_index: value_text(value(status, :endpoint_index), "-"),
      drive_uuid: fingerprint(value(status, :drive_uuid)),
      previous_drive_uuid: fingerprint(previous_uuid),
      identity_heal_required?: bool_text(value(status, :identity_heal_required?)),
      replacement_detected?: bool_text(replacement_detected?),
      first_seen_at: datetime_value(value(status, :first_seen_at)),
      last_seen_at: datetime_value(value(status, :last_seen_at)),
      replacement_detected_at: datetime_value(value(status, :replacement_detected_at)),
      healed_at: datetime_value(value(status, :healed_at))
    }
  end

  defp drive_identity_row(_status), do: drive_identity_row(%{})

  defp archived_evidence(artifacts, now, opts) when is_list(artifacts) do
    stale_after_ms = Keyword.get(opts, :artifact_stale_after_ms, @usage_default_stale_after_ms)

    rows =
      artifacts
      |> Enum.flat_map(&artifact_evidence_rows/1)
      |> Enum.take(@max_rows)

    latest_relevant = latest_relevant_artifact(artifacts)

    warnings =
      []
      |> maybe_stale_artifact_warning(latest_relevant, now, stale_after_ms)

    %{
      status: archived_status(rows, warnings),
      latest_artifact: artifact_summary(latest_relevant),
      rows: rows,
      warnings: warnings
    }
  end

  defp archived_evidence(_artifacts, now, opts), do: archived_evidence([], now, opts)

  defp artifact_evidence_rows(artifact) when is_map(artifact) do
    artifact
    |> value(:checks)
    |> list_value()
    |> Enum.filter(&scan_or_drive_check?/1)
    |> Enum.map(&artifact_evidence_row(artifact, &1))
  end

  defp artifact_evidence_rows(_artifact), do: []

  defp latest_relevant_artifact(artifacts) do
    Enum.find(artifacts, fn artifact ->
      artifact_evidence_rows(artifact) != []
    end)
  end

  defp scan_or_drive_check?(check) when is_map(check) do
    summary = value(check, :evidence_summary)
    kind = value(summary || %{}, :kind)
    task = value(check, :task)
    id = value(check, :id)

    kind in ["scan", "fresh_drive_heal"] or
      task in ["maxio.reconcile_index", "maxio.scan", "maxio.heal.fresh_drives"] or
      id in ["scanner_reconcile", "foreground_scan", "fresh_drive_heal"]
  end

  defp scan_or_drive_check?(_check), do: false

  defp artifact_evidence_row(artifact, check) do
    summary = value(check, :evidence_summary) || %{}
    fields = summary |> value(:fields) |> list_value() |> Enum.take(@max_fields)

    %{
      id:
        safe_id(
          "#{value_text(value(artifact, :file_name), "artifact")}-#{value_text(value(check, :id), "check")}"
        ),
      artifact_file_name: value_text(value(artifact, :file_name), "-"),
      artifact_run_id: value_text(value(artifact, :run_id), "-"),
      artifact_generated_at: value_text(value(artifact, :generated_at), "-"),
      artifact_gate_status: value_text(value(artifact, :gate_status), "unknown"),
      check_id: value_text(value(check, :id), "unknown"),
      task: value_text(value(check, :task), "unknown"),
      status: value_text(value(check, :status), "unknown"),
      kind: value_text(value(summary, :kind), "unknown"),
      title: value_text(value(summary, :title), "Archived Evidence"),
      fields: Enum.map(fields, &summary_field/1)
    }
  end

  defp artifact_summary(nil), do: nil

  defp artifact_summary(artifact) when is_map(artifact) do
    %{
      file_name: value_text(value(artifact, :file_name), "-"),
      run_id: value_text(value(artifact, :run_id), "-"),
      generated_at: value_text(value(artifact, :generated_at), "-"),
      gate_status: value_text(value(artifact, :gate_status), "unknown")
    }
  end

  defp artifact_summary(_artifact), do: nil

  defp summary_field(field) when is_map(field) do
    %{
      label: value_text(value(field, :label), "unknown"),
      value: value_text(value(field, :value), "-")
    }
  end

  defp summary_field(field), do: %{label: "value", value: value_text(field, "-")}

  defp maybe_stale_artifact_warning(warnings, nil, _now, _stale_after_ms), do: warnings

  defp maybe_stale_artifact_warning(warnings, artifact, now, stale_after_ms) do
    generated_at = parse_datetime(value(artifact, :generated_at))

    if generated_at && DateTime.diff(now, generated_at, :millisecond) > stale_after_ms do
      [
        %{
          id: "archived-evidence-stale",
          reason: "latest_archived_evidence_stale",
          generated_at: DateTime.to_iso8601(generated_at)
        }
        | warnings
      ]
    else
      warnings
    end
  end

  defp readonly_boundary do
    %{
      status: "read_only",
      message: "This page reads configuration, snapshots, and archived artifacts only.",
      forbidden: [
        "scan",
        "reconcile",
        "heal",
        "probe",
        "scheduler",
        "mix_task",
        "system_command"
      ]
    }
  end

  defp scrubber_config(opts) do
    cfg = Keyword.get(opts, :scrubber_config, Application.get_env(:maxio, :scrubber, []))

    drive_cfg =
      Keyword.get(opts, :drive_health_config, Application.get_env(:maxio, :drive_health, []))

    identity_cfg =
      Keyword.get(opts, :drive_identity_config, Application.get_env(:maxio, :drive_identity, []))

    [
      enabled: Keyword.get(cfg, :enabled, false),
      interval_ms: positive_int(Keyword.get(cfg, :interval_ms), 86_400_000),
      page_size: positive_int(Keyword.get(cfg, :page_size), 500),
      scan_versions: Keyword.get(cfg, :scan_versions, false),
      reconcile_index: Keyword.get(cfg, :reconcile_index, false),
      reconcile_index_dry_run: Keyword.get(cfg, :reconcile_index_dry_run, false),
      drive_health_enabled:
        Keyword.get(cfg, :drive_health_enabled, Keyword.get(drive_cfg, :enabled, true)),
      drive_identity_enabled:
        Keyword.get(cfg, :drive_identity_enabled, Keyword.get(identity_cfg, :enabled, true)),
      drive_offline_after_ms:
        non_negative_int(
          Keyword.get(cfg, :drive_offline_after_ms, Keyword.get(drive_cfg, :offline_after_ms)),
          DriveHealth.default_offline_after_ms()
        )
    ]
  end

  defp source_value(opts, kind) do
    case Keyword.get(opts, :authoritative_sources) do
      %{} = sources ->
        Map.get(
          sources,
          kind,
          Map.get(sources, to_string(kind), ObjectMeta.authoritative_source(kind))
        )

      sources when is_list(sources) ->
        Keyword.get(sources, kind, ObjectMeta.authoritative_source(kind))

      _other ->
        ObjectMeta.authoritative_source(kind)
    end
  end

  defp bucket_names(opts) do
    option(opts, :buckets, fn ->
      Buckets.list()
      |> Enum.map(& &1.name)
    end)
    |> list_value()
    |> Enum.map(&to_string/1)
  end

  defp option(opts, key, fun) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> value
      :error -> safe_call(fun)
    end
  end

  defp safe_call(fun) do
    fun.()
  rescue
    _error -> nil
  catch
    _kind, _reason -> nil
  end

  defp usage_stale_after_ms(opts, scrubber_config) do
    Keyword.get(
      opts,
      :usage_stale_after_ms,
      max(scrubber_config[:interval_ms] * 2, @usage_default_stale_after_ms)
    )
  end

  defp usage_status([], _stale_count, _missing_count), do: "empty"
  defp usage_status(_rows, stale_count, _missing_count) when stale_count > 0, do: "attention"
  defp usage_status(_rows, _stale_count, missing_count) when missing_count > 0, do: "attention"
  defp usage_status(_rows, _stale_count, _missing_count), do: "ok"

  defp drive_health_status([], _counts), do: "empty"
  defp drive_health_status(_rows, %{offline: count}) when count > 0, do: "blocked"
  defp drive_health_status(_rows, %{suspect: count}) when count > 0, do: "attention"
  defp drive_health_status(_rows, %{heal_required: count}) when count > 0, do: "attention"
  defp drive_health_status(_rows, %{identity_replacements: count}) when count > 0, do: "attention"
  defp drive_health_status(_rows, _counts), do: "ok"

  defp drive_identity_status([], _counts), do: "empty"
  defp drive_identity_status(_rows, %{heal_required: count}) when count > 0, do: "attention"
  defp drive_identity_status(_rows, %{replacements: count}) when count > 0, do: "attention"
  defp drive_identity_status(_rows, _counts), do: "ok"

  defp archived_status([], []), do: "empty"
  defp archived_status(_rows, [_ | _]), do: "attention"

  defp archived_status(rows, _warnings) do
    statuses = Enum.map(rows, & &1.status)

    cond do
      Enum.any?(statuses, &(&1 in ["blocked", "error", "failed"])) -> "blocked"
      Enum.any?(statuses, &(&1 in ["attention", "warning"])) -> "attention"
      true -> "ok"
    end
  end

  defp rollup_status(statuses) do
    cond do
      Enum.any?(statuses, &(&1 == "blocked")) -> "blocked"
      Enum.any?(statuses, &(&1 == "attention")) -> "attention"
      Enum.all?(statuses, &(&1 == "empty")) -> "empty"
      Enum.any?(statuses, &(&1 == "empty")) -> "attention"
      Enum.all?(statuses, &(&1 == "ok")) -> "ok"
      true -> "attention"
    end
  end

  defp row(id, label, value), do: %{id: id, label: label, value: value_text(value, "-")}

  defp present_rows(rows), do: Enum.reject(rows, &(&1.value in [nil, ""]))

  defp value(nil, _key), do: nil
  defp value(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp value(_map, _key), do: nil

  defp list_value(value) when is_list(value), do: value
  defp list_value(nil), do: []
  defp list_value(value), do: [value]

  defp value_text(nil, fallback), do: fallback
  defp value_text("", fallback), do: fallback
  defp value_text(value, _fallback), do: text(value)

  defp bool_text(true), do: "true"
  defp bool_text(false), do: "false"
  defp bool_text(_value), do: "false"

  defp truthy?(true), do: true
  defp truthy?(_value), do: false

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(_value), do: true

  defp module_value(value) when is_atom(value), do: Atom.to_string(value)
  defp module_value(value), do: value_text(value, "-")

  defp endpoint_value({node, drive}), do: "#{node} #{drive}"
  defp endpoint_value(value), do: value_text(value, "-")

  defp fingerprint(nil), do: "-"
  defp fingerprint(""), do: "-"

  defp fingerprint(value) when is_binary(value),
    do: String.slice(value, 0, 8) <> "...#{byte_size(value)}"

  defp fingerprint(value), do: value |> inspect(limit: 4, printable_limit: 64) |> fingerprint()

  defp int_value(value) when is_integer(value), do: value
  defp int_value(value) when is_binary(value), do: value |> Integer.parse() |> elem_or_zero()
  defp int_value(_value), do: 0

  defp elem_or_zero({value, ""}), do: value
  defp elem_or_zero(_parsed), do: 0

  defp age_ms(nil, _now), do: nil

  defp age_ms(%DateTime{} = scanned_at, now),
    do: max(DateTime.diff(now, scanned_at, :millisecond), 0)

  defp age_ms(scanned_at, now), do: scanned_at |> parse_datetime() |> age_ms(now)

  defp datetime_value(nil), do: nil
  defp datetime_value(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp datetime_value(value), do: value |> parse_datetime() |> datetime_value()

  defp parse_datetime(%DateTime{} = dt), do: dt

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> dt
      _error -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp positive_int(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_int(_value, default), do: default

  defp non_negative_int(value, _default) when is_integer(value) and value >= 0, do: value
  defp non_negative_int(_value, default), do: default

  defp text(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp text(value) when is_atom(value), do: Atom.to_string(value)

  defp text(value) when is_binary(value),
    do: value |> String.replace(~r/[\r\n\t]+/, " ") |> String.slice(0, @max_text_length)

  defp text(value) when is_integer(value) or is_float(value) or is_boolean(value),
    do: to_string(value)

  defp text(value), do: value |> inspect(limit: 8, printable_limit: 120) |> text()

  defp safe_id(value) do
    value
    |> text()
    |> String.replace(~r/[^A-Za-z0-9_-]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "unknown"
      id -> String.slice(id, 0, 96)
    end
  end
end
