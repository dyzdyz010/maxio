defmodule Maxio.IAM.SigningSecretRewriter do
  @moduledoc """
  Rewrites IAM signing-secret envelopes to the currently configured key.

  The service verifies every selected row by decrypting it before planning any
  write. A confirmed run writes all planned rows in one transaction with an
  optimistic `secret_key` guard, so concurrent secret changes cannot be
  overwritten silently.
  """

  import Ecto.Query

  alias Maxio.Cluster.Notify
  alias Maxio.IAM.{AccessKey, AccessKeySecret, STSSession, STSSessionSecret}
  alias Maxio.IAM.SigningSecretKeyring
  alias Maxio.Repo

  @scopes [:access_keys, :sts_sessions]

  @type report :: map()

  @spec run(keyword()) :: {:ok, report()} | {:error, report()}
  def run(opts \\ []) do
    dry_run = Keyword.get(opts, :dry_run, true)

    with {:ok, scopes} <- scopes(opts),
         {:ok, {current_key_id, _key}} <- SigningSecretKeyring.current_key(),
         {:ok, limit} <- limit(opts),
         {:ok, plan, report} <- build_plan(scopes, current_key_id, limit, dry_run) do
      cond do
        report.totals.errors > 0 ->
          {:error, Map.put(report, :status, :blocked)}

        dry_run ->
          {:ok, Map.put(report, :status, :dry_run)}

        true ->
          commit_plan(plan, report)
      end
    else
      {:error, %{} = report} ->
        {:error, report}

      {:error, reason} ->
        error = %{scope: nil, access_key_id: nil, reason: reason}

        {:error,
         %{
           status: :blocked,
           dry_run: dry_run,
           current_key_id: nil,
           scopes: %{},
           totals: add_error(empty_stats(), error)
         }}
    end
  end

  defp scopes(opts) do
    scopes =
      opts
      |> Keyword.get(:scopes, @scopes)
      |> List.wrap()
      |> Enum.map(&normalize_scope/1)

    cond do
      Enum.any?(scopes, &match?({:error, _}, &1)) ->
        {:error, :invalid_secret_rewrite_scope}

      scopes == [] ->
        {:error, :invalid_secret_rewrite_scope}

      true ->
        {:ok, scopes |> Enum.map(fn {:ok, scope} -> scope end) |> Enum.uniq()}
    end
  end

  defp normalize_scope(:access_keys), do: {:ok, :access_keys}
  defp normalize_scope("access_keys"), do: {:ok, :access_keys}
  defp normalize_scope(:sts_sessions), do: {:ok, :sts_sessions}
  defp normalize_scope("sts_sessions"), do: {:ok, :sts_sessions}
  defp normalize_scope(_scope), do: {:error, :invalid_secret_rewrite_scope}

  defp limit(opts) do
    case Keyword.get(opts, :limit) do
      nil -> {:ok, nil}
      limit when is_integer(limit) and limit > 0 -> {:ok, limit}
      _other -> {:error, :invalid_secret_rewrite_limit}
    end
  end

  defp build_plan(scopes, current_key_id, limit, dry_run) do
    {plan, scope_reports} =
      Enum.reduce(scopes, {[], %{}}, fn scope, {plan_acc, report_acc} ->
        {scope_plan, scope_report} = plan_scope(scope, current_key_id, limit)

        {plan_acc ++ scope_plan, Map.put(report_acc, scope, scope_report)}
      end)

    report = %{
      status: if(dry_run, do: :dry_run, else: :planned),
      dry_run: dry_run,
      current_key_id: current_key_id,
      scopes: scope_reports,
      totals: total_stats(scope_reports)
    }

    {:ok, plan, report}
  end

  defp plan_scope(:access_keys, current_key_id, limit) do
    AccessKey
    |> order_by([a], asc: a.inserted_at, asc: a.access_key_id)
    |> maybe_limit(limit)
    |> Repo.all()
    |> Enum.reduce({[], empty_stats()}, fn row, {plan, stats} ->
      case plan_access_key(row, current_key_id) do
        {:skip, stats_key} ->
          {plan, bump(stats, :scanned) |> bump(stats_key)}

        {:rewrite, item} ->
          {plan ++ [item], bump_candidate(stats, item.kind)}

        {:error, error} ->
          {plan, stats |> bump(:scanned) |> add_error(error)}
      end
    end)
  end

  defp plan_scope(:sts_sessions, current_key_id, limit) do
    STSSession
    |> order_by([s], asc: s.inserted_at, asc: s.access_key_id)
    |> maybe_limit(limit)
    |> Repo.all()
    |> Enum.reduce({[], empty_stats()}, fn row, {plan, stats} ->
      case plan_sts_session(row, current_key_id) do
        {:skip, stats_key} ->
          {plan, bump(stats, :scanned) |> bump(stats_key)}

        {:rewrite, item} ->
          {plan ++ [item], bump_candidate(stats, item.kind)}

        {:error, error} ->
          {plan, stats |> bump(:scanned) |> add_error(error)}
      end
    end)
  end

  defp maybe_limit(query, nil), do: query
  defp maybe_limit(query, limit), do: from(q in query, limit: ^limit)

  defp plan_access_key(%AccessKey{} = row, current_key_id) do
    plan_secret(%{
      scope: :access_keys,
      id: row.id,
      access_key_id: row.access_key_id,
      secret_key: row.secret_key,
      current_key_id: current_key_id,
      unwrap: &AccessKeySecret.unwrap/2,
      wrap: &AccessKeySecret.wrap/2,
      metadata: &AccessKeySecret.envelope_metadata/1
    })
  end

  defp plan_sts_session(%STSSession{} = row, current_key_id) do
    plan_secret(%{
      scope: :sts_sessions,
      id: row.id,
      access_key_id: row.access_key_id,
      secret_key: row.secret_key,
      current_key_id: current_key_id,
      unwrap: &STSSessionSecret.unwrap/2,
      wrap: &STSSessionSecret.wrap/2,
      metadata: &STSSessionSecret.envelope_metadata/1
    })
  end

  defp plan_secret(%{secret_key: stored_secret} = ctx) do
    with {:ok, plaintext} <- ctx.unwrap.(stored_secret, ctx.access_key_id),
         {:ok, kind, old_key_id} <- rewrite_kind(ctx.metadata.(stored_secret), ctx.current_key_id) do
      case kind do
        :current_key ->
          {:skip, :current_key}

        _rewrite ->
          case ctx.wrap.(plaintext, ctx.access_key_id) do
            {:ok, new_secret} ->
              {:rewrite,
               %{
                 scope: ctx.scope,
                 id: ctx.id,
                 access_key_id: ctx.access_key_id,
                 old_secret_key: stored_secret,
                 new_secret_key: new_secret,
                 kind: kind,
                 old_key_id: old_key_id
               }}

            {:error, reason} ->
              {:error, error(ctx, reason)}
          end
      end
    else
      {:error, reason} -> {:error, error(ctx, reason)}
    end
  end

  defp rewrite_kind({:ok, %{key_id: current_key_id}}, current_key_id),
    do: {:ok, :current_key, current_key_id}

  defp rewrite_kind({:ok, %{key_id: old_key_id}}, _current_key_id),
    do: {:ok, :stale_key, old_key_id}

  defp rewrite_kind(:plaintext, _current_key_id), do: {:ok, :legacy_plaintext, nil}
  defp rewrite_kind({:error, reason}, _current_key_id), do: {:error, reason}

  defp commit_plan(plan, report) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Repo.transaction(fn ->
      Enum.each(plan, fn item ->
        case rewrite_row(item, now) do
          1 -> :ok
          0 -> Repo.rollback({:conflict, item})
        end
      end)
    end)
    |> case do
      {:ok, _result} ->
        Enum.each(plan, &Notify.broadcast({:iam_changed, &1.access_key_id}))

        {:ok,
         report
         |> Map.put(:status, :rewrapped)
         |> put_rewrapped_counts(plan)}

      {:error, {:conflict, item}} ->
        error_report =
          report
          |> Map.put(:status, :blocked)
          |> add_top_level_error(error(item, :secret_rewrite_conflict))

        {:error, error_report}
    end
  end

  defp rewrite_row(%{scope: :access_keys} = item, now) do
    case locked_access_key(item.id) do
      %AccessKey{secret_key: old_secret_key} = row when old_secret_key == item.old_secret_key ->
        row
        |> Ecto.Changeset.change(secret_key: item.new_secret_key, updated_at: now)
        |> Repo.update()
        |> rewrite_count()

      _other ->
        0
    end
  end

  defp rewrite_row(%{scope: :sts_sessions} = item, now) do
    case locked_sts_session(item.id) do
      %STSSession{secret_key: old_secret_key} = row when old_secret_key == item.old_secret_key ->
        row
        |> Ecto.Changeset.change(secret_key: item.new_secret_key, updated_at: now)
        |> Repo.update()
        |> rewrite_count()

      _other ->
        0
    end
  end

  defp locked_access_key(id) do
    Repo.one(from(a in AccessKey, where: a.id == ^id, lock: "FOR UPDATE"))
  end

  defp locked_sts_session(id) do
    Repo.one(from(s in STSSession, where: s.id == ^id, lock: "FOR UPDATE"))
  end

  defp rewrite_count({:ok, _row}), do: 1
  defp rewrite_count({:error, _changeset}), do: 0

  defp put_rewrapped_counts(report, plan) do
    rewrites_by_scope = Enum.frequencies_by(plan, & &1.scope)

    scopes =
      Map.new(report.scopes, fn {scope, stats} ->
        {scope, %{stats | rewrapped: Map.get(rewrites_by_scope, scope, 0)}}
      end)

    %{report | scopes: scopes, totals: total_stats(scopes)}
  end

  defp bump_candidate(stats, kind) do
    stats
    |> bump(:scanned)
    |> bump(:candidates)
    |> bump(kind)
  end

  defp bump(stats, key), do: Map.update!(stats, key, &(&1 + 1))

  defp add_error(stats, error) do
    stats
    |> bump(:errors)
    |> Map.update!(:error_details, &(&1 ++ [error]))
  end

  defp add_top_level_error(report, error) do
    scope = error.scope

    scopes =
      Map.update(report.scopes, scope, add_error(empty_stats(), error), fn stats ->
        add_error(stats, error)
      end)

    %{report | scopes: scopes, totals: total_stats(scopes)}
  end

  defp error(ctx, reason) do
    %{
      scope: ctx.scope,
      access_key_id: ctx.access_key_id,
      reason: reason
    }
  end

  defp empty_stats do
    %{
      scanned: 0,
      current_key: 0,
      candidates: 0,
      legacy_plaintext: 0,
      stale_key: 0,
      rewrapped: 0,
      errors: 0,
      error_details: []
    }
  end

  defp total_stats(scope_reports) do
    Enum.reduce(scope_reports, empty_stats(), fn {_scope, stats}, acc ->
      %{
        scanned: acc.scanned + stats.scanned,
        current_key: acc.current_key + stats.current_key,
        candidates: acc.candidates + stats.candidates,
        legacy_plaintext: acc.legacy_plaintext + stats.legacy_plaintext,
        stale_key: acc.stale_key + stats.stale_key,
        rewrapped: acc.rewrapped + stats.rewrapped,
        errors: acc.errors + stats.errors,
        error_details: acc.error_details ++ stats.error_details
      }
    end)
  end
end
