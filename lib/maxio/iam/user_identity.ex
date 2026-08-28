defmodule Maxio.IAM.UserIdentity do
  @moduledoc """
  Transaction boundary for local IAM-user identity generations.

  A case-folded advisory lock serializes both existing and absent names. An
  existing operation also pins the immutable `iam_users.id`, so a request that
  waited behind delete plus same-name recreate cannot mutate the replacement.
  STS persistence uses the same boundary and revalidates every session in the
  issuer lineage immediately before insert.

  Callers own the surrounding `Repo.transaction/1`.
  """

  import Ecto.Query

  alias Maxio.IAM.{AccessKey, STSSession, User}

  @lock_namespace "maxio.iam.user_identity"
  @lock_wait_event [:maxio, :iam, :user_identity, :lock_wait]
  @user_arn_prefix "arn:aws:iam:::user/"

  @type snapshot :: {:existing, Ecto.UUID.t()} | :missing

  @spec snapshot(module(), binary()) :: snapshot()
  def snapshot(repo, name_or_arn) when is_binary(name_or_arn) do
    name = identity_name(name_or_arn)

    case fetch_by_name(repo, name) do
      %User{id: id} -> {:existing, id}
      nil -> :missing
    end
  end

  @spec lock_snapshot(module(), binary(), snapshot()) ::
          {:ok, User.t() | :missing} | {:error, :user_not_found | :identity_changed}
  def lock_snapshot(repo, name_or_arn, snapshot) do
    name = identity_name(name_or_arn)
    lock_names!(repo, [name])
    validate_snapshot(repo, name, snapshot)
  end

  @doc false
  @spec lock_snapshots(module(), [{binary(), snapshot()}]) ::
          {:ok, [User.t() | :missing]} | {:error, :user_not_found | :identity_changed}
  def lock_snapshots(repo, named_snapshots) when is_list(named_snapshots) do
    normalized = Enum.map(named_snapshots, fn {name, state} -> {identity_name(name), state} end)
    lock_names!(repo, Enum.map(normalized, &elem(&1, 0)))

    Enum.reduce_while(normalized, {:ok, []}, fn {name, state}, {:ok, rows} ->
      case validate_snapshot(repo, name, state) do
        {:ok, row} -> {:cont, {:ok, [row | rows]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, rows} -> {:ok, Enum.reverse(rows)}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec local_user_name(binary()) :: {:ok, binary()} | :not_local_user
  def local_user_name(@user_arn_prefix <> name) when name != "", do: {:ok, name}
  def local_user_name(_principal_arn), do: :not_local_user

  @spec lock_and_validate_issuer(module(), binary(), DateTime.t()) ::
          {:ok, :root | :legacy_user | :web_identity | User.t()}
          | {:error, :issuer_access_key_not_found}
  def lock_and_validate_issuer(repo, issuer_access_key_id, %DateTime{} = now)
      when is_binary(issuer_access_key_id) do
    with {:ok, terminal, lineage} <- trace_issuer(repo, issuer_access_key_id, now),
         {:ok, owner} <- lock_terminal(repo, terminal),
         :ok <- lock_and_validate_lineage(repo, lineage, now),
         :ok <- validate_terminal_access_key(repo, terminal) do
      {:ok, owner}
    else
      _other -> {:error, :issuer_access_key_not_found}
    end
  end

  @spec descendant_credential_ids(module(), User.t()) :: %{
          long_term: [binary()],
          sessions: [binary()]
        }
  def descendant_credential_ids(repo, %User{} = user) do
    long_term =
      repo.all(
        from(a in AccessKey,
          where: a.principal_arn == ^user.user_arn,
          select: a.access_key_id,
          order_by: [asc: a.access_key_id]
        )
      )

    sessions =
      repo.all(
        from(s in STSSession,
          select: {s.access_key_id, s.issuer_access_key_id, s.principal_arn},
          order_by: [asc: s.access_key_id]
        )
      )

    descendants =
      expand_descendants(sessions, MapSet.new(long_term), MapSet.new(), user.user_arn)

    %{long_term: long_term, sessions: descendants |> MapSet.to_list() |> Enum.sort()}
  end

  defp expand_descendants(sessions, frontier, found, user_arn) do
    newly_found =
      sessions
      |> Enum.filter(fn {access_key_id, issuer_access_key_id, principal_arn} ->
        not MapSet.member?(found, access_key_id) and
          (principal_arn == user_arn or MapSet.member?(frontier, issuer_access_key_id))
      end)
      |> Enum.map(&elem(&1, 0))
      |> MapSet.new()

    if MapSet.size(newly_found) == 0 do
      found
    else
      expand_descendants(
        sessions,
        MapSet.union(frontier, newly_found),
        MapSet.union(found, newly_found),
        user_arn
      )
    end
  end

  defp trace_issuer(repo, access_key_id, now) do
    trace_issuer(repo, access_key_id, now, MapSet.new())
  end

  defp trace_issuer(repo, access_key_id, now, seen) do
    if MapSet.member?(seen, access_key_id) do
      {:error, :cycle}
    else
      seen = MapSet.put(seen, access_key_id)

      case repo.get_by(AccessKey, access_key_id: access_key_id, status: "active") do
        %AccessKey{type: "root", principal_arn: "arn:aws:iam:::root"} = access_key ->
          {:ok, {:root, access_key_snapshot(access_key)}, []}

        %AccessKey{type: "iam_user", principal_arn: principal_arn} = access_key ->
          with {:ok, name} <- local_user_name(principal_arn) do
            case fetch_by_name(repo, name) do
              %User{status: "active"} = user ->
                {:ok, {:user, name, user.id, access_key_snapshot(access_key)}, []}

              nil ->
                if principal_arn == @user_arn_prefix <> access_key.access_key_id do
                  {:ok, {:legacy_user, name, access_key_snapshot(access_key)}, []}
                else
                  {:error, :invalid_user}
                end

              _other ->
                {:error, :invalid_user}
            end
          else
            _other -> {:error, :invalid_user}
          end

        nil ->
          trace_session_issuer(repo, access_key_id, now, seen)

        %AccessKey{} ->
          {:error, :invalid_access_key}
      end
    end
  end

  defp trace_session_issuer(repo, access_key_id, now, seen) do
    case repo.get_by(STSSession, access_key_id: access_key_id) do
      %STSSession{} = session ->
        with :ok <- usable_session?(session, now) do
          snapshot = session_snapshot(session)

          cond do
            web_identity_terminal?(session) ->
              {:ok, :web_identity, [snapshot]}

            is_binary(session.issuer_access_key_id) and session.issuer_access_key_id != "" ->
              with {:ok, terminal, ancestors} <-
                     trace_issuer(repo, session.issuer_access_key_id, now, seen) do
                {:ok, terminal, ancestors ++ [snapshot]}
              end

            true ->
              {:error, :invalid_session}
          end
        end

      nil ->
        {:error, :not_found}
    end
  end

  defp lock_terminal(repo, {:user, name, user_id, _access_key}) do
    case lock_snapshot(repo, name, {:existing, user_id}) do
      {:ok, %User{status: "active"} = user} -> {:ok, user}
      _other -> {:error, :invalid_user}
    end
  end

  defp lock_terminal(_repo, {:root, _access_key}), do: {:ok, :root}

  defp lock_terminal(repo, {:legacy_user, name, _access_key}) do
    case lock_snapshot(repo, name, :missing) do
      {:ok, :missing} -> {:ok, :legacy_user}
      _other -> {:error, :invalid_user}
    end
  end

  defp lock_terminal(_repo, :web_identity), do: {:ok, :web_identity}

  defp lock_and_validate_lineage(repo, lineage, now) do
    Enum.reduce_while(lineage, :ok, fn expected, :ok ->
      access_key_id = elem(expected, 0)

      case repo.one(
             from(s in STSSession,
               where: s.access_key_id == ^access_key_id,
               lock: "FOR UPDATE"
             )
           ) do
        %STSSession{} = session ->
          if session_snapshot(session) == expected and usable_session?(session, now) == :ok do
            {:cont, :ok}
          else
            {:halt, {:error, :lineage_changed}}
          end

        nil ->
          {:halt, {:error, :not_found}}
      end
    end)
  end

  defp validate_terminal_access_key(repo, {:user, _name, _user_id, expected}),
    do: validate_access_key(repo, expected)

  defp validate_terminal_access_key(repo, {:root, expected}),
    do: validate_access_key(repo, expected)

  defp validate_terminal_access_key(repo, {:legacy_user, _name, expected}),
    do: validate_access_key(repo, expected)

  defp validate_terminal_access_key(_repo, :web_identity), do: :ok

  defp validate_access_key(repo, expected) do
    access_key_id = elem(expected, 0)

    case repo.get_by(AccessKey, access_key_id: access_key_id, status: "active") do
      %AccessKey{} = access_key ->
        if access_key_snapshot(access_key) == expected,
          do: :ok,
          else: {:error, :access_key_changed}

      _other ->
        {:error, :access_key_changed}
    end
  end

  defp validate_snapshot(repo, name, {:existing, id}) do
    case fetch_by_name(repo, name, "FOR UPDATE") do
      %User{id: ^id} = user -> {:ok, user}
      %User{} -> {:error, :identity_changed}
      nil -> {:error, :user_not_found}
    end
  end

  defp validate_snapshot(repo, name, :missing) do
    case fetch_by_name(repo, name, "FOR UPDATE") do
      nil -> {:ok, :missing}
      %User{} -> {:error, :identity_changed}
    end
  end

  defp fetch_by_name(repo, name, nil) do
    repo.one(user_name_query(name))
  end

  defp fetch_by_name(repo, name, "FOR UPDATE") do
    repo.one(from(u in user_name_query(name), lock: "FOR UPDATE"))
  end

  defp fetch_by_name(repo, name), do: fetch_by_name(repo, name, nil)

  defp user_name_query(name) do
    from(u in User,
      where: fragment("lower(?)", u.user_name) == ^String.downcase(name),
      order_by: [asc: u.inserted_at],
      limit: 1
    )
  end

  defp lock_names!(repo, names) do
    names
    |> Enum.map(&(&1 |> String.downcase()))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.each(fn name ->
      :telemetry.execute(
        @lock_wait_event,
        %{system_time: System.system_time()},
        %{case_folded_user_name: name}
      )

      Ecto.Adapters.SQL.query!(
        repo,
        "SELECT pg_advisory_xact_lock(hashtext($1), hashtext($2))",
        [@lock_namespace, name]
      )
    end)
  end

  defp identity_name(@user_arn_prefix <> name), do: name
  defp identity_name(name), do: name

  defp access_key_snapshot(%AccessKey{} = access_key) do
    {
      access_key.access_key_id,
      access_key.principal_arn,
      access_key.type,
      access_key.status
    }
  end

  defp session_snapshot(%STSSession{} = session) do
    {
      session.access_key_id,
      session.issuer_access_key_id,
      session.principal_arn,
      session.principal_type,
      session.status,
      session.expires_at,
      session.web_identity_provider_arn,
      session.web_identity_subject_sha256,
      session.web_identity_audience
    }
  end

  defp usable_session?(%STSSession{status: "active", expires_at: expires_at}, now) do
    if DateTime.compare(expires_at, now) == :gt, do: :ok, else: {:error, :expired}
  end

  defp usable_session?(_session, _now), do: {:error, :inactive}

  defp web_identity_terminal?(%STSSession{
         issuer_access_key_id: nil,
         web_identity_provider_arn: provider_arn,
         web_identity_subject_sha256: subject_hash
       }) do
    is_binary(provider_arn) and provider_arn != "" and is_binary(subject_hash) and
      subject_hash != ""
  end

  defp web_identity_terminal?(_session), do: false
end
