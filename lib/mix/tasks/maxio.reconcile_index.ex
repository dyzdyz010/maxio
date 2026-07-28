defmodule Mix.Tasks.Maxio.ReconcileIndex do
  @shortdoc "Run one derived-index reconcile scanner pass"
  @moduledoc """
  Run one scanner pass that reconciles disk sidecar authority into the derived
  Postgres object index and performs guarded reverse-GC / orphan-shard evidence.

      mix maxio.reconcile_index
      mix maxio.reconcile_index --dry-run
      mix maxio.reconcile_index --bucket photos --json
      mix maxio.reconcile_index --cleanup-orphan-shards --orphan-cleanup-min-age-ms 172800000
      mix maxio.reconcile_index --json --fail-on-attention

  The scanner is safe by default:

  * it refuses to run unless `authoritative_source(:write) == :sidecar`, unless
    `--force` is passed;
  * orphan shard cleanup is disabled unless `--cleanup-orphan-shards` is passed;
  * `--dry-run` reports what would happen without writing PG rows or deleting
    orphan shard bytes;
  * non-FS backends without a topology return a no-op `no_topology` report.

  `--json` emits a machine-readable evidence report. `gate_status=blocked`
  means the scanner did not run (`authority_mismatch` / `no_topology`).
  `gate_status=attention` means the scanner ran but found drift, skipped probes,
  divergent sidecars, notification replay problems, retained-ledger ambiguity,
  orphan shards, or dry-run would-change evidence. Gates are reporting-only
  unless `--fail-on-blocked` or `--fail-on-attention` is explicitly passed.
  """
  use Mix.Task

  @impl true
  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          dry_run: :boolean,
          bucket: :string,
          force: :boolean,
          cleanup_orphan_shards: :boolean,
          orphan_cleanup_dry_run: :boolean,
          orphan_cleanup_min_age_ms: :integer,
          orphan_cleanup_max_deletes: :integer,
          fail_on_blocked: :boolean,
          fail_on_attention: :boolean,
          json: :boolean
        ]
      )

    if rest != [] or invalid != [] do
      Mix.raise("#{usage()} (unexpected: #{inspect(rest ++ Enum.map(invalid, &elem(&1, 0)))})")
    end

    Mix.Task.run("app.start")

    {:ok, report} =
      Maxio.Storage.Scanner.run_once(
        dry_run: Keyword.get(opts, :dry_run, false),
        bucket: Keyword.get(opts, :bucket),
        force: Keyword.get(opts, :force, false),
        cleanup_orphan_shards: Keyword.get(opts, :cleanup_orphan_shards, false),
        orphan_cleanup_dry_run: Keyword.get(opts, :orphan_cleanup_dry_run, false),
        orphan_cleanup_min_age_ms: Keyword.get(opts, :orphan_cleanup_min_age_ms),
        orphan_cleanup_max_deletes: Keyword.get(opts, :orphan_cleanup_max_deletes)
      )

    view = report_view(report)
    print_or_json(view, opts)
    fail_if_needed!(view, opts)
  end

  defp usage do
    "usage: mix maxio.reconcile_index [--dry-run] [--bucket <name>] [--force] " <>
      "[--cleanup-orphan-shards] [--orphan-cleanup-dry-run] " <>
      "[--orphan-cleanup-min-age-ms <ms>] [--orphan-cleanup-max-deletes <n>] " <>
      "[--fail-on-blocked] [--fail-on-attention] [--json]"
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
      "[maxio reconcile_index] status=#{view["status"]} " <>
        "gate_status=#{view["gate_status"]} dry_run=#{view["dry_run"]} " <>
        "buckets=#{view["buckets"]} scanned=#{view["scanned"]} " <>
        "upserted=#{view["upserted"]} gc=#{view["gc"]} skipped=#{view["skipped"]} " <>
        "divergent=#{view["divergent"]} " <>
        "notification_replayed=#{view["notification_replayed"]} " <>
        "notification_replay_failed=#{view["notification_replay_failed"]} " <>
        "notification_retained_scanned=#{view["notification_retained_scanned"]} " <>
        "notification_retained_pruned=#{view["notification_retained_pruned"]} " <>
        "notification_retained_aborted=#{view["notification_retained_aborted"]} " <>
        "notification_retained_ambiguous=#{view["notification_retained_ambiguous"]} " <>
        "orphan_shards=#{view["orphan_shards"]} orphan_bytes=#{view["orphan_bytes"]} " <>
        "orphan_cleaned=#{view["orphan_cleaned"]} " <>
        "orphan_cleaned_bytes=#{view["orphan_cleaned_bytes"]} " <>
        "blockers=#{length(view["blockers"])} warnings=#{length(view["warnings"])}"
    )

    Enum.each(view["blockers"], fn blocker ->
      IO.puts("[maxio reconcile_index.blocker] reason=#{blocker}")
    end)

    Enum.each(view["warnings"], fn warning ->
      IO.puts("[maxio reconcile_index.warning] reason=#{warning}")
    end)

    if view["status"] == "no_topology" do
      IO.puts(
        "[maxio reconcile_index] no distributed topology configured - nothing scanned " <>
          "(reconcile requires Maxio.Cluster.Topology for non-FS backends; FS injects " <>
          "a synthetic single-endpoint topology)"
      )
    end

    if view["status"] == "authority_mismatch" do
      IO.puts(
        "[maxio reconcile_index] refused: authoritative_source(:write) != :sidecar - disk is " <>
          "NOT the write authority. Reconciling PG from disk under :pg authority would " <>
          "resurrect objects deleted via PG-only delete markers and reverse-GC authoritative " <>
          "rows. Rerun with --force only if you explicitly accept disk as the authority."
      )
    end
  end

  defp report_view(report) do
    blockers = blockers(report)
    warnings = warnings(report)

    gate_status =
      cond do
        blockers != [] -> "blocked"
        warnings != [] -> "attention"
        true -> "ok"
      end

    %{
      "status" => Atom.to_string(report.status),
      "gate_status" => gate_status,
      "dry_run" => report.dry_run,
      "buckets" => report.buckets,
      "scanned" => report.scanned,
      "upserted" => report.upserted,
      "gc" => report.gc,
      "skipped" => report.skipped,
      "divergent" => report.divergent,
      "notification_replayed" => report.notification_replayed,
      "notification_replay_failed" => report.notification_replay_failed,
      "notification_retained_scanned" => report.notification_retained_scanned,
      "notification_retained_pruned" => report.notification_retained_pruned,
      "notification_retained_aborted" => report.notification_retained_aborted,
      "notification_retained_ambiguous" => report.notification_retained_ambiguous,
      "orphan_shards" => report.orphan_shards,
      "orphan_bytes" => report.orphan_bytes,
      "orphan_cleaned" => report.orphan_cleaned,
      "orphan_cleaned_bytes" => report.orphan_cleaned_bytes,
      "blockers" => blockers,
      "warnings" => warnings
    }
  end

  defp blockers(%{status: :ok}), do: []
  defp blockers(%{status: status}), do: [Atom.to_string(status)]

  defp warnings(%{status: status}) when status != :ok, do: []

  defp warnings(report) do
    []
    |> maybe_warn(report.dry_run and report.upserted > 0, "dry_run_would_reconcile")
    |> maybe_warn(report.dry_run and report.gc > 0, "dry_run_would_reverse_gc")
    |> maybe_warn(report.upserted > 0, "derived_index_reconciled")
    |> maybe_warn(report.gc > 0, "reverse_gc_deleted")
    |> maybe_warn(report.skipped > 0, "endpoint_or_probe_skipped")
    |> maybe_warn(report.divergent > 0, "sidecar_quorum_divergent")
    |> maybe_warn(report.notification_replay_failed > 0, "notification_replay_failed")
    |> maybe_warn(report.notification_retained_aborted > 0, "notification_retained_aborted")
    |> maybe_warn(report.notification_retained_ambiguous > 0, "notification_retained_ambiguous")
    |> maybe_warn(report.orphan_shards > 0, "orphan_shards_detected")
  end

  defp maybe_warn(warnings, true, warning), do: [warning | warnings]
  defp maybe_warn(warnings, false, _warning), do: warnings

  defp fail_if_needed!(%{"gate_status" => "blocked"}, opts) do
    if Keyword.get(opts, :fail_on_blocked, false) or Keyword.get(opts, :fail_on_attention, false) do
      Mix.raise("reconcile_index blocked")
    end
  end

  defp fail_if_needed!(%{"gate_status" => "attention"}, opts) do
    if Keyword.get(opts, :fail_on_attention, false) do
      Mix.raise("reconcile_index attention")
    end
  end

  defp fail_if_needed!(_view, _opts), do: :ok
end
