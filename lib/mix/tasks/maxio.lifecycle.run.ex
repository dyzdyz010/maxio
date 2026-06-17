defmodule Mix.Tasks.Maxio.Lifecycle.Run do
  @shortdoc "Run one maxio S3 lifecycle sweep"
  @moduledoc """
  Executes one deterministic lifecycle sweep.

      mix maxio.lifecycle.run
      mix maxio.lifecycle.run --bucket my-bucket
      mix maxio.lifecycle.run --dry-run

  Implemented actions:

    * current-version Expiration
    * NoncurrentVersionExpiration
    * ExpiredObjectDeleteMarker cleanup
    * AbortIncompleteMultipartUpload

  Transition actions remain explicit defers until maxio has tiering backends.
  MFA Delete buckets skip lifecycle actions that would permanently delete object versions.
  """
  use Mix.Task

  @impl true
  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [bucket: :string, dry_run: :boolean],
        aliases: [b: :bucket]
      )

    if rest != [] or invalid != [] do
      unexpected = rest ++ Enum.map(invalid, &elem(&1, 0))

      Mix.raise(
        "usage: mix maxio.lifecycle.run [--bucket <name>] [--dry-run] " <>
          "(unexpected: #{inspect(unexpected)})"
      )
    end

    Mix.Task.run("app.start")

    summary =
      Maxio.Lifecycle.run(
        bucket: opts[:bucket],
        dry_run: Keyword.get(opts, :dry_run, false)
      )

    IO.puts(
      "[maxio lifecycle] buckets=#{summary.buckets_scanned} " <>
        "objects_expired=#{summary.objects_expired} " <>
        "noncurrent_versions_expired=#{summary.noncurrent_versions_expired} " <>
        "delete_markers_removed=#{summary.delete_markers_removed} " <>
        "multipart_uploads_aborted=#{summary.multipart_uploads_aborted} " <>
        "mfa_delete_protected_actions_skipped=#{summary.mfa_delete_protected_actions_skipped} " <>
        "object_lock_protected_actions_skipped=#{summary.object_lock_protected_actions_skipped} " <>
        "unsupported_rules=#{summary.unsupported_rules} errors=#{length(summary.errors)}"
    )

    if summary.errors != [] do
      Enum.each(summary.errors, fn err ->
        IO.puts(
          "[maxio lifecycle] error bucket=#{err.bucket} key=#{err.key} reason=#{err.reason}"
        )
      end)

      Mix.raise("lifecycle sweep failed with #{length(summary.errors)} errors")
    end
  end
end
