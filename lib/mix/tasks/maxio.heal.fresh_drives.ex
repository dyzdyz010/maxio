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

  The task scans PG object inventory for distributed erasure sets containing
  recovered drives marked `DriveHealth.heal_required?`. It clears those markers
  only after a complete, unfiltered, non-dry-run pass with no missing,
  unrecoverable, skipped, or errored objects. `--current-only` is a partial
  inventory pass and never clears markers.

  Rebalance flags are opt-in. They reuse the fresh-drive scheduler bridge and
  the normal rebalance scheduler primitives; they do not perform decommission,
  topology mutation, physical removal, or physical drive actions.
  """
  use Mix.Task

  alias Maxio.Cluster.FreshDriveHeal
  alias Maxio.Cluster.FreshDriveHeal.Scheduler

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
          rebalance_verify_closure: :boolean
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
          "[--rebalance-verify-closure] " <>
          "(unexpected: #{inspect(unexpected)})"
      )
    end

    validate_positive!(opts, :rebalance_advance_steps, "--rebalance-advance-steps")
    Mix.Task.run("app.start")

    report =
      opts
      |> heal_opts()
      |> run_heal(opts)

    IO.puts(
      "[maxio heal.fresh_drives] status=#{report.status} " <>
        "drives_considered=#{report.drives_considered} " <>
        "drives_selected=#{report.drives_selected} drives_cleared=#{report.drives_cleared} " <>
        "drives_skipped_same_set=#{report.drives_skipped_same_set} " <>
        "drives_waiting=#{report.drives_waiting} sets=#{report.sets} buckets=#{report.buckets} " <>
        "scanned=#{report.scanned} healed_objects=#{report.healed_objects} " <>
        "healed_shards=#{report.healed_shards} unrecoverable=#{report.unrecoverable} " <>
        "missing=#{report.missing} skipped=#{report.skipped} errors=#{report.errors} " <>
        "truncated=#{report.truncated} dry_run=#{report.dry_run}" <>
        rebalance_enqueue_suffix(report) <>
        rebalance_advance_suffix(report)
    )
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

    case result do
      {:ok, report} -> report
      {:error, reason} -> Mix.raise("fresh-drive heal failed: #{inspect(reason)}")
    end
  end

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

  defp rebalance_enqueue_suffix(%{rebalance_enqueue: enqueue}) do
    " rebalance_enqueue_status=#{enqueue.status}" <>
      " rebalance_job_id=#{format_value(Map.get(enqueue, :job_id))}" <>
      " rebalance_enqueue_reason=#{format_value(Map.get(enqueue, :reason))}" <>
      " rebalance_routing_mismatches=#{Map.get(enqueue, :plan_routing_mismatches, 0)}"
  end

  defp rebalance_enqueue_suffix(_report), do: ""

  defp rebalance_advance_suffix(%{rebalance_advance: advance}) do
    " rebalance_advance_status=#{advance.status}" <>
      " rebalance_advance_steps=#{Map.get(advance, :steps, 0)}" <>
      " rebalance_advance_phases=#{inspect(Map.get(advance, :phases, []))}" <>
      " rebalance_advance_blockers=#{inspect(Map.get(advance, :blockers, []))}" <>
      " rebalance_advance_reason=#{format_value(Map.get(advance, :reason))}"
  end

  defp rebalance_advance_suffix(_report), do: ""

  defp format_value(nil), do: "nil"
  defp format_value(value) when is_binary(value), do: value
  defp format_value(value), do: inspect(value)

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
