defmodule Mix.Tasks.Maxio.Scan do
  @shortdoc "Run one metadata-driven usage and auto-heal scan"
  @moduledoc """
  Run one operational scrubber round.

      mix maxio.scan
      mix maxio.scan --bucket my-bucket
      mix maxio.scan --versions
      mix maxio.scan --no-throttle
      mix maxio.scan --reconcile-index
      mix maxio.scan --reconcile-index --cleanup-orphan-shards
      mix maxio.scan --json --fail-on-attention
      mix maxio.scan --max-objects-per-sec 100 --object-burst 10
      mix maxio.scan --no-adaptive-io
      mix maxio.scan --io-load-source storage-ops
      mix maxio.scan --drive-offline-after-ms 172800000

  FS backends refresh scan-derived usage only. Erasure-coded backends also invoke
  the existing local or distributed heal engine for each enumerated object.
  `--reconcile-index` first runs the disk/peer sidecar reconcile scanner, using
  its existing authority gate; `--force-reconcile-index` explicitly crosses that
  gate when the operator accepts disk sidecars as the source of truth. Orphan
  shard byte cleanup remains independently gated by sidecar write authority,
  full endpoint visibility, object locks, age, and per-run delete limits.

  `--json` emits a machine-readable evidence report for CI/runbooks.
  `gate_status=blocked` means a requested sub-scan did not run safely, such as
  index reconcile authority mismatch, no topology, or an index pre-pass crash.
  `gate_status=attention` means the scan ran but found actionable object,
  index, or drive-health evidence. Gates are reporting-only unless
  `--fail-on-blocked` or `--fail-on-attention` is explicitly passed.
  """
  use Mix.Task

  @io_load_sources ~w(s3-in-flight storage-ops combined drive-device-io cluster-s3-in-flight cluster-storage-ops cluster-combined cluster-drive-device-io)
  @io_load_source_usage Enum.join(@io_load_sources, "|")

  @impl true
  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          bucket: :string,
          versions: :boolean,
          no_throttle: :boolean,
          max_objects_per_sec: :integer,
          object_burst: :integer,
          sleep_between_batches_ms: :integer,
          no_adaptive_io: :boolean,
          io_load_source: :string,
          max_live_requests: :integer,
          io_pause_ms: :integer,
          io_max_pause_ms: :integer,
          drive_offline_after_ms: :integer,
          reconcile_index: :boolean,
          force_reconcile_index: :boolean,
          cleanup_orphan_shards: :boolean,
          orphan_cleanup_dry_run: :boolean,
          orphan_cleanup_min_age_ms: :integer,
          orphan_cleanup_max_deletes: :integer,
          fail_on_blocked: :boolean,
          fail_on_attention: :boolean,
          json: :boolean
        ],
        aliases: [b: :bucket]
      )

    if rest != [] or invalid != [] do
      unexpected = rest ++ Enum.map(invalid, &elem(&1, 0))

      Mix.raise(
        "usage: mix maxio.scan [--bucket <name>] [--versions] [--no-throttle] " <>
          "[--max-objects-per-sec <n>] [--object-burst <n>] " <>
          "[--sleep-between-batches-ms <ms>] [--no-adaptive-io] " <>
          "[--io-load-source #{@io_load_source_usage}] " <>
          "[--max-live-requests <n>] [--io-pause-ms <ms>] [--io-max-pause-ms <ms>] " <>
          "[--drive-offline-after-ms <ms>] " <>
          "[--reconcile-index] [--force-reconcile-index] [--cleanup-orphan-shards] " <>
          "[--orphan-cleanup-dry-run] [--orphan-cleanup-min-age-ms <ms>] " <>
          "[--orphan-cleanup-max-deletes <n>] " <>
          "[--fail-on-blocked] [--fail-on-attention] [--json] " <>
          "(unexpected: #{inspect(unexpected)})"
      )
    end

    Mix.Task.run("app.start")

    {:ok, summary} =
      Maxio.Cluster.Scrubber.run_once(
        bucket: opts[:bucket],
        scan_versions: Keyword.get(opts, :versions, false),
        no_throttle: Keyword.get(opts, :no_throttle, false),
        max_objects_per_sec: Keyword.get(opts, :max_objects_per_sec),
        object_burst: Keyword.get(opts, :object_burst),
        sleep_between_batches_ms: Keyword.get(opts, :sleep_between_batches_ms),
        adaptive_io: adaptive_io_opt(opts),
        io_load_source: io_load_source_opt(opts),
        max_live_requests: Keyword.get(opts, :max_live_requests),
        io_pause_ms: Keyword.get(opts, :io_pause_ms),
        io_max_pause_ms: Keyword.get(opts, :io_max_pause_ms),
        drive_offline_after_ms: Keyword.get(opts, :drive_offline_after_ms),
        reconcile_index: Keyword.get(opts, :reconcile_index, false),
        force_reconcile_index: Keyword.get(opts, :force_reconcile_index, false),
        cleanup_orphan_shards: Keyword.get(opts, :cleanup_orphan_shards, false),
        orphan_cleanup_dry_run: Keyword.get(opts, :orphan_cleanup_dry_run, false),
        orphan_cleanup_min_age_ms: Keyword.get(opts, :orphan_cleanup_min_age_ms),
        orphan_cleanup_max_deletes: Keyword.get(opts, :orphan_cleanup_max_deletes)
      )

    view = summary_view(summary)
    print_or_json(view, opts)
    fail_if_needed!(view, opts)
  end

  defp print_or_json(view, opts) do
    if Keyword.get(opts, :json, false) do
      IO.puts(Jason.encode!(view))
    else
      print_text(view)
    end
  end

  defp print_text(view) do
    IO.puts(
      "[maxio scan] status=#{view["status"]} gate_status=#{view["gate_status"]} " <>
        "backend=#{view["backend"]} buckets=#{view["buckets"]} scanned=#{view["scanned"]} " <>
        "damaged=#{view["damaged"]} healed=#{view["healed"]} " <>
        "unrecoverable=#{view["unrecoverable"]} missing=#{view["missing"]} " <>
        "skipped=#{view["skipped"]} sampled_out=#{view["sampled_out"]} " <>
        "index_status=#{view["index_status"]} index_scanned=#{view["index_scanned"]} " <>
        "index_upserted=#{view["index_upserted"]} index_gc=#{view["index_gc"]} " <>
        "index_skipped=#{view["index_skipped"]} index_divergent=#{view["index_divergent"]} " <>
        "index_orphan_shards=#{view["index_orphan_shards"]} " <>
        "index_orphan_bytes=#{view["index_orphan_bytes"]} " <>
        "index_orphan_cleaned=#{view["index_orphan_cleaned"]} " <>
        "index_orphan_cleaned_bytes=#{view["index_orphan_cleaned_bytes"]} " <>
        "drive_sets=#{view["drive_sets"]} drive_endpoints=#{view["drive_endpoints"]} " <>
        "drive_online=#{view["drive_online"]} drive_suspect=#{view["drive_suspect"]} " <>
        "drive_offline=#{view["drive_offline"]} " <>
        "drive_heal_required=#{view["drive_heal_required"]} " <>
        "drive_identity_replacements=#{view["drive_identity_replacements"]} " <>
        "drive_identity_heal_required=#{view["drive_identity_heal_required"]} " <>
        "drive_identity_errors=#{view["drive_identity_errors"]} " <>
        "objects=#{view["object_count"]} bytes=#{view["total_size"]} " <>
        "blockers=#{length(view["blockers"])} warnings=#{length(view["warnings"])}"
    )

    Enum.each(view["blockers"], fn blocker ->
      IO.puts("[maxio scan.blocker] reason=#{blocker}")
    end)

    Enum.each(view["warnings"], fn warning ->
      IO.puts("[maxio scan.warning] reason=#{warning}")
    end)
  end

  defp summary_view(summary) do
    blockers = blockers(summary)
    warnings = warnings(summary)

    gate_status =
      cond do
        blockers != [] -> "blocked"
        warnings != [] -> "attention"
        true -> "ok"
      end

    %{
      "status" => status_string(summary.status),
      "gate_status" => gate_status,
      "backend" => inspect(summary.backend),
      "buckets" => summary.buckets,
      "scanned" => summary.scanned,
      "damaged" => summary.damaged,
      "healed" => summary.healed,
      "unrecoverable" => summary.unrecoverable,
      "missing" => summary.missing,
      "skipped" => summary.skipped,
      "sampled_out" => summary.sampled_out,
      "index_status" => status_string(summary.index_status),
      "index_scanned" => summary.index_scanned,
      "index_upserted" => summary.index_upserted,
      "index_gc" => summary.index_gc,
      "index_skipped" => summary.index_skipped,
      "index_divergent" => summary.index_divergent,
      "index_orphan_shards" => summary.index_orphan_shards,
      "index_orphan_bytes" => summary.index_orphan_bytes,
      "index_orphan_cleaned" => summary.index_orphan_cleaned,
      "index_orphan_cleaned_bytes" => summary.index_orphan_cleaned_bytes,
      "drive_sets" => summary.drive_sets,
      "drive_endpoints" => summary.drive_endpoints,
      "drive_online" => summary.drive_online,
      "drive_suspect" => summary.drive_suspect,
      "drive_offline" => summary.drive_offline,
      "drive_heal_required" => summary.drive_heal_required,
      "drive_identity_replacements" => summary.drive_identity_replacements,
      "drive_identity_heal_required" => summary.drive_identity_heal_required,
      "drive_identity_errors" => summary.drive_identity_errors,
      "object_count" => summary.object_count,
      "total_size" => summary.total_size,
      "blockers" => blockers,
      "warnings" => warnings
    }
  end

  defp blockers(summary) do
    []
    |> maybe_add(summary.status != :ok, "scan_status_#{status_string(summary.status)}")
    |> maybe_add(
      summary.index_status in [:authority_mismatch, :no_topology, :error],
      "index_#{status_string(summary.index_status)}"
    )
  end

  defp warnings(summary) do
    if blockers(summary) != [] do
      []
    else
      []
      |> maybe_add(summary.damaged > 0, "objects_damaged_detected")
      |> maybe_add(summary.healed > 0, "objects_healed")
      |> maybe_add(summary.unrecoverable > 0, "objects_unrecoverable")
      |> maybe_add(summary.missing > 0, "objects_missing")
      |> maybe_add(summary.skipped > 0, "objects_skipped")
      |> maybe_add(summary.index_upserted > 0, "derived_index_reconciled")
      |> maybe_add(summary.index_gc > 0, "reverse_gc_deleted")
      |> maybe_add(summary.index_skipped > 0, "index_endpoint_or_probe_skipped")
      |> maybe_add(summary.index_divergent > 0, "index_sidecar_quorum_divergent")
      |> maybe_add(summary.index_orphan_shards > 0, "index_orphan_shards_detected")
      |> maybe_add(summary.index_orphan_cleaned > 0, "index_orphan_shards_cleaned")
      |> maybe_add(summary.drive_suspect > 0, "drive_suspect")
      |> maybe_add(summary.drive_offline > 0, "drive_offline")
      |> maybe_add(summary.drive_heal_required > 0, "drive_heal_required")
      |> maybe_add(summary.drive_identity_replacements > 0, "drive_identity_replacement_detected")
      |> maybe_add(summary.drive_identity_heal_required > 0, "drive_identity_heal_required")
      |> maybe_add(summary.drive_identity_errors > 0, "drive_identity_errors")
    end
  end

  defp maybe_add(values, true, value), do: values ++ [value]
  defp maybe_add(values, false, _value), do: values

  defp fail_if_needed!(%{"gate_status" => "blocked"}, opts) do
    if Keyword.get(opts, :fail_on_blocked, false) or Keyword.get(opts, :fail_on_attention, false) do
      Mix.raise("scan blocked")
    end
  end

  defp fail_if_needed!(%{"gate_status" => "attention"}, opts) do
    if Keyword.get(opts, :fail_on_attention, false) do
      Mix.raise("scan attention")
    end
  end

  defp fail_if_needed!(_view, _opts), do: :ok

  defp status_string(status) when is_atom(status), do: Atom.to_string(status)
  defp status_string(status), do: to_string(status)

  defp adaptive_io_opt(opts) do
    if Keyword.get(opts, :no_adaptive_io, false), do: false, else: nil
  end

  defp io_load_source_opt(opts) do
    case Keyword.get(opts, :io_load_source) do
      nil ->
        nil

      source when source in @io_load_sources ->
        Maxio.Cluster.IOPressure.normalize_source(source)

      source ->
        Mix.raise(
          "invalid --io-load-source #{inspect(source)}; expected one of #{Enum.join(@io_load_sources, ", ")}"
        )
    end
  end
end
