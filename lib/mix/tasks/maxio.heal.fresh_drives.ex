defmodule Mix.Tasks.Maxio.Heal.FreshDrives do
  @shortdoc "Heal recovered drives marked as fresh-drive heal required"
  @moduledoc """
  Run one operator-triggered fresh-drive heal pass.

      mix maxio.heal.fresh_drives
      mix maxio.heal.fresh_drives --dry-run
      mix maxio.heal.fresh_drives --bucket my-bucket
      mix maxio.heal.fresh_drives --max-objects 1000
      mix maxio.heal.fresh_drives --current-only

  The task scans PG object inventory for distributed erasure sets containing
  recovered drives marked `DriveHealth.heal_required?`. It clears those markers
  only after a complete, unfiltered, non-dry-run pass with no missing,
  unrecoverable, skipped, or errored objects. `--current-only` is a partial
  inventory pass and never clears markers.
  """
  use Mix.Task

  alias Maxio.Cluster.FreshDriveHeal

  @impl true
  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          bucket: :string,
          dry_run: :boolean,
          max_objects: :integer,
          current_only: :boolean,
          page_size: :integer
        ],
        aliases: [b: :bucket]
      )

    if rest != [] or invalid != [] do
      unexpected = rest ++ Enum.map(invalid, &elem(&1, 0))

      Mix.raise(
        "usage: mix maxio.heal.fresh_drives [--bucket <name>] [--dry-run] " <>
          "[--max-objects <n>] [--current-only] [--page-size <n>] " <>
          "(unexpected: #{inspect(unexpected)})"
      )
    end

    Mix.Task.run("app.start")

    {:ok, report} =
      FreshDriveHeal.run_once(
        bucket: opts[:bucket],
        dry_run: Keyword.get(opts, :dry_run, false),
        max_objects: Keyword.get(opts, :max_objects),
        scan_versions: not Keyword.get(opts, :current_only, false),
        page_size: Keyword.get(opts, :page_size)
      )

    IO.puts(
      "[maxio heal.fresh_drives] status=#{report.status} " <>
        "drives_considered=#{report.drives_considered} " <>
        "drives_selected=#{report.drives_selected} drives_cleared=#{report.drives_cleared} " <>
        "drives_skipped_same_set=#{report.drives_skipped_same_set} " <>
        "drives_waiting=#{report.drives_waiting} sets=#{report.sets} buckets=#{report.buckets} " <>
        "scanned=#{report.scanned} healed_objects=#{report.healed_objects} " <>
        "healed_shards=#{report.healed_shards} unrecoverable=#{report.unrecoverable} " <>
        "missing=#{report.missing} skipped=#{report.skipped} errors=#{report.errors} " <>
        "truncated=#{report.truncated} dry_run=#{report.dry_run}"
    )
  end
end
