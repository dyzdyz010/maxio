defmodule Mix.Tasks.Maxio.Console.DirectMultipart.Prune do
  @shortdoc "Prune unfinished Console browser-direct multipart uploads"
  @moduledoc """
  Evaluates Console browser-direct multipart upload registry rows and optionally
  aborts matching unfinished S3 multipart uploads.

      mix maxio.console.direct_multipart.prune --older-than-minutes 60 --all-owners --dry-run
      mix maxio.console.direct_multipart.prune --older-than-seconds 3600 --principal-arn arn:aws:iam:::root --confirm-abort
      mix maxio.console.direct_multipart.prune --older-than-minutes 1440 --all-owners --bucket photos --prefix raw/ --json --dry-run

  The task never reads object bytes and never stores SSE-C customer material.
  Actual aborts require `--confirm-abort`; otherwise use `--dry-run`.
  """

  use Mix.Task

  alias Maxio.Console.DirectMultipartUpload

  @switches [
    bucket: :string,
    prefix: :string,
    scope: :string,
    query: :string,
    principal_arn: :string,
    access_key: :string,
    all_owners: :boolean,
    older_than_seconds: :integer,
    older_than_minutes: :integer,
    min_size: :integer,
    max_size: :integer,
    limit: :integer,
    dry_run: :boolean,
    confirm_abort: :boolean,
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

    validate_cli_opts!(opts)

    Mix.Task.run("app.start")

    case DirectMultipartUpload.prune_active(prune_opts(opts)) do
      {:ok, summary} ->
        print_summary(summary, opts)

        if summary.failed > 0 do
          Mix.raise("direct multipart prune failed for #{summary.failed} uploads")
        end

      {:error, reason} ->
        Mix.raise("direct multipart prune failed: #{inspect(reason)}")
    end
  end

  defp validate_cli_opts!(opts) do
    dry_run? = Keyword.get(opts, :dry_run, false)
    confirm? = Keyword.get(opts, :confirm_abort, false)

    cond do
      dry_run? and confirm? ->
        Mix.raise("--dry-run and --confirm-abort are mutually exclusive")

      not dry_run? and not confirm? ->
        Mix.raise("--dry-run or --confirm-abort is required")

      Keyword.has_key?(opts, :older_than_seconds) and Keyword.has_key?(opts, :older_than_minutes) ->
        Mix.raise("use either --older-than-seconds or --older-than-minutes, not both")

      not Keyword.has_key?(opts, :older_than_seconds) and
          not Keyword.has_key?(opts, :older_than_minutes) ->
        Mix.raise("--older-than-seconds or --older-than-minutes is required")

      true ->
        :ok
    end

    validate_positive!(opts, :older_than_seconds, "--older-than-seconds")
    validate_positive!(opts, :older_than_minutes, "--older-than-minutes")
    validate_positive!(opts, :limit, "--limit")
    validate_non_negative!(opts, :min_size, "--min-size")
    validate_non_negative!(opts, :max_size, "--max-size")
    validate_scope!(Keyword.get(opts, :scope))
    validate_owner_scope!(opts)
    validate_size_range!(Keyword.get(opts, :min_size), Keyword.get(opts, :max_size))
  end

  defp prune_opts(opts) do
    []
    |> put_if_present(:bucket, Keyword.get(opts, :bucket))
    |> put_if_present(:prefix, Keyword.get(opts, :prefix))
    |> put_if_present(:scope, Keyword.get(opts, :scope))
    |> put_if_present(:query, Keyword.get(opts, :query))
    |> put_if_present(:principal_arn, Keyword.get(opts, :principal_arn))
    |> put_if_present(:access_key, Keyword.get(opts, :access_key))
    |> put_if_present(:all_owners, Keyword.get(opts, :all_owners))
    |> put_if_present(:older_than_seconds, older_than_seconds(opts))
    |> put_if_present(:min_file_size, Keyword.get(opts, :min_size))
    |> put_if_present(:max_file_size, Keyword.get(opts, :max_size))
    |> put_if_present(:limit, Keyword.get(opts, :limit))
    |> Keyword.put(:dry_run, Keyword.get(opts, :dry_run, false))
    |> Keyword.put(:confirm_abort, Keyword.get(opts, :confirm_abort, false))
  end

  defp older_than_seconds(opts) do
    case Keyword.fetch(opts, :older_than_seconds) do
      {:ok, seconds} -> seconds
      :error -> Keyword.fetch!(opts, :older_than_minutes) * 60
    end
  end

  defp print_summary(summary, opts) do
    if Keyword.get(opts, :json, false) do
      IO.puts(Jason.encode!(summary))
    else
      IO.puts(
        "[maxio console.direct_multipart.prune] dry_run=#{summary.dry_run} " <>
          "matched=#{summary.matched} selected=#{summary.selected} " <>
          "would_abort=#{summary.would_abort} aborted=#{summary.aborted} " <>
          "not_found=#{summary.not_found} failed=#{summary.failed} skipped=#{summary.skipped}"
      )

      Enum.each(Enum.reverse(summary.errors), fn error ->
        IO.puts(
          "[maxio console.direct_multipart.prune] error bucket=#{Map.get(error, :bucket)} " <>
            "key=#{Map.get(error, :key)} upload_id=#{Map.get(error, :upload_id)} " <>
            "registry_id=#{Map.get(error, :registry_id)} reason=#{Map.get(error, :reason)}"
        )
      end)
    end
  end

  defp validate_owner_scope!(opts) do
    all_owners? = Keyword.get(opts, :all_owners, false)

    has_owner_filter? =
      Keyword.has_key?(opts, :principal_arn) or Keyword.has_key?(opts, :access_key)

    cond do
      all_owners? and has_owner_filter? ->
        Mix.raise("--all-owners cannot be combined with --principal-arn or --access-key")

      all_owners? or has_owner_filter? ->
        :ok

      true ->
        Mix.raise("--all-owners, --principal-arn, or --access-key is required")
    end
  end

  defp validate_scope!(nil), do: :ok

  defp validate_scope!(scope) when scope in ["folder", "recursive", "bucket"], do: :ok

  defp validate_scope!(scope),
    do: Mix.raise("--scope must be one of folder, recursive, bucket; got #{inspect(scope)}")

  defp validate_size_range!(nil, _max_size), do: :ok
  defp validate_size_range!(_min_size, nil), do: :ok
  defp validate_size_range!(min_size, max_size) when min_size <= max_size, do: :ok

  defp validate_size_range!(_min_size, _max_size),
    do: Mix.raise("--min-size must be <= --max-size")

  defp validate_positive!(opts, key, name) do
    case Keyword.get(opts, key) do
      nil -> :ok
      value when is_integer(value) and value > 0 -> :ok
      value -> Mix.raise("#{name} must be a positive integer, got #{inspect(value)}")
    end
  end

  defp validate_non_negative!(opts, key, name) do
    case Keyword.get(opts, key) do
      nil -> :ok
      value when is_integer(value) and value >= 0 -> :ok
      value -> Mix.raise("#{name} must be a non-negative integer, got #{inspect(value)}")
    end
  end

  defp put_if_present(opts, _key, nil), do: opts
  defp put_if_present(opts, key, value), do: Keyword.put(opts, key, value)

  defp usage do
    "usage: mix maxio.console.direct_multipart.prune " <>
      "[--bucket <name>] [--prefix <prefix>] [--scope folder|recursive|bucket] " <>
      "[--query <text>] (--all-owners | --principal-arn <arn> | --access-key <id>) " <>
      "(--older-than-seconds N | --older-than-minutes N) [--min-size N] [--max-size N] " <>
      "[--limit N] (--dry-run | --confirm-abort) [--json]"
  end
end
