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
          orphan_cleanup_max_deletes: :integer
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

    IO.puts(
      "[maxio scan] status=#{summary.status} backend=#{inspect(summary.backend)} " <>
        "buckets=#{summary.buckets} scanned=#{summary.scanned} damaged=#{summary.damaged} " <>
        "healed=#{summary.healed} unrecoverable=#{summary.unrecoverable} " <>
        "missing=#{summary.missing} skipped=#{summary.skipped} sampled_out=#{summary.sampled_out} " <>
        "index_status=#{summary.index_status} index_scanned=#{summary.index_scanned} " <>
        "index_upserted=#{summary.index_upserted} index_gc=#{summary.index_gc} " <>
        "index_skipped=#{summary.index_skipped} index_divergent=#{summary.index_divergent} " <>
        "index_orphan_shards=#{summary.index_orphan_shards} " <>
        "index_orphan_bytes=#{summary.index_orphan_bytes} " <>
        "index_orphan_cleaned=#{summary.index_orphan_cleaned} " <>
        "index_orphan_cleaned_bytes=#{summary.index_orphan_cleaned_bytes} " <>
        "drive_sets=#{summary.drive_sets} drive_endpoints=#{summary.drive_endpoints} " <>
        "drive_online=#{summary.drive_online} drive_suspect=#{summary.drive_suspect} " <>
        "drive_offline=#{summary.drive_offline} " <>
        "drive_heal_required=#{summary.drive_heal_required} " <>
        "drive_identity_replacements=#{summary.drive_identity_replacements} " <>
        "drive_identity_heal_required=#{summary.drive_identity_heal_required} " <>
        "drive_identity_errors=#{summary.drive_identity_errors} " <>
        "objects=#{summary.object_count} bytes=#{summary.total_size}"
    )
  end

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
