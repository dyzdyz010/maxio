defmodule Maxio.STS do
  @moduledoc """
  Local STS session credential lifecycle.

  This module owns local session issuance, role-session issuance, listing and
  revocation. HTTP STS Query API routing and XML rendering live in
  `Maxio.STS.QueryPlug` / `Maxio.STS.View`; role trust policies are evaluated
  here against the normalized principal and request context supplied by that
  boundary.
  """
  import Ecto.Query

  alias Maxio.Auth.SessionToken
  alias Maxio.Cluster.Notify
  alias Maxio.IAM.{AccessKey, STSSession}
  alias Maxio.Policy.{Evaluator, RequestContext, Statement, Store}
  alias Maxio.Repo
  alias Maxio.Tags

  @default_duration_seconds 3_600
  @min_duration_seconds 900
  @iam_user_max_duration_seconds 129_600
  @root_max_duration_seconds 3_600
  @role_chaining_max_duration_seconds 3_600
  @max_session_policy_plaintext_bytes 2_048
  @max_managed_session_policies 10

  @doc """
  Issues a temporary session credential from an active long-term access key.

  Options:

    * `:issuer_access_key_id` or `:access_key_id` - required parent key.
    * `:duration_seconds` - defaults to 3600. Root is capped at 3600 seconds;
      IAM users may request 900..129600 seconds.
    * `:session_name` - optional audit label.
    * `:mfa_authenticated`, `:mfa_serial_hash`, `:pre_issue` - optional MFA
      audit fields and pre-issue verifier.
    * `:session_access_key_id`, `:secret_key`, `:session_token` - test hooks.
  """
  @spec issue_session(keyword()) :: {:ok, map()} | {:error, term()}
  def issue_session(opts \\ []) do
    with {:ok, issuer_access_key_id} <- issuer_access_key_id(opts),
         {:ok, issuer} <- fetch_active_issuer(issuer_access_key_id),
         {:ok, duration_seconds} <- duration_seconds(opts, issuer.type),
         :ok <- pre_issue(opts),
         {:ok, access_key_id} <- session_access_key_id(opts) do
      now = utc_now()
      expires_at = DateTime.add(now, duration_seconds, :second)
      secret_key = Keyword.get(opts, :secret_key) || gen_secret_key()
      session_token = Keyword.get(opts, :session_token) || gen_session_token()
      session_name = Keyword.get(opts, :session_name) || default_session_name()
      tags = issuer.tags || %{}

      attrs = %{
        access_key_id: access_key_id,
        secret_key: secret_key,
        session_token_sha256: SessionToken.hash(session_token),
        issuer_access_key_id: issuer.access_key_id,
        principal_arn: issuer.principal_arn,
        principal_type: issuer.type,
        session_name: session_name,
        status: "active",
        issued_at: now,
        expires_at: expires_at,
        tags: tags,
        mfa_authenticated: Keyword.get(opts, :mfa_authenticated, false),
        mfa_serial_hash: Keyword.get(opts, :mfa_serial_hash)
      }

      case %STSSession{} |> STSSession.changeset(attrs) |> Repo.insert() do
        {:ok, session} ->
          Notify.broadcast({:iam_changed, session.access_key_id})

          {:ok,
           session
           |> public_session()
           |> Map.merge(%{secret_key: secret_key, session_token: session_token})}

        {:error, changeset} ->
          {:error, sanitize_changeset_errors(changeset)}
      end
    end
  end

  @doc """
  Issues temporary credentials for an IAM role after evaluating its trust policy.

  The persisted session principal is the role ARN, so S3 authorization consumes
  role identity policies through the existing principal-policy store. The AWS
  Query response still returns the derived assumed-role session ARN.
  """
  @spec assume_role(map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def assume_role(caller_principal, role, opts \\ [])

  def assume_role(caller_principal, role, opts) when is_map(caller_principal) and is_map(role) do
    with {:ok, issuer_access_key_id} <- caller_access_key_id(caller_principal),
         {:ok, role_arn} <- role_field(role, :role_arn),
         {:ok, session_name} <- session_name(opts),
         {:ok, source_identity} <- effective_source_identity(caller_principal, opts),
         opts = Keyword.put(opts, :source_identity, source_identity),
         {:ok, session_tags} <- session_tags(opts),
         {:ok, requested_transitive_tag_keys} <- transitive_tag_keys(opts, session_tags),
         {:ok, tag_state} <-
           assume_role_tag_state(caller_principal, session_tags, requested_transitive_tag_keys),
         {:ok, session_policy} <- session_policy(opts),
         opts =
           opts
           |> Keyword.put(:session_tags, session_tags)
           |> Keyword.put(:transitive_tag_keys, tag_state.transitive_tag_keys)
           |> Keyword.put(:session_policy, session_policy)
           |> Keyword.put(:tag_session_required?, tag_state.tag_session_required?),
         {:ok, mfa_context} <- assume_role_mfa_context(caller_principal, opts),
         opts =
           opts
           |> Keyword.put(:mfa_authenticated, mfa_context.present?)
           |> Keyword.put(:mfa_serial_hash, Map.get(mfa_context, :serial_hash)),
         {:ok, duration_seconds} <-
           assume_role_duration_seconds(opts, role_max_session_duration(role), caller_principal),
         :ok <- trust_policy_allows?(caller_principal, role, session_name, opts),
         :ok <-
           caller_set_source_identity_allows?(
             caller_principal,
             role,
             role_arn,
             session_name,
             opts
           ),
         :ok <- pre_issue(opts),
         :ok <- consume_assume_role_mfa(mfa_context),
         {:ok, access_key_id} <- session_access_key_id(opts) do
      now = utc_now()
      expires_at = DateTime.add(now, duration_seconds, :second)
      secret_key = Keyword.get(opts, :secret_key) || gen_secret_key()
      session_token = Keyword.get(opts, :session_token) || gen_session_token()

      attrs = %{
        access_key_id: access_key_id,
        secret_key: secret_key,
        session_token_sha256: SessionToken.hash(session_token),
        issuer_access_key_id: issuer_access_key_id,
        principal_arn: role_arn,
        principal_type: "assumed_role",
        session_name: session_name,
        status: "active",
        issued_at: now,
        expires_at: expires_at,
        tags: merged_session_tags(role, tag_state.session_tags),
        transitive_tag_keys: tag_state.transitive_tag_keys,
        session_policy: session_policy,
        source_identity: source_identity,
        mfa_authenticated: mfa_context.present?,
        mfa_serial_hash: Map.get(mfa_context, :serial_hash)
      }

      case %STSSession{} |> STSSession.changeset(attrs) |> Repo.insert() do
        {:ok, session} ->
          Notify.broadcast({:iam_changed, session.access_key_id})

          {:ok,
           session
           |> public_session()
           |> Map.merge(%{
             secret_key: secret_key,
             session_token: session_token,
             role_arn: role_arn,
             assumed_role_arn: assumed_role_arn(role_arn, session_name),
             assumed_role_id: assumed_role_id(role, session_name)
           })}

        {:error, changeset} ->
          {:error, sanitize_changeset_errors(changeset)}
      end
    end
  end

  def assume_role(_caller_principal, _role, _opts), do: {:error, :invalid_assume_role_request}

  @doc "Lists STS sessions without exposing secret keys or token hashes."
  @spec list_sessions(keyword()) :: [map()]
  def list_sessions(opts \\ []) do
    STSSession
    |> maybe_filter(:issuer_access_key_id, Keyword.get(opts, :issuer_access_key_id))
    |> maybe_filter(:principal_arn, Keyword.get(opts, :principal_arn))
    |> order_by([s], desc: s.issued_at, asc: s.access_key_id)
    |> Repo.all()
    |> Enum.map(&public_session/1)
  end

  @doc "Revokes a session credential. Missing rows are treated as already revoked."
  @spec revoke_session(String.t()) :: {:ok, map() | nil} | {:error, term()}
  def revoke_session(access_key_id) when is_binary(access_key_id) do
    case Repo.get_by(STSSession, access_key_id: access_key_id) do
      nil ->
        {:ok, nil}

      %STSSession{status: "revoked"} = session ->
        {:ok, public_session(session)}

      %STSSession{} = session ->
        now = utc_now()

        session
        |> Ecto.Changeset.change(status: "revoked", revoked_at: now)
        |> Repo.update()
        |> case do
          {:ok, updated} ->
            Notify.broadcast({:iam_changed, updated.access_key_id})
            {:ok, public_session(updated)}

          {:error, changeset} ->
            {:error, changeset}
        end
    end
  end

  def revoke_session(_access_key_id), do: {:error, :invalid_access_key_id}

  @spec public_session(STSSession.t()) :: map()
  def public_session(%STSSession{} = session) do
    %{
      id: session.id,
      access_key_id: session.access_key_id,
      issuer_access_key_id: session.issuer_access_key_id,
      principal_arn: session.principal_arn,
      principal_type: session.principal_type,
      session_name: session.session_name,
      status: session.status,
      issued_at: session.issued_at,
      expires_at: session.expires_at,
      revoked_at: session.revoked_at,
      tags: session.tags || %{},
      transitive_tag_keys: session.transitive_tag_keys || [],
      session_policy: session.session_policy,
      source_identity: session.source_identity,
      mfa_authenticated: session.mfa_authenticated,
      mfa_serial_hash: session.mfa_serial_hash,
      inserted_at: session.inserted_at,
      updated_at: session.updated_at
    }
  end

  defp issuer_access_key_id(opts) do
    case Keyword.get(opts, :issuer_access_key_id, Keyword.get(opts, :access_key_id)) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, :missing_issuer_access_key_id}
    end
  end

  defp fetch_active_issuer(access_key_id) do
    case Repo.get_by(AccessKey, access_key_id: access_key_id, status: "active") do
      nil -> {:error, :issuer_access_key_not_found}
      %AccessKey{} = access_key -> {:ok, access_key}
    end
  end

  defp duration_seconds(opts, principal_type) do
    duration = Keyword.get(opts, :duration_seconds, @default_duration_seconds)

    max_duration =
      if principal_type == "root",
        do: @root_max_duration_seconds,
        else: @iam_user_max_duration_seconds

    if is_integer(duration) and duration >= @min_duration_seconds and duration <= max_duration do
      {:ok, duration}
    else
      {:error, :invalid_session_duration}
    end
  end

  defp assume_role_duration_seconds(opts, role_max_duration, caller_principal) do
    duration = Keyword.get(opts, :duration_seconds) || @default_duration_seconds
    max_duration = assume_role_max_duration(role_max_duration, caller_principal)

    if is_integer(duration) and duration >= @min_duration_seconds and duration <= max_duration do
      {:ok, duration}
    else
      {:error, :invalid_session_duration}
    end
  end

  defp assume_role_max_duration(role_max_duration, %{
         type: :assumed_role,
         credential_type: :session
       }),
       do: min(role_max_duration, @role_chaining_max_duration_seconds)

  defp assume_role_max_duration(role_max_duration, _caller_principal), do: role_max_duration

  defp role_max_session_duration(%{max_session_duration_seconds: max}) when is_integer(max),
    do: max

  defp role_max_session_duration(%{"max_session_duration_seconds" => max}) when is_integer(max),
    do: max

  defp role_max_session_duration(_role), do: @default_duration_seconds

  defp trust_policy_allows?(caller_principal, role, session_name, opts) do
    with {:ok, role_arn} <- role_field(role, :role_arn),
         {:ok, trust_policy} <- role_field(role, :trust_policy),
         {:ok, trust_json} <- Jason.encode(trust_policy),
         {:ok, statements} <- Statement.parse_trust_policy(trust_json, role_arn) do
      source_identity = Keyword.get(opts, :source_identity)

      ctx = %RequestContext{
        principal: caller_principal,
        authenticated?: true,
        owner?: false,
        action: "sts:AssumeRole",
        resource: role_arn,
        conditions:
          assume_role_request_conditions(
            opts,
            session_name,
            source_identity,
            role,
            caller_principal
          )
      }

      with :ok <- trust_policy_no_explicit_deny?(ctx, statements),
           :ok <-
             caller_assume_role_no_explicit_deny?(
               caller_principal,
               role,
               role_arn,
               session_name,
               opts
             ),
           :ok <-
             caller_tag_session_allows?(
               caller_principal,
               role,
               role_arn,
               session_name,
               opts
             ) do
        case Evaluator.evaluate(ctx, statements) do
          :allow ->
            with :ok <- set_source_identity_allows?(ctx, statements, source_identity) do
              tag_session_allows?(
                ctx,
                statements,
                Keyword.get(opts, :tag_session_required?, false)
              )
            end

          {:deny, :implicit_deny} ->
            account_principal_trust_allows?(
              ctx,
              statements,
              caller_principal,
              role,
              session_name,
              opts
            )

          {:deny, reason} ->
            {:error, {:assume_role_denied, reason}}
        end
      end
    else
      _other -> {:error, :malformed_trust_policy}
    end
  end

  defp trust_policy_no_explicit_deny?(%RequestContext{} = ctx, statements) do
    account_ctx = local_account_context(ctx)

    [ctx, account_ctx]
    |> Enum.reduce_while(:ok, fn deny_ctx, :ok ->
      case Evaluator.evaluate(deny_ctx, statements) do
        {:deny, :explicit_deny} -> {:halt, {:error, {:assume_role_denied, :explicit_deny}}}
        _result -> {:cont, :ok}
      end
    end)
  end

  defp account_principal_trust_allows?(
         %RequestContext{} = ctx,
         statements,
         caller_principal,
         role,
         session_name,
         opts
       ) do
    account_ctx = local_account_context(ctx)
    source_identity = Keyword.get(opts, :source_identity)

    with :allow <- Evaluator.evaluate(account_ctx, statements),
         :ok <-
           caller_assume_role_allows?(
             caller_principal,
             role,
             ctx.resource,
             session_name,
             opts
           ),
         :ok <- set_source_identity_allows?(account_ctx, statements, source_identity) do
      tag_session_allows?(
        account_ctx,
        statements,
        Keyword.get(opts, :tag_session_required?, false)
      )
    else
      {:deny, reason} -> {:error, {:assume_role_denied, reason}}
      {:error, _reason} = error -> error
    end
  end

  defp local_account_context(%RequestContext{} = ctx),
    do: %{ctx | principal: %{type: :root, arn: Maxio.IAM.root_principal_arn()}}

  defp caller_assume_role_no_explicit_deny?(
         %{type: :root},
         _role,
         _role_arn,
         _session_name,
         _opts
       ),
       do: :ok

  defp caller_assume_role_no_explicit_deny?(
         caller_principal,
         role,
         role_arn,
         session_name,
         opts
       ) do
    case evaluate_caller_identity_policy(caller_principal, role, role_arn, session_name, opts,
           action: "sts:AssumeRole"
         ) do
      {:deny, :explicit_deny} -> {:error, {:caller_assume_role_denied, :explicit_deny}}
      _result -> :ok
    end
  end

  defp caller_assume_role_allows?(%{type: :root}, _role, _role_arn, _session_name, _opts),
    do: :ok

  defp caller_assume_role_allows?(caller_principal, role, role_arn, session_name, opts) do
    case evaluate_caller_identity_policy(caller_principal, role, role_arn, session_name, opts,
           action: "sts:AssumeRole"
         ) do
      :allow -> :ok
      {:deny, reason} -> {:error, {:caller_assume_role_denied, reason}}
    end
  end

  defp caller_tag_session_allows?(caller_principal, role, role_arn, session_name, opts) do
    cond do
      not Keyword.get(opts, :tag_session_required?, false) ->
        :ok

      caller_principal[:type] == :root ->
        :ok

      true ->
        case evaluate_caller_identity_policy(caller_principal, role, role_arn, session_name, opts,
               action: "sts:TagSession"
             ) do
          :allow -> :ok
          {:deny, reason} -> {:error, {:caller_tag_session_denied, reason}}
        end
    end
  end

  defp evaluate_caller_identity_policy(
         caller_principal,
         role,
         role_arn,
         session_name,
         opts,
         action: action
       ) do
    ctx = %RequestContext{
      principal: caller_principal,
      authenticated?: true,
      owner?: false,
      action: action,
      resource: role_arn,
      conditions:
        assume_role_request_conditions(
          opts,
          session_name,
          Keyword.get(opts, :source_identity),
          role,
          caller_principal
        )
    }

    Evaluator.evaluate(ctx, Store.principal_policies(caller_principal))
  end

  defp caller_set_source_identity_allows?(caller_principal, role, role_arn, session_name, opts) do
    source_identity = Keyword.get(opts, :source_identity)

    cond do
      not source_identity_present?(source_identity) ->
        :ok

      caller_principal[:type] == :root ->
        :ok

      true ->
        ctx = %RequestContext{
          principal: caller_principal,
          authenticated?: true,
          owner?: false,
          action: "sts:SetSourceIdentity",
          resource: role_arn,
          conditions:
            assume_role_request_conditions(
              opts,
              session_name,
              source_identity,
              role,
              caller_principal
            )
        }

        case Evaluator.evaluate(ctx, Store.principal_policies(caller_principal)) do
          :allow -> :ok
          {:deny, reason} -> {:error, {:caller_set_source_identity_denied, reason}}
        end
    end
  end

  defp set_source_identity_allows?(%RequestContext{} = ctx, statements, source_identity) do
    if source_identity_present?(source_identity) do
      source_ctx = %{ctx | action: "sts:SetSourceIdentity"}

      case Evaluator.evaluate(source_ctx, statements) do
        :allow -> :ok
        {:deny, reason} -> {:error, {:set_source_identity_denied, reason}}
      end
    else
      :ok
    end
  end

  defp tag_session_allows?(%RequestContext{} = ctx, statements, required?) do
    if required? do
      tag_ctx = %{ctx | action: "sts:TagSession"}

      case Evaluator.evaluate(tag_ctx, statements) do
        :allow -> :ok
        {:deny, reason} -> {:error, {:tag_session_denied, reason}}
      end
    else
      :ok
    end
  end

  defp assume_role_request_conditions(opts, session_name, source_identity, role, caller_principal) do
    opts
    |> request_envelope_conditions()
    |> maybe_put_condition("sts:ExternalId", Keyword.get(opts, :external_id))
    |> maybe_put_condition("sts:SourceIdentity", source_identity)
    |> maybe_put_condition("aws:SourceIdentity", source_identity)
    |> put_session_tag_conditions(Keyword.get(opts, :session_tags, []))
    |> put_transitive_tag_key_conditions(Keyword.get(opts, :transitive_tag_keys, []))
    |> put_resource_tag_conditions(role)
    |> maybe_put_mfa_present(Keyword.get(opts, :mfa_authenticated, false))
    |> put_principal_context(caller_principal)
    |> put_principal_tag_conditions(caller_principal)
    |> Map.put("sts:RoleSessionName", session_name)
  end

  defp request_envelope_conditions(opts) do
    %{}
    |> maybe_put_condition("aws:SecureTransport", Keyword.get(opts, :secure_transport))
    |> maybe_put_condition("aws:SourceIp", Keyword.get(opts, :source_ip))
    |> Map.put("aws:CurrentTime", Keyword.get(opts, :current_time) || utc_now())
  end

  defp put_session_tag_conditions(conditions, []), do: conditions

  defp put_session_tag_conditions(conditions, session_tags) do
    tag_keys = Enum.map(session_tags, &elem(&1, 0))

    session_tags
    |> Enum.reduce(conditions, fn {key, value}, acc ->
      Map.put(acc, "aws:RequestTag/#{key}", value)
    end)
    |> Map.put("aws:TagKeys", tag_keys)
  end

  defp put_transitive_tag_key_conditions(conditions, []), do: conditions

  defp put_transitive_tag_key_conditions(conditions, transitive_tag_keys),
    do: Map.put(conditions, "sts:TransitiveTagKeys", transitive_tag_keys)

  defp put_resource_tag_conditions(conditions, role) do
    role
    |> role_tags()
    |> normalize_tag_map()
    |> Enum.reduce(conditions, fn {key, value}, acc ->
      Map.put(acc, "aws:ResourceTag/#{key}", value)
    end)
  end

  defp maybe_put_mfa_present(conditions, true),
    do: Map.put(conditions, "aws:MultiFactorAuthPresent", true)

  defp maybe_put_mfa_present(conditions, _value), do: conditions

  defp put_principal_context(conditions, %{type: :root, access_key: access_key}) do
    conditions
    |> Map.put("aws:PrincipalType", "Account")
    |> maybe_put_condition("aws:userid", access_key)
  end

  defp put_principal_context(conditions, %{type: :iam_user, access_key: access_key, arn: arn}) do
    conditions
    |> Map.put("aws:PrincipalType", "User")
    |> maybe_put_condition("aws:userid", access_key)
    |> maybe_put_condition("aws:username", username_from_arn(arn))
  end

  defp put_principal_context(conditions, %{type: type, access_key: access_key}) do
    conditions
    |> Map.put("aws:PrincipalType", type |> to_string() |> Macro.camelize())
    |> maybe_put_condition("aws:userid", access_key)
  end

  defp put_principal_context(conditions, _principal), do: conditions

  defp put_principal_tag_conditions(conditions, %{tags: tags}) when is_map(tags) do
    Enum.reduce(tags, conditions, fn {key, value}, acc ->
      Map.put(acc, "aws:PrincipalTag/#{key}", to_string(value))
    end)
  end

  defp put_principal_tag_conditions(conditions, _principal), do: conditions

  defp username_from_arn("arn:aws:iam:::user/" <> path) do
    path
    |> String.split("/", trim: true)
    |> List.last()
  end

  defp username_from_arn(_arn), do: nil

  defp source_identity_present?(value), do: is_binary(value) and value != ""

  defp effective_source_identity(caller_principal, opts) do
    requested_source_identity = Keyword.get(opts, :source_identity)
    inherited_source_identity = caller_principal[:source_identity]

    cond do
      source_identity_present?(inherited_source_identity) and is_nil(requested_source_identity) ->
        {:ok, inherited_source_identity}

      source_identity_present?(inherited_source_identity) and
          requested_source_identity == inherited_source_identity ->
        {:ok, inherited_source_identity}

      source_identity_present?(inherited_source_identity) ->
        {:error, :source_identity_cannot_be_changed}

      true ->
        {:ok, requested_source_identity}
    end
  end

  defp session_tags(opts) do
    raw = Keyword.get(opts, :session_tags, [])

    with {:ok, tags} <- normalize_session_tags(raw),
         :ok <- validate_session_tags(tags) do
      {:ok, tags}
    else
      _error -> {:error, :invalid_session_tags}
    end
  end

  defp normalize_session_tags(nil), do: {:ok, []}
  defp normalize_session_tags(%{} = tags), do: {:ok, Tags.map_to_list(tags)}

  defp normalize_session_tags(tags) when is_list(tags) do
    if Enum.all?(tags, &match?({key, value} when is_binary(key) and is_binary(value), &1)) do
      {:ok, tags}
    else
      {:error, :invalid_session_tags}
    end
  end

  defp normalize_session_tags(_tags), do: {:error, :invalid_session_tags}

  defp validate_session_tags(tags) do
    lower_keys = tags |> Enum.map(fn {key, _value} -> String.downcase(key) end)

    cond do
      Tags.validate(tags, :bucket) != :ok -> {:error, :invalid_session_tags}
      length(Enum.uniq(lower_keys)) != length(lower_keys) -> {:error, :invalid_session_tags}
      true -> :ok
    end
  end

  defp transitive_tag_keys(opts, session_tags) do
    raw = Keyword.get(opts, :transitive_tag_keys, [])

    with {:ok, keys} <- normalize_transitive_tag_keys(raw),
         :ok <- validate_transitive_tag_keys(keys),
         {:ok, canonical_keys} <- canonical_transitive_tag_keys(keys, session_tags) do
      {:ok, canonical_keys}
    else
      _error -> {:error, :invalid_transitive_tag_keys}
    end
  end

  defp normalize_transitive_tag_keys(nil), do: {:ok, []}

  defp normalize_transitive_tag_keys(keys) when is_list(keys) do
    if Enum.all?(keys, &is_binary/1) do
      {:ok, keys}
    else
      {:error, :invalid_transitive_tag_keys}
    end
  end

  defp normalize_transitive_tag_keys(_keys), do: {:error, :invalid_transitive_tag_keys}

  defp validate_transitive_tag_keys(keys) do
    lower_keys = Enum.map(keys, &String.downcase/1)

    cond do
      Tags.validate(Enum.map(keys, &{&1, ""}), :bucket) != :ok ->
        {:error, :invalid_transitive_tag_keys}

      length(Enum.uniq(lower_keys)) != length(lower_keys) ->
        {:error, :invalid_transitive_tag_keys}

      true ->
        :ok
    end
  end

  defp canonical_transitive_tag_keys([], _session_tags), do: {:ok, []}

  defp canonical_transitive_tag_keys(keys, session_tags) do
    explicit_keys =
      Map.new(session_tags, fn {key, _value} -> {String.downcase(key), key} end)

    Enum.reduce_while(keys, {:ok, []}, fn key, {:ok, acc} ->
      case Map.fetch(explicit_keys, String.downcase(key)) do
        {:ok, canonical_key} -> {:cont, {:ok, acc ++ [canonical_key]}}
        :error -> {:halt, {:error, :invalid_transitive_tag_keys}}
      end
    end)
  end

  defp assume_role_tag_state(caller_principal, session_tags, requested_transitive_tag_keys) do
    with {:ok, inherited_tags} <- inherited_transitive_session_tags(caller_principal),
         :ok <- reject_inherited_transitive_tag_override(inherited_tags, session_tags) do
      effective_session_tags = inherited_tags ++ session_tags

      with :ok <- validate_session_tags(effective_session_tags) do
        inherited_transitive_keys = Enum.map(inherited_tags, &elem(&1, 0))

        {:ok,
         %{
           session_tags: effective_session_tags,
           transitive_tag_keys:
             merge_transitive_tag_keys(inherited_transitive_keys, requested_transitive_tag_keys),
           tag_session_required?: effective_session_tags != []
         }}
      end
    else
      {:error, :invalid_session_tags} -> {:error, :invalid_session_tags}
      {:error, :inherited_transitive_tag_conflict} = error -> error
      _error -> {:error, :invalid_session_tags}
    end
  end

  defp inherited_transitive_session_tags(%{credential_type: :session} = principal) do
    tags =
      principal
      |> Map.get(:tags, Map.get(principal, "tags", %{}))
      |> normalize_tag_map()

    tag_keys =
      principal
      |> principal_transitive_tag_keys()
      |> unique_case_insensitive()

    {:ok, tags_for_transitive_keys(tags, tag_keys)}
  end

  defp inherited_transitive_session_tags(_principal), do: {:ok, []}

  defp principal_transitive_tag_keys(principal) do
    keys =
      Map.get(principal, :transitive_tag_keys) || Map.get(principal, "transitive_tag_keys") || []

    if is_list(keys) and Enum.all?(keys, &is_binary/1), do: keys, else: []
  end

  defp tags_for_transitive_keys(tags, keys) do
    Enum.reduce(keys, [], fn key, acc ->
      case find_tag_case_insensitive(tags, key) do
        nil -> acc
        {tag_key, value} -> acc ++ [{tag_key, value}]
      end
    end)
  end

  defp find_tag_case_insensitive(tags, key) do
    normalized_key = String.downcase(key)

    Enum.find(tags, fn {tag_key, _value} ->
      String.downcase(to_string(tag_key)) == normalized_key
    end)
  end

  defp reject_inherited_transitive_tag_override(inherited_tags, session_tags) do
    inherited_keys =
      inherited_tags
      |> Enum.map(fn {key, _value} -> String.downcase(key) end)
      |> MapSet.new()

    if Enum.any?(session_tags, fn {key, _value} ->
         MapSet.member?(inherited_keys, String.downcase(key))
       end) do
      {:error, :inherited_transitive_tag_conflict}
    else
      :ok
    end
  end

  defp merge_transitive_tag_keys(inherited_keys, requested_keys),
    do: Enum.reduce(requested_keys, inherited_keys, &append_case_insensitive_unique/2)

  defp unique_case_insensitive(values),
    do: Enum.reduce(values, [], &append_case_insensitive_unique/2)

  defp append_case_insensitive_unique(value, acc) do
    if Enum.any?(acc, &(String.downcase(&1) == String.downcase(value))) do
      acc
    else
      acc ++ [value]
    end
  end

  defp session_policy(opts) do
    raw = Keyword.get(opts, :session_policy, Keyword.get(opts, :policy))
    policy_arns = Keyword.get(opts, :policy_arns, [])

    with {:ok, policy_arns} <- managed_policy_arns(policy_arns),
         :ok <- validate_session_policy_plaintext(raw, policy_arns),
         {:ok, inline_policy} <- inline_session_policy(raw),
         {:ok, managed_policies} <- managed_session_policies(policy_arns) do
      combine_session_policies(inline_policy, managed_policies)
    end
  end

  defp inline_session_policy(nil), do: {:ok, nil}

  defp inline_session_policy(raw) when is_binary(raw), do: parse_session_policy(raw)

  defp inline_session_policy(raw) when is_map(raw),
    do: raw |> Jason.encode!() |> parse_session_policy()

  defp inline_session_policy(_raw), do: {:error, :invalid_session_policy}

  defp managed_policy_arns(nil), do: {:ok, []}

  defp managed_policy_arns(arns) when is_list(arns) do
    cond do
      length(arns) > @max_managed_session_policies ->
        {:error, :invalid_session_policy}

      not Enum.all?(arns, &valid_managed_policy_arn?/1) ->
        {:error, :invalid_session_policy}

      length(Enum.uniq(arns)) != length(arns) ->
        {:error, :invalid_session_policy}

      true ->
        {:ok, arns}
    end
  end

  defp managed_policy_arns(_arns), do: {:error, :invalid_session_policy}

  defp valid_managed_policy_arn?(arn), do: Maxio.IAM.validate_managed_policy_arn(arn) == :ok

  defp validate_session_policy_plaintext(raw, policy_arns) do
    inline_size =
      cond do
        is_nil(raw) -> 0
        is_binary(raw) -> byte_size(raw)
        is_map(raw) -> raw |> Jason.encode!() |> byte_size()
        true -> @max_session_policy_plaintext_bytes + 1
      end

    arn_size = Enum.reduce(policy_arns, 0, fn arn, acc -> acc + byte_size(arn) end)

    if inline_size + arn_size <= @max_session_policy_plaintext_bytes do
      :ok
    else
      {:error, :invalid_session_policy}
    end
  end

  defp managed_session_policies([]), do: {:ok, []}

  defp managed_session_policies(policy_arns) do
    Enum.reduce_while(policy_arns, {:ok, []}, fn policy_arn, {:ok, acc} ->
      case Store.managed_session_policy(policy_arn) do
        {:ok, json} ->
          case parse_session_policy(json) do
            {:ok, policy} -> {:cont, {:ok, acc ++ [policy]}}
            {:error, reason} -> {:halt, {:error, reason}}
          end

        {:error, _reason} ->
          {:halt, {:error, :invalid_session_policy}}
      end
    end)
  end

  defp parse_session_policy(json) when is_binary(json) do
    with true <- byte_size(json) <= @max_session_policy_plaintext_bytes,
         {:ok, statements} <- Statement.parse_identity_policy(json),
         true <- statements != [],
         {:ok, %{} = document} <- Jason.decode(json) do
      {:ok, document}
    else
      _error -> {:error, :invalid_session_policy}
    end
  end

  defp combine_session_policies(nil, []), do: {:ok, nil}
  defp combine_session_policies(%{} = inline_policy, []), do: {:ok, inline_policy}

  defp combine_session_policies(nil, managed_policies),
    do: {:ok, combined_policy(managed_policies)}

  defp combine_session_policies(%{} = inline_policy, managed_policies),
    do: {:ok, combined_policy([inline_policy | managed_policies])}

  defp combined_policy(policies) do
    statements =
      policies
      |> Enum.flat_map(&policy_statements/1)

    %{
      "Version" => "2012-10-17",
      "Statement" => statements
    }
  end

  defp policy_statements(%{"Statement" => statements}) when is_list(statements), do: statements
  defp policy_statements(%{"Statement" => %{} = statement}), do: [statement]

  defp assume_role_mfa_context(caller_principal, opts) do
    serial = Keyword.get(opts, :mfa_serial)
    token_code = Keyword.get(opts, :mfa_token_code)

    cond do
      is_nil(serial) and is_nil(token_code) ->
        {:ok, %{present?: false}}

      not (is_binary(serial) and is_binary(token_code)) ->
        {:error, :invalid_mfa_parameters}

      true ->
        verify_assume_role_mfa(caller_principal, serial, token_code)
    end
  end

  defp verify_assume_role_mfa(caller_principal, serial, token_code) do
    time = utc_now()

    case Maxio.IAM.verify_mfa_device(caller_principal, serial, token_code,
           consume: false,
           time: time
         ) do
      :ok ->
        {:ok,
         %{
           present?: true,
           principal: caller_principal,
           serial: serial,
           token_code: token_code,
           serial_hash: sha256_hex(serial),
           time: time
         }}

      {:error, reason} ->
        {:error, {:mfa_failed, reason}}
    end
  end

  defp consume_assume_role_mfa(%{present?: true} = mfa_context) do
    case Maxio.IAM.verify_mfa_device(
           mfa_context_principal(mfa_context),
           mfa_context.serial,
           mfa_context.token_code,
           consume: true,
           time: mfa_context.time
         ) do
      :ok -> :ok
      {:error, reason} -> {:error, {:pre_issue_failed, reason}}
    end
  end

  defp consume_assume_role_mfa(_mfa_context), do: :ok

  defp mfa_context_principal(%{principal: principal}), do: principal

  defp merged_session_tags(role, session_tags) do
    role
    |> role_tags()
    |> normalize_tag_map()
    |> merge_session_tag_list(session_tags)
  end

  defp role_tags(%{} = role), do: Map.get(role, :tags) || Map.get(role, "tags") || %{}

  defp normalize_tag_map(tags) when is_map(tags) do
    Map.new(tags, fn {key, value} -> {to_string(key), tag_value(value)} end)
  end

  defp normalize_tag_map(_tags), do: %{}

  defp merge_session_tag_list(role_tags, []), do: role_tags

  defp merge_session_tag_list(role_tags, session_tags) do
    Enum.reduce(session_tags, role_tags, fn {key, value}, acc ->
      acc
      |> delete_tag_case_insensitive(key)
      |> Map.put(key, value)
    end)
  end

  defp delete_tag_case_insensitive(tags, key) do
    Map.reject(tags, fn {existing_key, _value} ->
      String.downcase(to_string(existing_key)) == String.downcase(key)
    end)
  end

  defp tag_value(nil), do: ""
  defp tag_value(value), do: to_string(value)

  defp maybe_put_condition(conditions, _key, nil), do: conditions
  defp maybe_put_condition(conditions, _key, ""), do: conditions
  defp maybe_put_condition(conditions, key, value), do: Map.put(conditions, key, value)

  defp role_field(role, field) when is_atom(field) do
    case Map.fetch(role, field) do
      {:ok, value} when not is_nil(value) -> {:ok, value}
      _other -> role_string_field(role, Atom.to_string(field))
    end
  end

  defp role_string_field(role, field) do
    case Map.fetch(role, field) do
      {:ok, value} when not is_nil(value) -> {:ok, value}
      _other -> {:error, :invalid_role}
    end
  end

  defp caller_access_key_id(%{access_key: access_key})
       when is_binary(access_key) and access_key != "",
       do: {:ok, access_key}

  defp caller_access_key_id(_principal), do: {:error, :missing_issuer_access_key_id}

  defp session_name(opts) do
    case Keyword.get(opts, :session_name) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, :invalid_session_name}
    end
  end

  defp pre_issue(opts) do
    callback = Keyword.get(opts, :pre_issue, fn -> :ok end)

    case callback.() do
      :ok -> :ok
      {:error, reason} -> {:error, {:pre_issue_failed, reason}}
      other -> {:error, {:pre_issue_failed, other}}
    end
  rescue
    error -> {:error, {:pre_issue_failed, error.__struct__}}
  end

  defp session_access_key_id(opts) do
    access_key_id = Keyword.get(opts, :session_access_key_id) || gen_session_access_key_id()

    if access_key_available?(access_key_id) do
      {:ok, access_key_id}
    else
      {:error, :access_key_id_conflict}
    end
  end

  defp access_key_available?(access_key_id) do
    is_nil(Repo.get_by(AccessKey, access_key_id: access_key_id)) and
      is_nil(Repo.get_by(STSSession, access_key_id: access_key_id))
  end

  defp maybe_filter(query, _field, nil), do: query
  defp maybe_filter(query, _field, ""), do: query

  defp maybe_filter(query, :issuer_access_key_id, value),
    do: where(query, [s], s.issuer_access_key_id == ^value)

  defp maybe_filter(query, :principal_arn, value),
    do: where(query, [s], s.principal_arn == ^value)

  defp gen_session_access_key_id,
    do: "ASIA" <> (:crypto.strong_rand_bytes(10) |> Base.encode32(padding: false))

  defp gen_secret_key, do: :crypto.strong_rand_bytes(30) |> Base.encode64() |> binary_part(0, 40)

  defp gen_session_token, do: :crypto.strong_rand_bytes(64) |> Base.url_encode64(padding: false)

  defp default_session_name, do: "maxio-session-#{System.unique_integer([:positive])}"

  defp sha256_hex(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  @doc false
  @spec assumed_role_arn(String.t(), String.t()) :: String.t()
  def assumed_role_arn("arn:aws:iam:::role/" <> role_name, session_name),
    do: "arn:aws:sts:::assumed-role/#{role_name}/#{session_name}"

  def assumed_role_arn(role_arn, session_name), do: "#{role_arn}/#{session_name}"

  @doc false
  @spec assumed_role_id(map(), String.t()) :: String.t()
  def assumed_role_id(%{id: id}, session_name) when not is_nil(id), do: "#{id}:#{session_name}"

  def assumed_role_id(%{"id" => id}, session_name) when not is_nil(id),
    do: "#{id}:#{session_name}"

  def assumed_role_id(_role, session_name), do: session_name

  defp utc_now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  defp sanitize_changeset_errors(%Ecto.Changeset{} = changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
