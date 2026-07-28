defmodule Maxio.Auth.CredentialStore.EctoStore do
  @moduledoc """
  Postgres credential backend.

  Long-term access keys live in `access_keys`; temporary STS session credentials
  live in `sts_sessions` and require a matching session token.
  """
  @behaviour Maxio.Auth.CredentialStore

  import Ecto.Query

  alias Maxio.Auth.SessionToken
  alias Maxio.IAM
  alias Maxio.IAM.{AccessKey, AccessKeySecret, STSSession, STSSessionSecret}
  alias Maxio.Policy.Statement
  alias Maxio.Repo

  @impl true
  def get_secret(access_key), do: get_secret(access_key, [])

  @impl true
  def get_secret(access_key, opts) do
    case Repo.get_by(AccessKey, access_key_id: access_key, status: "active") do
      nil ->
        get_session_secret(access_key, opts)

      %AccessKey{} = row ->
        cond do
          session_token?(Keyword.get(opts, :session_token)) ->
            {:error, :invalid_token}

          not access_key_principal_usable?(row) ->
            :error

          true ->
            case AccessKeySecret.unwrap(row.secret_key, row.access_key_id) do
              {:ok, secret_key} ->
                {:ok, %{secret_key: secret_key, principal: access_key_principal(row)}}

              {:error, _reason} ->
                :error
            end
        end
    end
  end

  @impl true
  def put_access_key(%{access_key: ak, secret_key: sk} = attrs) do
    principal = Map.get(attrs, :principal, %{})
    type = principal |> Map.get(:type, Map.get(attrs, :type, "iam_user")) |> to_string()

    arn =
      Map.get(principal, :arn) ||
        Map.get(attrs, :arn) ||
        if type == "root", do: "arn:aws:iam:::root", else: "arn:aws:iam:::user/#{ak}"

    tags =
      attrs
      |> Map.get(:tags, Map.get(principal, :tags, %{}))
      |> normalize_tags()

    with {:ok, stored_secret} <- AccessKeySecret.wrap(sk, ak) do
      %AccessKey{}
      |> AccessKey.changeset(%{
        access_key_id: ak,
        secret_key: stored_secret,
        principal_arn: arn,
        type: type,
        status: "active",
        tags: tags
      })
      |> Repo.insert(
        on_conflict:
          {:replace, [:secret_key, :principal_arn, :type, :status, :tags, :updated_at]},
        conflict_target: :access_key_id
      )
      |> case do
        {:ok, _} -> :ok
        {:error, cs} -> {:error, cs}
      end
    end
  end

  def put_access_key(_), do: {:error, :invalid_attrs}

  @impl true
  def list_keys do
    Repo.all(from(a in AccessKey))
    |> Enum.map(fn a ->
      %{
        access_key: a.access_key_id,
        principal: access_key_principal(a)
      }
    end)
  end

  @impl true
  def invalidate(_scope), do: :ok

  defp get_session_secret(access_key, opts) do
    now = Keyword.get(opts, :now) || DateTime.utc_now()

    case Repo.get_by(STSSession, access_key_id: access_key) do
      nil ->
        :error

      %STSSession{status: status} when status != "active" ->
        {:error, :invalid_token}

      %STSSession{} = row ->
        cond do
          expired?(row.expires_at, now) ->
            {:error, :expired_token}

          not session_token?(Keyword.get(opts, :session_token)) ->
            {:error, :missing_session_token}

          not SessionToken.verify(Keyword.get(opts, :session_token), row.session_token_sha256) ->
            {:error, :invalid_token}

          not session_principal_usable?(row, now) ->
            {:error, :invalid_token}

          true ->
            case STSSessionSecret.unwrap(row.secret_key, row.access_key_id) do
              {:ok, secret_key} ->
                {:ok, %{secret_key: secret_key, principal: session_principal(row)}}

              {:error, _reason} ->
                {:error, :invalid_token}
            end
        end
    end
  end

  defp access_key_principal(%AccessKey{} = row) do
    %{
      type: principal_type(row.type),
      access_key: row.access_key_id,
      arn: row.principal_arn,
      tags: row.tags || %{}
    }
  end

  defp access_key_principal_usable?(%AccessKey{
         type: "root",
         principal_arn: "arn:aws:iam:::root"
       }),
       do: true

  defp access_key_principal_usable?(%AccessKey{
         type: "iam_user",
         principal_arn: principal_arn,
         access_key_id: access_key_id
       }) do
    IAM.iam_user_principal_usable?(principal_arn, access_key_id)
  end

  defp access_key_principal_usable?(%AccessKey{}), do: false

  defp session_principal_usable?(%STSSession{} = row, now) do
    session_own_principal_usable?(row) and
      session_issuer_usable?(row, now, MapSet.new([row.access_key_id]))
  end

  defp session_issuer_usable?(
         %STSSession{principal_type: "assumed_role", web_identity_provider_arn: provider_arn},
         _now,
         _seen
       )
       when is_binary(provider_arn) and provider_arn != "",
       do: true

  defp session_issuer_usable?(%STSSession{issuer_access_key_id: issuer_access_key_id}, now, seen) do
    session_issuer_access_key_usable?(issuer_access_key_id, now, seen)
  end

  defp session_own_principal_usable?(%STSSession{
         principal_type: "root",
         principal_arn: "arn:aws:iam:::root"
       }),
       do: true

  defp session_own_principal_usable?(%STSSession{
         principal_type: "iam_user",
         principal_arn: principal_arn,
         issuer_access_key_id: issuer_access_key_id
       }) do
    IAM.iam_user_principal_usable?(principal_arn, issuer_access_key_id)
  end

  defp session_own_principal_usable?(%STSSession{principal_type: "assumed_role"}), do: true
  defp session_own_principal_usable?(%STSSession{}), do: false

  defp session_issuer_access_key_usable?(issuer_access_key_id, now, seen) do
    cond do
      not is_binary(issuer_access_key_id) or issuer_access_key_id == "" ->
        false

      MapSet.member?(seen, issuer_access_key_id) ->
        false

      true ->
        case Repo.get_by(AccessKey, access_key_id: issuer_access_key_id, status: "active") do
          %AccessKey{} = access_key ->
            access_key_principal_usable?(access_key)

          nil ->
            session_issuer_session_usable?(issuer_access_key_id, now, seen)
        end
    end
  end

  defp session_issuer_session_usable?(issuer_access_key_id, now, seen) do
    case Repo.get_by(STSSession, access_key_id: issuer_access_key_id) do
      %STSSession{status: "active"} = session ->
        session_own_principal_usable?(session) and
          session_issuer_usable?(session, now, MapSet.put(seen, issuer_access_key_id))

      _other ->
        false
    end
  end

  defp session_principal(%STSSession{principal_type: "assumed_role"} = row) do
    %{
      type: :assumed_role,
      access_key: row.access_key_id,
      arn: row.principal_arn,
      tags: row.tags || %{},
      transitive_tag_keys: row.transitive_tag_keys || [],
      session_policy: row.session_policy,
      session_policy_statements: session_policy_statements(row.session_policy),
      source_identity: row.source_identity,
      mfa_authenticated: row.mfa_authenticated,
      mfa_serial_hash: row.mfa_serial_hash,
      credential_type: :session,
      session_name: row.session_name,
      session_access_key: row.access_key_id,
      session_expires_at: row.expires_at,
      issuer_access_key: row.issuer_access_key_id
    }
  end

  defp session_principal(%STSSession{} = row) do
    %{
      type: principal_type(row.principal_type),
      access_key: row.issuer_access_key_id,
      arn: row.principal_arn,
      tags: row.tags || %{},
      transitive_tag_keys: row.transitive_tag_keys || [],
      session_policy: row.session_policy,
      session_policy_statements: session_policy_statements(row.session_policy),
      source_identity: row.source_identity,
      mfa_authenticated: row.mfa_authenticated,
      mfa_serial_hash: row.mfa_serial_hash,
      credential_type: :session,
      session_name: row.session_name,
      session_access_key: row.access_key_id,
      session_expires_at: row.expires_at,
      issuer_access_key: row.issuer_access_key_id
    }
  end

  defp expired?(expires_at, now), do: DateTime.compare(expires_at, now) != :gt

  defp session_token?(nil), do: false
  defp session_token?(""), do: false
  defp session_token?(_token), do: true

  defp principal_type("root"), do: :root
  defp principal_type("iam_user"), do: :iam_user
  defp principal_type("assumed_role"), do: :assumed_role
  defp principal_type(_other), do: :unknown

  defp session_policy_statements(nil), do: []

  defp session_policy_statements(%{} = document) do
    document
    |> Jason.encode!()
    |> Statement.parse_identity_policy()
    |> case do
      {:ok, statements} -> statements
      {:error, _reason} -> :invalid
    end
  end

  defp session_policy_statements(_document), do: :invalid

  defp normalize_tags(tags) when is_map(tags) do
    Map.new(tags, fn {key, value} -> {to_string(key), tag_value(value)} end)
  end

  defp normalize_tags(_tags), do: %{}

  defp tag_value(nil), do: ""
  defp tag_value(value), do: to_string(value)
end
