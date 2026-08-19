defmodule Maxio.IAM.OIDCProviderRefresh do
  @moduledoc """
  Refreshes persisted IAM OIDC provider JWKS snapshots.

  This module is deliberately kept out of the STS request path. STS
  AssumeRoleWithWebIdentity continues to verify tokens against the last known
  good public JWKS stored in Postgres; discovery/network failures are surfaced
  through this operator path without mutating the provider row.
  """

  import Ecto.Query

  alias Maxio.Cluster.Notify
  alias Maxio.IAM.OIDCProvider
  alias Maxio.Repo
  alias Maxio.S3.Log

  @default_limit 100
  @default_refresh_after_seconds 86_400

  @type report :: %{
          status: atom(),
          dry_run: boolean(),
          scanned: non_neg_integer(),
          candidates: non_neg_integer(),
          refreshed: non_neg_integer(),
          skipped: non_neg_integer(),
          failed: non_neg_integer(),
          errors: [map()],
          providers: [map()]
        }

  @spec refresh(String.t(), keyword()) :: {:ok, report()} | {:error, report()}
  def refresh(provider_arn_or_url, opts \\ [])

  def refresh(provider_arn_or_url, opts) when is_binary(provider_arn_or_url) and is_list(opts) do
    report = new_report(opts) |> Map.put(:scanned, 1)

    case fetch_provider(provider_arn_or_url) do
      {:ok, %OIDCProvider{} = provider} ->
        provider
        |> refresh_provider(report, Keyword.put(opts, :force, true))
        |> finish()

      :error ->
        report
        |> fail(%{
          provider_arn: provider_arn_or_url,
          issuer_url: nil,
          reason: :not_found
        })
        |> finish()

      {:error, reason} ->
        report
        |> fail(%{
          provider_arn: provider_arn_or_url,
          issuer_url: nil,
          reason: reason
        })
        |> finish()
    end
  end

  def refresh(_provider_arn_or_url, opts) when is_list(opts) do
    new_report(opts)
    |> fail(%{provider_arn: nil, issuer_url: nil, reason: :malformed})
    |> finish()
  end

  @spec refresh_all(keyword()) :: {:ok, report()} | {:error, report()}
  def refresh_all(opts \\ []) when is_list(opts) do
    providers = providers_to_scan(opts)

    providers
    |> Enum.reduce(new_report(opts) |> Map.put(:scanned, length(providers)), fn provider,
                                                                                report ->
      refresh_provider(provider, report, opts)
    end)
    |> finish()
  end

  defp providers_to_scan(opts) do
    include_disabled? = truthy?(Keyword.get(opts, :include_disabled, false))
    limit = positive_int(Keyword.get(opts, :limit, @default_limit), @default_limit)
    now = now(opts)
    force? = truthy?(Keyword.get(opts, :force, false))

    refresh_after_seconds =
      positive_int(
        Keyword.get(opts, :refresh_after_seconds, @default_refresh_after_seconds),
        @default_refresh_after_seconds
      )

    OIDCProvider
    |> maybe_active_only(include_disabled?)
    |> maybe_due_only(force?, now, refresh_after_seconds)
    |> order_by([p], asc: p.issuer_host_path)
    |> limit(^limit)
    |> Repo.all()
  end

  defp maybe_active_only(query, true), do: query
  defp maybe_active_only(query, false), do: where(query, [p], p.status == "active")

  defp maybe_due_only(query, true, _now, _refresh_after_seconds), do: query

  defp maybe_due_only(query, false, now, refresh_after_seconds) do
    cutoff = DateTime.add(now, -refresh_after_seconds, :second)
    where(query, [p], is_nil(p.jwks_fetched_at) or p.jwks_fetched_at <= ^cutoff)
  end

  defp refresh_provider(%OIDCProvider{} = provider, report, opts) do
    cond do
      provider.status != "active" and not truthy?(Keyword.get(opts, :include_disabled, false)) ->
        skip(report, provider, :disabled)

      not due?(provider, opts) ->
        skip(report, provider, :not_due)

      true ->
        run_refresh(provider, report, opts)
    end
  end

  defp run_refresh(%OIDCProvider{} = provider, report, opts) do
    report = %{report | candidates: report.candidates + 1}

    with {:ok, discovery} <- discover(provider, opts),
         {:ok, attrs} <- discovery_attrs(discovery, opts),
         :ok <- validate_discovery_thumbprints(provider, attrs),
         {:ok, changeset} <- refresh_changeset(provider, attrs) do
      if report.dry_run do
        record_dry_run(report, provider, attrs)
      else
        commit_refresh(provider, changeset, report, attrs)
      end
    else
      {:error, reason} ->
        record_failure(report, provider, reason)
    end
  rescue
    error ->
      record_failure(report, provider, {:crashed, Exception.message(error)})
  catch
    kind, reason ->
      record_failure(report, provider, {:caught, kind, reason})
  end

  defp discover(%OIDCProvider{} = provider, opts) do
    discoverer =
      Keyword.get(
        opts,
        :discoverer,
        Application.get_env(:maxio, :oidc_discovery, Maxio.IAM.OIDCDiscovery.HTTP)
      )

    discovery_opts =
      opts
      |> Keyword.get(:discovery_opts, [])
      |> put_provider_thumbprints(provider)

    with true <- is_atom(discoverer),
         {:module, ^discoverer} <- Code.ensure_loaded(discoverer),
         true <- function_exported?(discoverer, :discover, 2) do
      discoverer.discover(provider.issuer_url, discovery_opts)
    else
      _other -> {:error, :invalid_oidc_discovery_provider}
    end
  end

  defp put_provider_thumbprints(discovery_opts, %OIDCProvider{} = provider) do
    case normalize_thumbprints(provider.thumbprints || []) do
      [] -> discovery_opts
      thumbprints -> Keyword.put(discovery_opts, :thumbprints, thumbprints)
    end
  end

  defp discovery_attrs(discovery, opts) when is_map(discovery) do
    now = now(opts)

    attrs = %{
      jwks: map_get(discovery, :jwks),
      jwks_fetched_at: map_get(discovery, :jwks_fetched_at) || now,
      discovery_document: map_get(discovery, :discovery_document) || %{},
      thumbprints: discovery_thumbprints(discovery)
    }

    with %{} <- attrs.jwks,
         %DateTime{} <- attrs.jwks_fetched_at,
         %{} <- attrs.discovery_document do
      {:ok, attrs}
    else
      _other -> {:error, :oidc_discovery_malformed_json}
    end
  end

  defp discovery_attrs(_discovery, _opts), do: {:error, :oidc_discovery_malformed_json}

  defp validate_discovery_thumbprints(%OIDCProvider{} = provider, attrs) do
    discovered = Map.get(attrs, :thumbprints, [])

    # `discovered == [] or` 这层短路与 `thumbprints_cover?(_, [])` 完全重复，且让后者不可达。
    # 空发现集合的语义（无可校验指纹 → 放行）现在只由谓词自己表达，结果逐字相同。
    if thumbprints_cover?(provider.thumbprints || [], discovered) do
      :ok
    else
      {:error, :oidc_discovery_thumbprint_mismatch}
    end
  end

  defp refresh_changeset(%OIDCProvider{} = provider, attrs) do
    changeset = OIDCProvider.changeset(provider, Map.drop(attrs, [:thumbprints]))

    if changeset.valid? do
      {:ok, changeset}
    else
      {:error, {:invalid_oidc_provider_refresh, changeset_errors(changeset)}}
    end
  end

  defp commit_refresh(%OIDCProvider{} = provider, _changeset, report, attrs) do
    case locked_update(provider, attrs) do
      {:ok, updated} ->
        Notify.broadcast({:iam_changed, updated.provider_arn})

        Log.info("iam oidc provider jwks refresh updated provider",
          action: :iam_oidc_provider_jwks_refresh,
          provider_arn: updated.provider_arn,
          issuer_url: updated.issuer_url,
          reason: "key_count=#{key_count(attrs.jwks)}"
        )

        record_success(report, updated, attrs, :refreshed)

      {:error, changeset} ->
        if match?(%Ecto.Changeset{}, changeset) do
          record_failure(
            report,
            provider,
            {:invalid_oidc_provider_refresh, changeset_errors(changeset)}
          )
        else
          record_failure(report, provider, changeset)
        end

      {:stale, current} ->
        Log.warn("iam oidc provider jwks refresh skipped stale provider",
          action: :iam_oidc_provider_jwks_refresh,
          provider_arn: provider.provider_arn,
          issuer_url: provider.issuer_url,
          reason: "provider_changed current_updated_at=#{inspect(current.updated_at)}"
        )

        skip(report, provider, :provider_changed)
    end
  end

  defp locked_update(%OIDCProvider{} = provider, attrs) do
    Repo.transaction(fn ->
      current =
        OIDCProvider
        |> where([p], p.id == ^provider.id)
        |> lock("FOR UPDATE")
        |> Repo.one()

      cond do
        is_nil(current) ->
          Repo.rollback(:not_found)

        current.updated_at != provider.updated_at ->
          Repo.rollback({:stale, current})

        true ->
          current
          |> OIDCProvider.changeset(Map.drop(attrs, [:thumbprints]))
          |> Repo.update()
          |> case do
            {:ok, updated} -> updated
            {:error, changeset} -> Repo.rollback({:error, changeset})
          end
      end
    end)
    |> case do
      {:ok, updated} -> {:ok, updated}
      {:error, {:error, changeset}} -> {:error, changeset}
      {:error, {:stale, current}} -> {:stale, current}
      {:error, :not_found} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp record_dry_run(report, %OIDCProvider{} = provider, attrs) do
    Log.info("iam oidc provider jwks refresh dry-run validated provider",
      action: :iam_oidc_provider_jwks_refresh,
      provider_arn: provider.provider_arn,
      issuer_url: provider.issuer_url,
      reason: "key_count=#{key_count(attrs.jwks)}"
    )

    record_success(report, provider, attrs, :would_refresh)
  end

  defp record_success(report, %OIDCProvider{} = provider, attrs, status) do
    detail = %{
      provider_arn: provider.provider_arn,
      issuer_url: provider.issuer_url,
      status: status,
      key_count: key_count(attrs.jwks),
      jwks_fetched_at: attrs.jwks_fetched_at
    }

    %{report | refreshed: report.refreshed + if(status == :refreshed, do: 1, else: 0)}
    |> put_provider_detail(detail)
  end

  defp record_failure(report, %OIDCProvider{} = provider, reason) do
    Log.warn("iam oidc provider jwks refresh failed",
      action: :iam_oidc_provider_jwks_refresh,
      provider_arn: provider.provider_arn,
      issuer_url: provider.issuer_url,
      reason: inspect(safe_reason(reason))
    )

    report
    |> fail(%{
      provider_arn: provider.provider_arn,
      issuer_url: provider.issuer_url,
      reason: safe_reason(reason)
    })
  end

  defp skip(report, %OIDCProvider{} = provider, reason) do
    detail = %{
      provider_arn: provider.provider_arn,
      issuer_url: provider.issuer_url,
      status: :skipped,
      reason: reason,
      jwks_fetched_at: provider.jwks_fetched_at
    }

    %{report | skipped: report.skipped + 1}
    |> put_provider_detail(detail)
  end

  defp fail(report, detail) do
    detail = Map.update!(detail, :reason, &safe_reason/1)

    %{
      report
      | failed: report.failed + 1,
        errors: [detail | report.errors]
    }
    |> put_provider_detail(Map.put(detail, :status, :failed))
  end

  defp put_provider_detail(report, detail),
    do: %{report | providers: [detail | report.providers]}

  defp finish(report) do
    report =
      report
      |> Map.update!(:providers, &Enum.reverse/1)
      |> Map.update!(:errors, &Enum.reverse/1)
      |> Map.put(:status, report_status(report))

    Log.info("iam oidc provider jwks refresh pass complete",
      action: :iam_oidc_provider_jwks_refresh,
      reason:
        "status=#{report.status} dry_run=#{report.dry_run} scanned=#{report.scanned} " <>
          "candidates=#{report.candidates} refreshed=#{report.refreshed} " <>
          "skipped=#{report.skipped} failed=#{report.failed}"
    )

    if report.failed > 0, do: {:error, report}, else: {:ok, report}
  end

  defp report_status(%{failed: failed, refreshed: refreshed}) when failed > 0 and refreshed > 0,
    do: :partial

  defp report_status(%{failed: failed}) when failed > 0, do: :failed
  defp report_status(%{dry_run: true, candidates: candidates}) when candidates > 0, do: :dry_run
  defp report_status(%{refreshed: refreshed}) when refreshed > 0, do: :refreshed
  defp report_status(%{scanned: 0}), do: :empty
  defp report_status(%{candidates: 0}), do: :not_due
  defp report_status(_report), do: :ok

  defp due?(%OIDCProvider{} = provider, opts) do
    if truthy?(Keyword.get(opts, :force, false)) do
      true
    else
      due_by_age?(provider, opts)
    end
  end

  defp due_by_age?(%OIDCProvider{jwks_fetched_at: nil}, _opts), do: true

  defp due_by_age?(%OIDCProvider{jwks_fetched_at: %DateTime{} = fetched_at}, opts) do
    refresh_after_seconds =
      positive_int(
        Keyword.get(opts, :refresh_after_seconds, @default_refresh_after_seconds),
        @default_refresh_after_seconds
      )

    cutoff = DateTime.add(now(opts), -refresh_after_seconds, :second)
    DateTime.compare(fetched_at, cutoff) != :gt
  end

  defp due_by_age?(%OIDCProvider{}, _opts), do: true

  defp fetch_provider("arn:aws:iam:::oidc-provider/" <> _resource = provider_arn) do
    case Repo.get_by(OIDCProvider, provider_arn: provider_arn) do
      %OIDCProvider{} = provider -> {:ok, provider}
      nil -> :error
    end
  end

  defp fetch_provider(issuer_url) when is_binary(issuer_url) do
    issuer_url = issuer_url |> String.trim() |> String.trim_trailing("/")

    case Maxio.STS.WebIdentity.issuer_host_path(issuer_url) do
      {:ok, issuer_host_path} ->
        case Repo.get_by(OIDCProvider, issuer_host_path: issuer_host_path) do
          %OIDCProvider{} = provider -> {:ok, provider}
          nil -> :error
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp new_report(opts) do
    %{
      status: :pending,
      dry_run: Keyword.get(opts, :dry_run, true) != false,
      scanned: 0,
      candidates: 0,
      refreshed: 0,
      skipped: 0,
      failed: 0,
      errors: [],
      providers: []
    }
  end

  defp map_get(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp key_count(jwks) do
    case OIDCProvider.public_jwks(jwks) do
      %{"keys" => keys} when is_list(keys) -> length(keys)
      _other -> 0
    end
  end

  # 唯一调用方 `discovery_attrs/2` 已经用 `when is_map(discovery)` + `_discovery` 兜底
  # 把非 map 的 discovery 结构化拒成 `{:error, :oidc_discovery_malformed_json}`。
  # 这里原来重复了一层 map 守卫，且兜底返回 `[]` —— 那等于把畸形 discovery 静默当成
  # 「没有 thumbprint」（AGENTS.md §3 明令禁止的静默放行），何况永远不可达。去掉重复层，
  # 让上游那道**可达且结构化**的关卡成为唯一契约边界。
  defp discovery_thumbprints(discovery) do
    discovery
    |> map_get(:thumbprints)
    |> normalize_thumbprints()
    |> Enum.uniq_by(&String.downcase/1)
  end

  defp normalize_thumbprints(nil), do: []
  defp normalize_thumbprints(values) when is_list(values), do: Enum.map(values, &to_string/1)
  defp normalize_thumbprints(value), do: [to_string(value)]

  defp thumbprints_cover?(_configured_thumbprints, []), do: true

  defp thumbprints_cover?(configured_thumbprints, discovered_thumbprints) do
    configured =
      configured_thumbprints
      |> Enum.map(&to_string/1)
      |> Enum.map(&String.downcase/1)
      |> MapSet.new()

    Enum.all?(discovered_thumbprints, &MapSet.member?(configured, String.downcase(&1)))
  end

  defp changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end

  defp safe_reason(reason) when is_atom(reason), do: reason
  defp safe_reason(%{} = reason), do: reason

  defp safe_reason({:invalid_oidc_provider_refresh, errors}) when is_map(errors) do
    %{code: :invalid_oidc_provider_refresh, errors: errors}
  end

  defp safe_reason({:crashed, message}) when is_binary(message), do: %{code: :crashed}
  defp safe_reason({:caught, kind, _reason}), do: %{code: :caught, kind: kind}
  defp safe_reason(_reason), do: :oidc_provider_refresh_failed

  defp positive_int(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_int(_value, default), do: default

  defp now(opts) do
    case Keyword.get(opts, :now) do
      %DateTime{} = now -> DateTime.truncate(now, :microsecond)
      _other -> DateTime.utc_now() |> DateTime.truncate(:microsecond)
    end
  end

  defp truthy?(value) when value in [true, "true", "1", 1], do: true
  defp truthy?(_value), do: false
end
