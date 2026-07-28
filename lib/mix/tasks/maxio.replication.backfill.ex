defmodule Mix.Tasks.Maxio.Replication.Backfill do
  @shortdoc "Backfill existing object versions into the S3 bucket replication outbox"
  @moduledoc """
  Scan existing source object versions and enqueue matching bucket replication
  tasks into the durable outbox.

      mix maxio.replication.backfill --source-bucket photos --dry-run
      mix maxio.replication.backfill --source-bucket photos --confirm --limit 500
      mix maxio.replication.backfill --source-bucket photos --confirm \\
        --key-marker logs/a.txt --version-id-marker 01J... --json

  The task is dry-run by default. `--confirm` is required to persist outbox
  rows. It does not copy bytes; run `mix maxio.replication.drain` or enable the
  replication delivery scheduler to deliver the queued work.
  """

  use Mix.Task

  alias Maxio.S3.ReplicationBackfill

  @max_limit 10_000

  @impl true
  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          source_bucket: :string,
          dry_run: :boolean,
          confirm: :boolean,
          limit: :integer,
          key_marker: :string,
          version_id_marker: :string,
          json: :boolean
        ]
      )

    if rest != [] or invalid != [] do
      unexpected = rest ++ Enum.map(invalid, &elem(&1, 0))

      Mix.raise(
        "usage: mix maxio.replication.backfill --source-bucket BUCKET " <>
          "[--dry-run|--confirm] [--limit N] [--key-marker KEY --version-id-marker VERSION] " <>
          "[--json] (unexpected: #{inspect(unexpected)})"
      )
    end

    validate_opts!(opts)
    Mix.Task.run("app.start")

    backfill_opts =
      []
      |> Keyword.put(:source_bucket, Keyword.fetch!(opts, :source_bucket))
      |> Keyword.put(:dry_run, dry_run?(opts))
      |> maybe_put(:limit, Keyword.get(opts, :limit))
      |> maybe_put(:key_marker, Keyword.get(opts, :key_marker))
      |> maybe_put(:version_id_marker, Keyword.get(opts, :version_id_marker))

    case ReplicationBackfill.run(backfill_opts) do
      {:ok, summary} -> print_summary(summary, opts)
      {:error, reason} -> Mix.raise("replication backfill failed: #{inspect(reason)}")
    end
  end

  defp validate_opts!(opts) do
    unless Keyword.get(opts, :source_bucket) not in [nil, ""] do
      Mix.raise("--source-bucket is required")
    end

    if Keyword.get(opts, :confirm, false) and Keyword.get(opts, :dry_run, false) do
      Mix.raise("choose exactly one of --dry-run or --confirm")
    end

    validate_limit!(Keyword.get(opts, :limit))
    validate_markers!(Keyword.get(opts, :key_marker), Keyword.get(opts, :version_id_marker))
  end

  defp validate_limit!(nil), do: :ok

  defp validate_limit!(limit) when is_integer(limit) and limit > 0 and limit <= @max_limit,
    do: :ok

  defp validate_limit!(limit) when is_integer(limit) and limit > @max_limit do
    Mix.raise("--limit must be <= #{@max_limit}, got #{inspect(limit)}")
  end

  defp validate_limit!(limit),
    do: Mix.raise("--limit must be a positive integer, got #{inspect(limit)}")

  defp validate_markers!(nil, nil), do: :ok
  defp validate_markers!(key, version) when is_binary(key) and is_binary(version), do: :ok

  defp validate_markers!(key, nil) when is_binary(key) do
    Mix.raise("--key-marker requires --version-id-marker")
  end

  defp validate_markers!(_key, version) when is_binary(version) do
    Mix.raise("--version-id-marker requires --key-marker")
  end

  defp dry_run?(opts), do: not Keyword.get(opts, :confirm, false)

  defp print_summary(summary, opts) do
    if Keyword.get(opts, :json, false) do
      IO.puts(Jason.encode!(summary))
    else
      print_text(summary)
    end
  end

  defp print_text(summary) do
    mode = if summary.dry_run, do: "dry-run", else: "confirm"

    IO.puts(
      "[maxio replication.backfill] mode=#{mode} source_bucket=#{inspect(summary.source_bucket)} " <>
        "scanned_versions=#{summary.scanned_versions} matched_versions=#{summary.matched_versions} " <>
        "matched_tasks=#{summary.matched_tasks} existing_tasks=#{summary.existing_tasks} " <>
        "would_enqueue_tasks=#{summary.would_enqueue_tasks} enqueued_tasks=#{summary.enqueued_tasks} " <>
        "skipped_replica_versions=#{summary.skipped_replica_versions} " <>
        "skipped_no_rule_versions=#{summary.skipped_no_rule_versions} " <>
        "refreshed_source_statuses=#{summary.refreshed_source_statuses} " <>
        "truncated=#{summary.is_truncated}"
    )

    if summary.is_truncated do
      IO.puts(
        "[maxio replication.backfill] next_key_marker=#{inspect(summary.next_key_marker)} " <>
          "next_version_id_marker=#{inspect(summary.next_version_id_marker)}"
      )
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
