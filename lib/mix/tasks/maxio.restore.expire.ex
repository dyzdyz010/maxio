defmodule Mix.Tasks.Maxio.Restore.Expire do
  @shortdoc "Expire due S3 restored archive copies"
  @moduledoc """
  Clears expired RestoreObject metadata and emits ObjectRestore:Delete
  notifications for archive object versions whose restored copy is due.

      mix maxio.restore.expire
      mix maxio.restore.expire --bucket my-bucket
      mix maxio.restore.expire --limit 500
      mix maxio.restore.expire --dry-run
      mix maxio.restore.expire --json
  """

  use Mix.Task

  alias Maxio.S3.RestoreExpiry

  @impl true
  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [bucket: :string, limit: :integer, dry_run: :boolean, json: :boolean],
        aliases: [b: :bucket]
      )

    if rest != [] or invalid != [] do
      unexpected = rest ++ Enum.map(invalid, &elem(&1, 0))

      Mix.raise(
        "usage: mix maxio.restore.expire [--bucket <name>] [--limit N] [--dry-run] [--json] " <>
          "(unexpected: #{inspect(unexpected)})"
      )
    end

    validate_limit!(Keyword.get(opts, :limit))
    Mix.Task.run("app.start")

    summary =
      RestoreExpiry.run(
        bucket: opts[:bucket],
        limit: Keyword.get(opts, :limit, 1000),
        dry_run: Keyword.get(opts, :dry_run, false)
      )

    print_summary(summary, opts)

    if summary.failed > 0 do
      Mix.raise("restore expiry failed for #{summary.failed} object versions")
    end
  end

  defp validate_limit!(nil), do: :ok
  defp validate_limit!(limit) when is_integer(limit) and limit > 0, do: :ok

  defp validate_limit!(limit),
    do: Mix.raise("--limit must be a positive integer, got #{inspect(limit)}")

  defp print_summary(summary, opts) do
    if Keyword.get(opts, :json, false) do
      IO.puts(Jason.encode!(summary))
    else
      IO.puts(
        "[maxio restore.expire] scanned=#{summary.scanned} expired=#{summary.expired} " <>
          "stale=#{summary.stale} failed=#{summary.failed} dry_run=#{summary.dry_run}"
      )

      Enum.each(Enum.reverse(summary.errors), fn error ->
        IO.puts(
          "[maxio restore.expire] error bucket=#{Map.get(error, :bucket)} " <>
            "key=#{Map.get(error, :key)} version_id=#{Map.get(error, :version_id)} " <>
            "reason=#{Map.get(error, :reason)}"
        )
      end)
    end
  end
end
