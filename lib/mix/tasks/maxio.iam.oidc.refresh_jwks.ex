defmodule Mix.Tasks.Maxio.Iam.Oidc.RefreshJwks do
  @shortdoc "Dry-run or refresh IAM OIDC provider JWKS snapshots"
  @moduledoc """
  Refresh persisted IAM OIDC provider JWKS snapshots through bounded OIDC
  discovery.

  The task is dry-run by default. A real DB update requires `--confirm`.

      mix maxio.iam.oidc.refresh_jwks --all
      mix maxio.iam.oidc.refresh_jwks --all --confirm
      mix maxio.iam.oidc.refresh_jwks --provider arn:aws:iam:::oidc-provider/idp.example.test
      mix maxio.iam.oidc.refresh_jwks --issuer https://idp.example.test/tenant --json
  """

  use Mix.Task

  alias Mix.Tasks.Maxio.Iam.Mfa.Output

  @usage "usage: mix maxio.iam.oidc.refresh_jwks (--all | --provider ARN | --issuer URL) [--limit N] [--refresh-after-seconds N] [--force] [--include-disabled] [--dry-run | --confirm] [--json]"
  @switches [
    all: :boolean,
    provider: :string,
    issuer: :string,
    limit: :integer,
    refresh_after_seconds: :integer,
    stale_after_seconds: :integer,
    force: :boolean,
    include_disabled: :boolean,
    dry_run: :boolean,
    confirm: :boolean,
    json: :boolean
  ]

  @impl true
  def run(argv) do
    {opts, rest, invalid} = OptionParser.parse(argv, strict: @switches)
    Output.reject_invalid!(rest, invalid, @usage)
    validate_flags!(opts)

    Mix.Task.run("app.start")

    result =
      case target(opts) do
        :all ->
          Maxio.IAM.refresh_oidc_provider_jwks_if_due(refresh_opts(opts))

        {:provider, provider_arn} ->
          Maxio.IAM.refresh_oidc_provider_jwks(provider_arn, refresh_opts(opts))

        {:issuer, issuer_url} ->
          Maxio.IAM.refresh_oidc_provider_jwks(issuer_url, refresh_opts(opts))
      end

    case result do
      {:ok, report} ->
        print_report(report, Keyword.get(opts, :json, false))

      {:error, report} ->
        print_report(report, Keyword.get(opts, :json, false))
        Mix.raise("iam oidc jwks refresh failed: #{inspect(report.errors)}")
    end
  end

  defp validate_flags!(opts) do
    if Keyword.get(opts, :dry_run, false) and Keyword.get(opts, :confirm, false) do
      Mix.raise("--dry-run and --confirm are mutually exclusive")
    end

    case Enum.count([Keyword.get(opts, :all), opts[:provider], opts[:issuer]], &present?/1) do
      1 -> :ok
      _other -> Mix.raise(@usage)
    end

    validate_positive!(opts[:limit], "--limit")
    validate_positive!(refresh_after_seconds(opts), "--refresh-after-seconds")
  end

  defp target(opts) do
    cond do
      Keyword.get(opts, :all, false) -> :all
      is_binary(opts[:provider]) -> {:provider, opts[:provider]}
      is_binary(opts[:issuer]) -> {:issuer, opts[:issuer]}
    end
  end

  defp refresh_opts(opts) do
    []
    |> maybe_put(:limit, opts[:limit])
    |> maybe_put(:refresh_after_seconds, refresh_after_seconds(opts))
    |> maybe_put(:force, Keyword.get(opts, :force, false))
    |> maybe_put(:include_disabled, Keyword.get(opts, :include_disabled, false))
    |> Keyword.put(:dry_run, not Keyword.get(opts, :confirm, false))
  end

  defp refresh_after_seconds(opts),
    do: opts[:refresh_after_seconds] || opts[:stale_after_seconds]

  defp print_report(report, true), do: Output.print_json(json_report(report))

  defp print_report(report, false) do
    IO.puts(
      "[maxio iam.oidc.refresh_jwks] status=#{report.status} dry_run=#{report.dry_run} " <>
        "scanned=#{report.scanned} candidates=#{report.candidates} refreshed=#{report.refreshed} " <>
        "skipped=#{report.skipped} failed=#{report.failed}"
    )

    Enum.each(report.providers, fn provider ->
      IO.puts(
        "[maxio iam.oidc.refresh_jwks.provider] status=#{provider.status} " <>
          "provider_arn=#{inspect(provider.provider_arn)} issuer_url=#{inspect(provider.issuer_url)} " <>
          "key_count=#{Map.get(provider, :key_count, 0)} reason=#{inspect(Map.get(provider, :reason))}"
      )
    end)
  end

  defp json_report(report) do
    %{
      status: report.status,
      dry_run: report.dry_run,
      scanned: report.scanned,
      candidates: report.candidates,
      refreshed: report.refreshed,
      skipped: report.skipped,
      failed: report.failed,
      providers: report.providers,
      errors: report.errors
    }
  end

  defp validate_positive!(nil, _flag), do: :ok
  defp validate_positive!(value, _flag) when is_integer(value) and value > 0, do: :ok

  defp validate_positive!(value, flag),
    do: Mix.raise("#{flag} must be a positive integer, got #{inspect(value)}")

  defp present?(true), do: true
  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, _key, false), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
