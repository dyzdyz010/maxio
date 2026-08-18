defmodule Mix.Tasks.Maxio.ReservedBucket.Purge do
  @shortdoc "List or delete object keys shadowed by the reserved /minio paths"
  @moduledoc """
  Inspects and cleans up object keys that are shadowed by the MinIO reserved path
  namespace (`/minio/health/*`, `/minio/admin/*`, the Prometheus metrics paths).

      mix maxio.reserved_bucket.purge --dry-run
      mix maxio.reserved_bucket.purge --dry-run --json
      mix maxio.reserved_bucket.purge --confirm-delete
      mix maxio.reserved_bucket.purge --confirm-delete --bucket minio

  Why this task exists: in path-style addressing `GET /minio/health/live` is claimed by
  the health probe, so the object with that exact bucket/key can be neither read nor
  deleted through the S3 API, and its bucket can therefore never be emptied (DeleteBucket
  keeps returning `BucketNotEmpty`). Operators must not be left without an exit, and the
  exit must not require changing DNS or configuring virtual-host addressing — hence a CLI
  (AGENTS.md §4.4 CLI first). The startup audit points straight at this task.

  The scan surface is derived from `Maxio.S3.ReservedNamespace`'s claim table, so it is by
  construction identical to what the plugs actually claim: this task never deletes a key
  that is still reachable over S3.

  `--dry-run` and `--confirm-delete` are mutually exclusive and one of them is required —
  deleting object data must always be an explicit act.

  ## Object Lock

  Deletion goes through the one and only S3 version-delete commit path
  (`Maxio.S3.Handlers.Object.delete_version!/4`), so a version protected by Object Lock is
  **refused, never destroyed**. Refused versions are listed one by one as `retained ...`
  lines (which lock, until when) and the task exits non-zero with an explicit
  "the bucket still cannot be emptied" message — a purge that left protected data behind
  must never be reported as success.

      mix maxio.reserved_bucket.purge --confirm-delete --bypass-governance

  `--bypass-governance` mirrors S3's `x-amz-bypass-governance-retention`: it releases
  **GOVERNANCE retention only**. COMPLIANCE retention and legal holds can never be
  bypassed, by anyone, including root — that is the whole point of those modes.
  Authorization boundary: being able to run a mix task on the server *is* the operator
  role here (the HTTP path uses `s3:BypassGovernanceRetention` instead).
  """

  use Mix.Task

  alias Maxio.S3.ReservedBucketAudit

  @switches [
    bucket: :string,
    dry_run: :boolean,
    confirm_delete: :boolean,
    bypass_governance: :boolean,
    json: :boolean
  ]
  @aliases [b: :bucket]

  @impl true
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: @switches, aliases: @aliases)

    if rest != [] or invalid != [] do
      unexpected = rest ++ Enum.map(invalid, &elem(&1, 0))
      Mix.raise("#{usage()} (unexpected: #{inspect(unexpected)})")
    end

    validate_mode!(opts)

    Mix.Task.run("app.start")

    purge_opts =
      []
      |> put_if_present(:bucket, Keyword.get(opts, :bucket))
      |> Keyword.put(:confirm_delete, Keyword.get(opts, :confirm_delete, false))
      |> Keyword.put(:bypass_governance, Keyword.get(opts, :bypass_governance, false))

    keys = ReservedBucketAudit.shadowed_keys(purge_opts)

    case ReservedBucketAudit.purge(purge_opts) do
      {:ok, summary} ->
        print(summary, keys, opts)
        raise_unless_clean!(summary)
    end
  end

  # 退出码是运维脚本唯一会读的东西。"删了一部分、剩下的被 Object Lock 挡住"绝不能以 0 退出
  # ——那等于告诉调用方"桶已清空"，而 DeleteBucket 仍会 BucketNotEmpty（铁律 3）。
  # dry-run 不算失败（它本来就什么都没删），但仍会打印 retained 预告。
  defp raise_unless_clean!(summary) do
    cond do
      summary.failed > 0 ->
        Mix.raise("reserved bucket purge failed for #{summary.failed} object version(s)")

      not summary.dry_run and summary.retained_count > 0 ->
        Mix.raise(
          "the bucket still cannot be emptied: #{summary.retained_count} shadowed object " <>
            "version(s) are protected by Object Lock and were retained (see the `retained` " <>
            "lines above). COMPLIANCE retention and legal holds cannot be bypassed by anyone; " <>
            "GOVERNANCE retention can be released with --bypass-governance."
        )

      true ->
        :ok
    end
  end

  defp validate_mode!(opts) do
    dry_run? = Keyword.get(opts, :dry_run, false)
    confirm? = Keyword.get(opts, :confirm_delete, false)

    cond do
      dry_run? and confirm? -> Mix.raise("--dry-run and --confirm-delete are mutually exclusive")
      not dry_run? and not confirm? -> Mix.raise("--dry-run or --confirm-delete is required")
      true -> :ok
    end
  end

  defp print(summary, keys, opts) do
    if Keyword.get(opts, :json, false) do
      summary
      |> Map.put(:keys, Enum.map(keys, fn {bucket, key} -> %{bucket: bucket, key: key} end))
      |> Jason.encode!()
      |> IO.puts()
    else
      IO.puts(
        "[maxio reserved_bucket.purge] dry_run=#{summary.dry_run} matched_keys=#{summary.matched} " <>
          "versions=#{summary.versions} deleted=#{summary.deleted} " <>
          "retained=#{summary.retained_count} failed=#{summary.failed}"
      )

      Enum.each(keys, fn {bucket, key} ->
        IO.puts("[maxio reserved_bucket.purge] shadowed bucket=#{bucket} key=#{key}")
      end)

      Enum.each(summary.retained, &IO.puts(retained_line(&1, summary.dry_run)))

      Enum.each(summary.errors, fn error ->
        IO.puts(
          "[maxio reserved_bucket.purge] error bucket=#{error.bucket} key=#{error.key} " <>
            "version_id=#{error.version_id} reason=#{error.reason}"
        )
      end)

      if summary.dry_run and summary.matched > 0 do
        IO.puts(
          "[maxio reserved_bucket.purge] nothing was deleted; rerun with --confirm-delete to remove them"
        )
      end

      if summary.dry_run and summary.retained_count > 0 do
        IO.puts(
          "[maxio reserved_bucket.purge] --confirm-delete would still leave " <>
            "#{summary.retained_count} version(s) behind: the bucket still cannot be emptied " <>
            "while they are protected"
        )
      end
    end
  end

  # 每条保留必须自带"哪种锁 + 到期时间 + 能不能绕过"——运维要据此决定是等保留期、
  # 解 legal hold，还是加 --bypass-governance，而不是回来再猜一遍。
  defp retained_line(retained, dry_run?) do
    verb = if dry_run?, do: "would be retained", else: "retained"

    "[maxio reserved_bucket.purge] #{verb} bucket=#{retained.bucket} key=#{retained.key} " <>
      "version_id=#{retained.version_id} lock=#{retained.reason} " <>
      "mode=#{retained.mode || "-"} retain_until=#{format_retain_until(retained.retain_until)} " <>
      "bypassable=#{retained.bypassable?} " <>
      "(object lock forbids deletion; the bucket still cannot be emptied)"
  end

  defp format_retain_until(%DateTime{} = at), do: DateTime.to_iso8601(at)
  defp format_retain_until(_other), do: "-"

  defp put_if_present(opts, _key, nil), do: opts
  defp put_if_present(opts, key, value), do: Keyword.put(opts, key, value)

  defp usage do
    "usage: mix maxio.reserved_bucket.purge (--dry-run | --confirm-delete) " <>
      "[--bucket <name>] [--bypass-governance] [--json]"
  end
end
