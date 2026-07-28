defmodule Mix.Tasks.Maxio.Heal.FreshDrives do
  @shortdoc "Heal recovered drives marked as fresh-drive heal required"
  @moduledoc """
  Run one operator-triggered fresh-drive heal pass.

      mix maxio.heal.fresh_drives
      mix maxio.heal.fresh_drives --dry-run
      mix maxio.heal.fresh_drives --bucket my-bucket
      mix maxio.heal.fresh_drives --max-objects 1000
      mix maxio.heal.fresh_drives --current-only
      mix maxio.heal.fresh_drives --max-objects-per-sec 100 --object-burst 10
      mix maxio.heal.fresh_drives --io-load-source storage-ops
      mix maxio.heal.fresh_drives --rebalance-if-needed
      mix maxio.heal.fresh_drives --rebalance-advance-steps 2
      mix maxio.heal.fresh_drives --rebalance-verify-closure
      mix maxio.heal.fresh_drives --json --fail-on-attention

  The task scans PG object inventory for distributed erasure sets containing
  recovered drives marked `DriveHealth.heal_required?`. It clears those markers
  only after a complete, unfiltered, non-dry-run pass with no missing,
  unrecoverable, skipped, or errored objects. `--current-only` is a partial
  inventory pass and never clears markers.

  Rebalance flags are opt-in. They reuse the fresh-drive scheduler bridge and
  the normal rebalance scheduler primitives; they do not perform decommission,
  topology mutation, physical removal, or physical drive actions.

  `--json` emits a machine-readable evidence report for CI/runbooks.
  `gate_status=blocked` means the requested heal pass was not complete enough
  to trust as a closure signal, or an opt-in rebalance bridge failed/blocked.
  `gate_status=attention` means the pass ran but produced operator evidence
  such as dry-run, healed objects, cleared markers, or skipped same-set drives.
  Gates are reporting-only unless `--fail-on-blocked` or
  `--fail-on-attention` is explicitly passed.
  """
  use Mix.Task

  alias Maxio.Cluster.FreshDriveHeal
  alias Maxio.Cluster.FreshDriveHeal.Scheduler
  alias Maxio.Storage.Distributed

  @io_load_sources ~w(s3-in-flight storage-ops combined drive-device-io cluster-s3-in-flight cluster-storage-ops cluster-combined cluster-drive-device-io)
  @io_load_source_usage Enum.join(@io_load_sources, "|")

  @impl true
  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          bucket: :string,
          dry_run: :boolean,
          max_objects: :integer,
          current_only: :boolean,
          page_size: :integer,
          no_throttle: :boolean,
          max_objects_per_sec: :integer,
          object_burst: :integer,
          sleep_between_batches_ms: :integer,
          no_adaptive_io: :boolean,
          io_load_source: :string,
          max_live_requests: :integer,
          io_pause_ms: :integer,
          io_max_pause_ms: :integer,
          rebalance_if_needed: :boolean,
          rebalance_advance_steps: :integer,
          rebalance_verify_closure: :boolean,
          fail_on_blocked: :boolean,
          fail_on_attention: :boolean,
          json: :boolean
        ],
        aliases: [b: :bucket]
      )

    if rest != [] or invalid != [] do
      unexpected = rest ++ Enum.map(invalid, &elem(&1, 0))

      Mix.raise(
        "usage: mix maxio.heal.fresh_drives [--bucket <name>] [--dry-run] " <>
          "[--max-objects <n>] [--current-only] [--page-size <n>] " <>
          "[--no-throttle] [--max-objects-per-sec <n>] [--object-burst <n>] " <>
          "[--sleep-between-batches-ms <ms>] [--no-adaptive-io] " <>
          "[--io-load-source #{@io_load_source_usage}] " <>
          "[--max-live-requests <n>] [--io-pause-ms <ms>] [--io-max-pause-ms <ms>] " <>
          "[--rebalance-if-needed] [--rebalance-advance-steps <n>] " <>
          "[--rebalance-verify-closure] [--fail-on-blocked] " <>
          "[--fail-on-attention] [--json] " <>
          "(unexpected: #{inspect(unexpected)})"
      )
    end

    validate_positive!(opts, :rebalance_advance_steps, "--rebalance-advance-steps")
    Mix.Task.run("app.start")

    view =
      opts
      |> heal_opts()
      |> run_heal(opts)
      |> result_view(opts)

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
      "[maxio heal.fresh_drives] status=#{view["status"]} " <>
        "gate_status=#{view["gate_status"]} " <>
        "backend=#{view["backend"]} bucket=#{format_value(view["bucket"])} " <>
        "scan_versions=#{view["scan_versions"]} max_objects=#{format_value(view["max_objects"])} " <>
        "drives_considered=#{view["drives_considered"]} " <>
        "drives_selected=#{view["drives_selected"]} drives_cleared=#{view["drives_cleared"]} " <>
        "drives_skipped_same_set=#{view["drives_skipped_same_set"]} " <>
        "drives_waiting=#{view["drives_waiting"]} sets=#{view["sets"]} buckets=#{view["buckets"]} " <>
        "scanned=#{view["scanned"]} healed_objects=#{view["healed_objects"]} " <>
        "healed_shards=#{view["healed_shards"]} unrecoverable=#{view["unrecoverable"]} " <>
        "missing=#{view["missing"]} skipped=#{view["skipped"]} errors=#{view["errors"]} " <>
        "truncated=#{view["truncated"]} dry_run=#{view["dry_run"]} " <>
        "blockers=#{length(view["blockers"])} warnings=#{length(view["warnings"])}" <>
        error_reason_suffix(view) <>
        rebalance_enqueue_suffix(view) <>
        rebalance_advance_suffix(view)
    )

    Enum.each(view["blockers"], fn blocker ->
      IO.puts("[maxio heal.fresh_drives.blocker] reason=#{blocker}")
    end)

    Enum.each(view["warnings"], fn warning ->
      IO.puts("[maxio heal.fresh_drives.warning] reason=#{warning}")
    end)
  end

  defp heal_opts(opts) do
    [
      bucket: opts[:bucket],
      dry_run: Keyword.get(opts, :dry_run, false),
      max_objects: Keyword.get(opts, :max_objects),
      scan_versions: not Keyword.get(opts, :current_only, false),
      page_size: Keyword.get(opts, :page_size),
      no_throttle: Keyword.get(opts, :no_throttle, false),
      max_objects_per_sec: Keyword.get(opts, :max_objects_per_sec),
      object_burst: Keyword.get(opts, :object_burst),
      sleep_between_batches_ms: Keyword.get(opts, :sleep_between_batches_ms),
      adaptive_io: adaptive_io_opt(opts),
      io_load_source: io_load_source_opt(opts),
      max_live_requests: Keyword.get(opts, :max_live_requests),
      io_pause_ms: Keyword.get(opts, :io_pause_ms),
      io_max_pause_ms: Keyword.get(opts, :io_max_pause_ms)
    ]
  end

  defp run_heal(heal_opts, opts) do
    result =
      if rebalance_bridge_requested?(opts) do
        Scheduler.run_now(scheduler_opts(heal_opts, opts))
      else
        FreshDriveHeal.run_once(heal_opts)
      end

    result
  end

  defp result_view({:ok, report}, _opts), do: report_view(report)

  defp result_view({:error, reason}, opts) do
    error_status =
      if rebalance_bridge_requested?(opts) do
        "scheduler_error"
      else
        "error"
      end

    error_blocker =
      if rebalance_bridge_requested?(opts) do
        "fresh_drive_heal_scheduler_error"
      else
        "fresh_drive_heal_error"
      end

    opts
    |> heal_opts()
    |> zero_error_view(error_status, error_blocker, reason)
  end

  defp report_view(report) do
    blockers = blockers(report)
    warnings = warnings(report, blockers)

    gate_status =
      cond do
        blockers != [] -> "blocked"
        warnings != [] -> "attention"
        true -> "ok"
      end

    view = %{
      "status" => status_string(report.status),
      "gate_status" => gate_status,
      "backend" => inspect(report.backend),
      "bucket" => report.bucket,
      "scan_versions" => report.scan_versions,
      "dry_run" => report.dry_run,
      "max_objects" => report.max_objects,
      "drives_considered" => report.drives_considered,
      "drives_selected" => report.drives_selected,
      "drives_cleared" => report.drives_cleared,
      "drives_skipped_same_set" => report.drives_skipped_same_set,
      "drives_waiting" => report.drives_waiting,
      "sets" => report.sets,
      "buckets" => report.buckets,
      "scanned" => report.scanned,
      "healed_objects" => report.healed_objects,
      "healed_shards" => report.healed_shards,
      "unrecoverable" => report.unrecoverable,
      "missing" => report.missing,
      "skipped" => report.skipped,
      "errors" => report.errors,
      "truncated" => report.truncated,
      "blockers" => blockers,
      "warnings" => warnings
    }

    view
    |> maybe_put_rebalance(report, "rebalance_enqueue", :rebalance_enqueue)
    |> maybe_put_rebalance(report, "rebalance_advance", :rebalance_advance)
  end

  defp zero_error_view(heal_opts, status, blocker, reason) do
    %{
      "status" => status,
      "gate_status" => "blocked",
      "backend" => inspect(Distributed),
      "bucket" => Keyword.get(heal_opts, :bucket),
      "scan_versions" => Keyword.get(heal_opts, :scan_versions, true),
      "dry_run" => Keyword.get(heal_opts, :dry_run, false),
      "max_objects" => Keyword.get(heal_opts, :max_objects),
      "drives_considered" => 0,
      "drives_selected" => 0,
      "drives_cleared" => 0,
      "drives_skipped_same_set" => 0,
      "drives_waiting" => 0,
      "sets" => 0,
      "buckets" => 0,
      "scanned" => 0,
      "healed_objects" => 0,
      "healed_shards" => 0,
      "unrecoverable" => 0,
      "missing" => 0,
      "skipped" => 0,
      "errors" => 1,
      "truncated" => false,
      "error_reason" => json_ready(reason),
      "blockers" => [blocker],
      "warnings" => []
    }
  end

  defp maybe_put_rebalance(view, report, json_key, report_key) do
    case Map.fetch(report, report_key) do
      {:ok, rebalance} -> Map.put(view, json_key, json_ready(rebalance))
      :error -> view
    end
  end

  defp blockers(report) do
    []
    |> maybe_add(
      report.status in [:waiting, :partial, :partial_scope, :incomplete],
      "fresh_drive_heal_status_#{status_string(report.status)}"
    )
    |> maybe_add(report.unrecoverable > 0, "objects_unrecoverable")
    |> maybe_add(report.missing > 0, "objects_missing")
    |> maybe_add(report.skipped > 0, "objects_skipped")
    |> maybe_add(report.errors > 0, "objects_errors")
    |> maybe_add(
      rebalance_blocked?(Map.get(report, :rebalance_enqueue)),
      "rebalance_enqueue_#{rebalance_status(report, :rebalance_enqueue)}"
    )
    |> maybe_add(
      rebalance_blocked?(Map.get(report, :rebalance_advance)),
      "rebalance_advance_#{rebalance_status(report, :rebalance_advance)}"
    )
  end

  defp warnings(report, [] = _blockers) do
    []
    |> maybe_add(report.status == :dry_run, "fresh_drive_heal_dry_run")
    |> maybe_add(report.drives_cleared > 0, "fresh_drive_heal_markers_cleared")
    |> maybe_add(report.healed_objects > 0, "objects_healed")
    |> maybe_add(report.healed_shards > 0, "shards_healed")
    |> maybe_add(report.drives_skipped_same_set > 0, "drives_skipped_same_set")
    |> maybe_add(
      rebalance_created?(Map.get(report, :rebalance_enqueue)),
      "rebalance_job_enqueued"
    )
    |> maybe_add(
      rebalance_skipped?(Map.get(report, :rebalance_enqueue)),
      "rebalance_enqueue_skipped"
    )
    |> maybe_add(
      rebalance_partial?(Map.get(report, :rebalance_advance)),
      "rebalance_advance_partial"
    )
  end

  defp warnings(_report, _blockers), do: []

  defp rebalance_blocked?(%{status: status}),
    do: status in [:failed, :blocked, "failed", "blocked"]

  defp rebalance_blocked?(_rebalance), do: false

  defp rebalance_created?(%{status: status}), do: status in [:created, "created"]
  defp rebalance_created?(_rebalance), do: false

  defp rebalance_skipped?(%{status: status}), do: status in [:skipped, "skipped"]
  defp rebalance_skipped?(_rebalance), do: false

  defp rebalance_partial?(%{status: status}), do: status in [:partial, "partial"]
  defp rebalance_partial?(_rebalance), do: false

  defp rebalance_status(report, key) do
    report
    |> Map.get(key, %{})
    |> Map.get(:status, "unknown")
    |> status_string()
  end

  defp fail_if_needed!(%{"gate_status" => "blocked"}, opts) do
    if Keyword.get(opts, :fail_on_blocked, false) or Keyword.get(opts, :fail_on_attention, false) do
      Mix.raise("fresh-drive heal blocked")
    end
  end

  defp fail_if_needed!(%{"gate_status" => "attention"}, opts) do
    if Keyword.get(opts, :fail_on_attention, false) do
      Mix.raise("fresh-drive heal attention")
    end
  end

  defp fail_if_needed!(_view, _opts), do: :ok

  defp json_ready(value) when is_boolean(value) or is_nil(value), do: value
  defp json_ready(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp json_ready(value) when is_atom(value), do: Atom.to_string(value)
  defp json_ready(value) when is_number(value) or is_binary(value), do: value
  defp json_ready(values) when is_list(values), do: Enum.map(values, &json_ready/1)
  defp json_ready(value) when is_tuple(value), do: inspect(value)

  defp json_ready(%{} = value) do
    Map.new(value, fn {key, item} -> {to_string(key), json_ready(item)} end)
  end

  defp json_ready(value), do: inspect(value)

  defp maybe_add(values, true, value), do: values ++ [value]
  defp maybe_add(values, false, _value), do: values

  defp scheduler_opts(heal_opts, opts) do
    advance_steps = rebalance_advance_steps(opts)

    scheduler_opts =
      heal_opts
      |> Keyword.put(:probe_drive_health, false)
      |> Keyword.put(:auto_rebalance_after_heal, true)
      |> Keyword.put(:auto_advance_rebalance_after_heal, is_integer(advance_steps))

    scheduler_opts =
      case advance_steps do
        nil -> scheduler_opts
        steps -> Keyword.put(scheduler_opts, :rebalance_advance_max_steps, steps)
      end

    if Keyword.get(opts, :rebalance_verify_closure, false) do
      Keyword.put(scheduler_opts, :rebalance_advance_opts, auto_rebalance_closure: true)
    else
      scheduler_opts
    end
  end

  defp rebalance_bridge_requested?(opts) do
    Keyword.get(opts, :rebalance_if_needed, false) ||
      is_integer(Keyword.get(opts, :rebalance_advance_steps)) ||
      Keyword.get(opts, :rebalance_verify_closure, false)
  end

  defp rebalance_advance_steps(opts) do
    cond do
      steps = Keyword.get(opts, :rebalance_advance_steps) -> steps
      Keyword.get(opts, :rebalance_verify_closure, false) -> 3
      true -> nil
    end
  end

  defp rebalance_enqueue_suffix(%{"rebalance_enqueue" => enqueue}) do
    " rebalance_enqueue_status=#{enqueue["status"]}" <>
      " rebalance_job_id=#{format_value(Map.get(enqueue, "job_id"))}" <>
      " rebalance_enqueue_reason=#{format_value(Map.get(enqueue, "reason"))}" <>
      " rebalance_routing_mismatches=#{Map.get(enqueue, "plan_routing_mismatches", 0)}"
  end

  defp rebalance_enqueue_suffix(_view), do: ""

  defp error_reason_suffix(%{"error_reason" => reason}),
    do: " error_reason=#{format_value(reason)}"

  defp error_reason_suffix(_view), do: ""

  defp rebalance_advance_suffix(%{"rebalance_advance" => advance}) do
    " rebalance_advance_status=#{advance["status"]}" <>
      " rebalance_advance_steps=#{Map.get(advance, "steps", 0)}" <>
      " rebalance_advance_phases=#{inspect(Map.get(advance, "phases", []))}" <>
      " rebalance_advance_blockers=#{inspect(Map.get(advance, "blockers", []))}" <>
      " rebalance_advance_reason=#{format_value(Map.get(advance, "reason"))}"
  end

  defp rebalance_advance_suffix(_view), do: ""

  defp format_value(nil), do: "nil"
  defp format_value(value) when is_binary(value), do: value
  defp format_value(value) when is_list(value), do: inspect(value)
  defp format_value(value), do: inspect(value)

  defp status_string(status) when is_atom(status), do: Atom.to_string(status)
  defp status_string(status), do: to_string(status)

  defp validate_positive!(opts, key, flag) do
    case Keyword.get(opts, key) do
      nil -> :ok
      value when is_integer(value) and value > 0 -> :ok
      value -> Mix.raise("#{flag} must be a positive integer, got #{inspect(value)}")
    end
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
