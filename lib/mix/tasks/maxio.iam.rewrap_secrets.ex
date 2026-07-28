defmodule Mix.Tasks.Maxio.Iam.RewrapSecrets do
  @shortdoc "Dry-run or rewrite IAM signing-secret envelopes to the current key"
  @moduledoc """
  Rewrites long-term access-key and STS session secret envelopes to the current
  `MAXIO_ACCESS_KEY_SECRET_KEY_ID` / `MAXIO_ACCESS_KEY_SECRET_KEY`.

  The task is dry-run by default. A real rewrite requires `--confirm`.

      mix maxio.iam.rewrap_secrets
      mix maxio.iam.rewrap_secrets --access-keys --confirm
      mix maxio.iam.rewrap_secrets --sts-sessions --limit 100 --json
  """
  use Mix.Task

  alias Mix.Tasks.Maxio.Iam.Mfa.Output

  @usage "usage: mix maxio.iam.rewrap_secrets [--access-keys] [--sts-sessions] [--limit N] [--dry-run | --confirm] [--json]"
  @switches [
    access_keys: :boolean,
    sts_sessions: :boolean,
    limit: :integer,
    dry_run: :boolean,
    confirm: :boolean,
    json: :boolean
  ]

  @impl true
  def run(argv) do
    {opts, rest, invalid} = OptionParser.parse(argv, strict: @switches)
    Output.reject_invalid!(rest, invalid, @usage)

    if Keyword.get(opts, :dry_run, false) and Keyword.get(opts, :confirm, false) do
      Mix.raise("--dry-run and --confirm are mutually exclusive")
    end

    Mix.Task.run("app.start")

    task_opts =
      [
        scopes: scopes(opts),
        dry_run: not Keyword.get(opts, :confirm, false)
      ]
      |> maybe_put_limit(Keyword.get(opts, :limit))

    case Maxio.IAM.rewrap_signing_secrets(task_opts) do
      {:ok, report} ->
        print_report(report, Keyword.get(opts, :json, false))

      {:error, report} ->
        print_report(report, Keyword.get(opts, :json, false))
        Mix.raise("iam signing secret rewrap blocked: #{inspect(report.totals.error_details)}")
    end
  end

  defp scopes(opts) do
    access_keys? = Keyword.get(opts, :access_keys, false)
    sts_sessions? = Keyword.get(opts, :sts_sessions, false)

    case {access_keys?, sts_sessions?} do
      {false, false} -> [:access_keys, :sts_sessions]
      {true, false} -> [:access_keys]
      {false, true} -> [:sts_sessions]
      {true, true} -> [:access_keys, :sts_sessions]
    end
  end

  defp maybe_put_limit(opts, nil), do: opts

  defp maybe_put_limit(opts, limit) when is_integer(limit) and limit > 0,
    do: Keyword.put(opts, :limit, limit)

  defp maybe_put_limit(_opts, _limit), do: Mix.raise(@usage)

  defp print_report(report, true), do: Output.print_json(json_report(report))

  defp print_report(report, false) do
    IO.puts(
      "[maxio iam.rewrap_secrets] status=#{report.status} dry_run=#{report.dry_run} " <>
        "current_key_id=#{inspect(report.current_key_id)} " <>
        "scanned=#{report.totals.scanned} candidates=#{report.totals.candidates} " <>
        "rewrapped=#{report.totals.rewrapped} errors=#{report.totals.errors}"
    )

    Enum.each(report.scopes, fn {scope, stats} ->
      IO.puts(
        "[maxio iam.rewrap_secrets.scope] scope=#{scope} scanned=#{stats.scanned} " <>
          "current=#{stats.current_key} stale_key=#{stats.stale_key} " <>
          "legacy_plaintext=#{stats.legacy_plaintext} candidates=#{stats.candidates} " <>
          "rewrapped=#{stats.rewrapped} errors=#{stats.errors}"
      )
    end)
  end

  defp json_report(report) do
    %{
      status: to_string(report.status),
      dry_run: report.dry_run,
      current_key_id: report.current_key_id,
      totals: json_stats(report.totals),
      scopes:
        Map.new(report.scopes, fn {scope, stats} ->
          {to_string(scope), json_stats(stats)}
        end)
    }
  end

  defp json_stats(stats) do
    stats
    |> Map.take([
      :scanned,
      :current_key,
      :candidates,
      :legacy_plaintext,
      :stale_key,
      :rewrapped,
      :errors,
      :error_details
    ])
    |> Map.update!(:error_details, fn errors ->
      Enum.map(errors, fn error ->
        %{
          scope: error.scope && to_string(error.scope),
          access_key_id: error.access_key_id,
          reason: inspect(error.reason)
        }
      end)
    end)
  end
end
