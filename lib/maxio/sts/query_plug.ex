defmodule Maxio.STS.QueryPlug do
  @moduledoc """
  Minimal AWS STS Query API plug.

  The plug runs after SigV4 authentication and before S3 dispatch. It only
  handles root-service requests carrying an `Action` query parameter, so STS
  actions cannot accidentally fall through to S3 ListBuckets.
  """

  import Plug.Conn

  alias Maxio.S3.Log
  alias Maxio.IAM
  alias Maxio.STS
  alias Maxio.STS.{Error, View}
  alias Maxio.Auth.SigV4.Signer

  @behaviour Plug

  @version "2011-06-15"
  @form_limit 65_536
  @role_session_name_pattern ~r/\A[A-Za-z0-9+=,.@_-]{2,64}\z/
  @source_identity_pattern ~r/\A(?!aws:)[A-Za-z0-9+=,.@_-]{2,64}\z/i
  @external_id_pattern ~r|\A[A-Za-z0-9_+=,.@:/-]{2,1224}\z|
  @tag_member_param_pattern ~r/\ATags\.member\.(\d+)\.(Key|Value)\z/
  @transitive_tag_key_param_pattern ~r/\ATransitiveTagKeys\.member\.(\d+)\z/
  @policy_arn_param_pattern ~r/\APolicyArns\.member\.(\d+)\.arn\z/
  @access_key_id_pattern ~r/\A[A-Za-z0-9_]{16,128}\z/
  @sigv4_query_param_pattern ~r/\AX-Amz-(?:Algorithm|Credential|Date|Expires|SignedHeaders|Signature|Security-Token|Content-Sha256)\z/
  @get_access_key_info_allowed_params ~w(Action Version AccessKeyId)
  @assume_role_allowed_params ~w(
    Action Version RoleArn RoleSessionName DurationSeconds ExternalId SourceIdentity SerialNumber TokenCode Policy
  )
  @web_identity_allowed_params ~w(
    Action Version RoleArn RoleSessionName DurationSeconds WebIdentityToken Policy ProviderId
  )

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    conn = fetch_query_params(conn)

    if sts_query?(conn) do
      handle_sts_query(conn)
    else
      conn
    end
  end

  @doc "Returns true when this request is addressed to the STS Query API."
  @spec sts_query?(Plug.Conn.t()) :: boolean()
  def sts_query?(conn) do
    conn.assigns[:s3_level] == :service and
      (Map.has_key?(conn.query_params || %{}, "Action") or
         signed_sts_scope?(conn) or
         (conn.method == "POST" and (form_content_type?(conn) or signed_sts_scope?(conn))))
  end

  defp handle_sts_query(conn) do
    try do
      case conn.method do
        "GET" ->
          case verify_get_query_params(conn) do
            :ok -> dispatch_action(conn)
            {:error, %Error{} = error} -> reject(conn, error)
          end

        "POST" ->
          case load_post_form(conn) do
            {:ok, conn} -> dispatch_action(conn)
            {:error, %Error{} = error} -> reject(conn, error)
          end

        _other ->
          reject(conn, Error.new(:invalid_action))
      end
    rescue
      err in Error ->
        reject(conn, err)

      other ->
        Log.error("unhandled exception in sts query api",
          action: action(conn),
          reason: Exception.message(other)
        )

        reject(conn, Error.new(:internal_failure))
    end
  end

  defp dispatch_action(conn) do
    case action(conn) do
      "GetSessionToken" -> get_session_token(conn)
      "GetCallerIdentity" -> get_caller_identity(conn)
      "GetAccessKeyInfo" -> get_access_key_info(conn)
      "AssumeRole" -> assume_role(conn)
      "AssumeRoleWithWebIdentity" -> assume_role_with_web_identity(conn)
      _other -> reject(conn, Error.new(:invalid_action))
    end
  end

  defp get_session_token(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_sts_signature_scope(conn),
         :ok <- reject_temporary_credentials(conn),
         {:ok, mfa_context} <- mfa_context(conn),
         {:ok, duration_seconds} <- duration_seconds(conn),
         {:ok, session} <- issue_session(conn, duration_seconds, mfa_context) do
      request_id = request_id(conn)

      Log.info("sts get-session-token issued",
        action: :get_session_token,
        principal_arn: conn.assigns.principal[:arn],
        mfa_present: mfa_context.present?,
        mfa_serial_hash: Map.get(mfa_context, :serial_hash)
      )

      conn
      |> put_resp_content_type("text/xml")
      |> send_resp(200, View.get_session_token_response(session, request_id))
      |> halt()
    else
      {:error, %Error{} = error} -> reject(conn, error)
    end
  end

  defp get_caller_identity(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_sts_signature_scope(conn),
         {:ok, identity} <- caller_identity(conn.assigns.principal) do
      request_id = request_id(conn)

      Log.info("sts get-caller-identity returned",
        action: :get_caller_identity,
        principal_arn: identity.arn
      )

      conn
      |> put_resp_content_type("text/xml")
      |> send_resp(200, View.get_caller_identity_response(identity, request_id))
      |> halt()
    else
      {:error, %Error{} = error} -> reject(conn, error)
    end
  end

  defp get_access_key_info(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_sts_signature_scope(conn),
         :ok <- reject_unsupported_get_access_key_info_parameters(conn),
         {:ok, access_key_id} <- access_key_id(conn),
         {:ok, account_id} <- access_key_account_id(access_key_id) do
      request_id = request_id(conn)

      Log.info("sts get-access-key-info returned",
        action: :get_access_key_info,
        requested_access_key_id: access_key_id,
        account_id: account_id
      )

      conn
      |> put_resp_content_type("text/xml")
      |> send_resp(200, View.get_access_key_info_response(account_id, request_id))
      |> halt()
    else
      {:error, %Error{} = error} -> reject(conn, error)
    end
  end

  defp assume_role(conn) do
    with :ok <- require_version(conn),
         :ok <- require_authenticated_principal(conn),
         :ok <- require_sts_signature_scope(conn),
         :ok <- reject_unsupported_assume_role_parameters(conn),
         {:ok, role_arn} <- role_arn(conn),
         {:ok, session_name} <- role_session_name(conn),
         {:ok, external_id} <- external_id(conn),
         {:ok, requested_source_identity} <- source_identity(conn),
         {:ok, source_identity} <- effective_source_identity(conn, requested_source_identity),
         {:ok, session_tags} <- session_tags(conn),
         {:ok, transitive_tag_keys} <- transitive_tag_keys(conn, session_tags),
         {:ok, session_policy} <- session_policy(conn),
         {:ok, policy_arns} <- policy_arns(conn),
         {:ok, mfa_context} <- mfa_context(conn),
         {:ok, duration_seconds} <- duration_seconds(conn),
         {:ok, role} <- fetch_role(role_arn),
         {:ok, session} <-
           issue_assume_role(conn, role, session_name, duration_seconds,
             external_id: external_id,
             source_identity: source_identity,
             session_tags: session_tags,
             transitive_tag_keys: transitive_tag_keys,
             session_policy: session_policy,
             policy_arns: policy_arns,
             mfa_context: mfa_context
           ) do
      request_id = request_id(conn)

      Log.info("sts assume-role issued",
        action: :assume_role,
        principal_arn: conn.assigns.principal[:arn],
        role_arn: role_arn,
        session_name: session_name,
        source_identity: source_identity,
        mfa_present: mfa_context.present?,
        mfa_serial_hash: Map.get(mfa_context, :serial_hash)
      )

      conn
      |> put_resp_content_type("text/xml")
      |> send_resp(200, View.assume_role_response(session, request_id))
      |> halt()
    else
      {:error, %Error{} = error} -> reject(conn, error)
    end
  end

  defp assume_role_with_web_identity(conn) do
    with :ok <- require_version(conn),
         :ok <- reject_unsupported_web_identity_parameters(conn),
         :ok <- reject_web_identity_provider_id(conn),
         {:ok, role_arn} <- role_arn(conn),
         {:ok, session_name} <- role_session_name(conn),
         {:ok, web_identity_token} <- web_identity_token(conn),
         {:ok, session_policy} <- session_policy(conn),
         {:ok, policy_arns} <- policy_arns(conn),
         {:ok, duration_seconds} <- duration_seconds(conn),
         {:ok, role} <- fetch_role(role_arn),
         {:ok, web_identity} <- verify_web_identity_token(conn, web_identity_token),
         {:ok, session} <-
           issue_assume_role_with_web_identity(conn, role, web_identity, session_name,
             duration_seconds: duration_seconds,
             session_policy: session_policy,
             policy_arns: policy_arns
           ) do
      request_id = request_id(conn)

      Log.info("sts assume-role-with-web-identity issued",
        action: :assume_role_with_web_identity,
        role_arn: role_arn,
        session_name: session_name,
        provider_arn: web_identity.provider_arn,
        subject_hash: web_identity.subject_sha256,
        audience: web_identity.audience,
        source_identity: session.source_identity,
        tag_keys: session.tags |> Map.keys() |> Enum.sort()
      )

      conn
      |> put_resp_content_type("text/xml")
      |> send_resp(200, View.assume_role_with_web_identity_response(session, request_id))
      |> halt()
    else
      {:error, %Error{} = error} -> reject(conn, error)
    end
  end

  defp require_version(conn) do
    case Map.get(params(conn), "Version") do
      @version ->
        :ok

      nil ->
        {:error, Error.new(:invalid_parameter_value, message: "Version is required.")}

      _other ->
        {:error, Error.new(:invalid_parameter_value, message: "Version must be #{@version}.")}
    end
  end

  defp require_authenticated_principal(conn) do
    case conn.assigns[:principal] do
      :anonymous ->
        {:error, Error.new(:access_denied, message: "STS requests must be signed.")}

      %{access_key: access_key} when is_binary(access_key) and access_key != "" ->
        :ok

      _other ->
        {:error, Error.new(:access_denied)}
    end
  end

  defp require_sts_signature_scope(conn) do
    case conn.assigns[:sigv4_signed_request] do
      %{service: "sts"} ->
        :ok

      %{service: _other} ->
        {:error,
         Error.new(:access_denied,
           message: "Credential scope service must be sts for STS requests."
         )}

      _other ->
        {:error, Error.new(:access_denied, message: "STS requests must be signed.")}
    end
  end

  defp reject_temporary_credentials(conn) do
    if conn.assigns.principal[:credential_type] == :session do
      {:error,
       Error.new(:access_denied,
         message: "GetSessionToken cannot be called with temporary credentials."
       )}
    else
      :ok
    end
  end

  defp duration_seconds(conn) do
    case Map.get(params(conn), "DurationSeconds") do
      nil ->
        {:ok, nil}

      value ->
        case Integer.parse(value) do
          {seconds, ""} ->
            {:ok, seconds}

          _other ->
            {:error,
             Error.new(:invalid_parameter_value, message: "DurationSeconds must be an integer.")}
        end
    end
  end

  defp issue_session(conn, duration_seconds, mfa_context) do
    opts =
      [
        issuer_access_key_id: conn.assigns.principal.access_key,
        session_name: "get-session-token",
        mfa_authenticated: mfa_context.present?,
        mfa_serial_hash: Map.get(mfa_context, :serial_hash),
        pre_issue: Map.fetch!(mfa_context, :pre_issue)
      ]
      |> maybe_put_duration(duration_seconds)

    case STS.issue_session(opts) do
      {:ok, session} ->
        {:ok, session}

      {:error, :invalid_session_duration} ->
        {:error,
         Error.new(:invalid_parameter_value,
           message: "DurationSeconds must be between 900 and the principal-specific maximum."
         )}

      {:error, :issuer_access_key_not_found} ->
        {:error,
         Error.new(:access_denied, message: "The signing access key cannot issue STS sessions.")}

      {:error, {:pre_issue_failed, _reason}} ->
        {:error, Error.new(:access_denied, message: "MFA validation failed.")}

      {:error, reason} ->
        Log.warn("sts get-session-token failed",
          action: :get_session_token,
          reason: inspect(reason)
        )

        {:error, Error.new(:internal_failure)}
    end
  end

  defp role_arn(conn) do
    case Map.get(params(conn), "RoleArn") do
      value when is_binary(value) and value != "" ->
        {:ok, value}

      _other ->
        {:error, Error.new(:invalid_parameter_value, message: "RoleArn is required.")}
    end
  end

  defp role_session_name(conn) do
    case Map.get(params(conn), "RoleSessionName") do
      value when is_binary(value) ->
        if Regex.match?(@role_session_name_pattern, value) do
          {:ok, value}
        else
          {:error,
           Error.new(:invalid_parameter_value,
             message: "RoleSessionName must be 2 to 64 allowed characters."
           )}
        end

      _other ->
        {:error, Error.new(:invalid_parameter_value, message: "RoleSessionName is required.")}
    end
  end

  defp web_identity_token(conn) do
    case Map.get(params(conn), "WebIdentityToken") do
      value when is_binary(value) and value != "" ->
        {:ok, value}

      _other ->
        {:error, Error.new(:invalid_parameter_value, message: "WebIdentityToken is required.")}
    end
  end

  defp verify_web_identity_token(conn, token) do
    opts =
      case conn.private[:maxio_now] do
        %DateTime{} = now -> [now: now]
        _other -> []
      end

    case STS.WebIdentity.verify(token, opts) do
      {:ok, web_identity} ->
        {:ok, web_identity}

      {:error, reason} ->
        Log.warn("sts web identity token rejected",
          action: :assume_role_with_web_identity,
          reason: reason
        )

        {:error, web_identity_error(reason)}
    end
  end

  defp web_identity_error(:expired),
    do: Error.new(:expired_token, message: "The web identity token has expired.")

  defp web_identity_error(:invalid_audience),
    do: Error.new(:idp_rejected_claim, message: "The web identity token audience is rejected.")

  defp web_identity_error(:unknown_identity_provider),
    do:
      Error.new(:invalid_identity_token, message: "No matching identity provider is configured.")

  defp web_identity_error(:identity_provider_disabled),
    do: Error.new(:invalid_identity_token, message: "The identity provider is disabled.")

  defp web_identity_error(:invalid_signature),
    do:
      Error.new(:invalid_identity_token, message: "The web identity token signature is invalid.")

  defp web_identity_error(_reason), do: Error.new(:invalid_identity_token)

  defp reject_unsupported_assume_role_parameters(conn) do
    unsupported =
      params(conn)
      |> Map.keys()
      |> Enum.find(&unsupported_assume_role_param?/1)

    if unsupported do
      {:error,
       Error.new(:invalid_parameter_value,
         message: "#{unsupported} is not implemented for AssumeRole."
       )}
    else
      :ok
    end
  end

  defp unsupported_assume_role_param?(param) when param in @assume_role_allowed_params,
    do: false

  defp unsupported_assume_role_param?("Tags.member." <> _rest = param),
    do: not Regex.match?(@tag_member_param_pattern, param)

  defp unsupported_assume_role_param?("TransitiveTagKeys.member." <> _rest = param),
    do: not Regex.match?(@transitive_tag_key_param_pattern, param)

  defp unsupported_assume_role_param?("PolicyArns.member." <> _rest = param),
    do: not Regex.match?(@policy_arn_param_pattern, param)

  defp unsupported_assume_role_param?(param) when is_binary(param), do: true

  defp unsupported_assume_role_param?(_param), do: true

  defp reject_unsupported_web_identity_parameters(conn) do
    unsupported =
      params(conn)
      |> Map.keys()
      |> Enum.find(&unsupported_web_identity_param?/1)

    if unsupported do
      {:error,
       Error.new(:invalid_parameter_value,
         message: "#{unsupported} is not implemented for AssumeRoleWithWebIdentity."
       )}
    else
      :ok
    end
  end

  defp unsupported_web_identity_param?(param) when param in @web_identity_allowed_params,
    do: false

  defp unsupported_web_identity_param?("PolicyArns.member." <> _rest = param),
    do: not Regex.match?(@policy_arn_param_pattern, param)

  defp unsupported_web_identity_param?(param) when is_binary(param), do: true

  defp unsupported_web_identity_param?(_param), do: true

  defp reject_unsupported_get_access_key_info_parameters(conn) do
    unsupported =
      params(conn)
      |> Map.keys()
      |> Enum.find(fn key ->
        key not in @get_access_key_info_allowed_params and
          not Regex.match?(@sigv4_query_param_pattern, key)
      end)

    if unsupported do
      {:error,
       Error.new(:invalid_parameter_value,
         message: "#{unsupported} is not implemented for GetAccessKeyInfo."
       )}
    else
      :ok
    end
  end

  defp access_key_id(conn) do
    case Map.get(params(conn), "AccessKeyId") do
      value when is_binary(value) ->
        if valid_access_key_id?(value) do
          {:ok, value}
        else
          {:error, Error.new(:invalid_parameter_value, message: "AccessKeyId is invalid.")}
        end

      _other ->
        {:error, Error.new(:invalid_parameter_value, message: "AccessKeyId is required.")}
    end
  end

  defp valid_access_key_id?(value) do
    Regex.match?(@access_key_id_pattern, value) or configured_root_access_key?(value)
  end

  defp configured_root_access_key?(value) do
    case Application.get_env(:maxio, :s3, []) |> Keyword.get(:root_user) do
      root_access_key when is_binary(root_access_key) -> root_access_key == value
      _other -> false
    end
  end

  defp access_key_account_id(access_key_id) do
    case STS.access_key_account_id(access_key_id) do
      {:ok, account_id} ->
        {:ok, account_id}

      {:error, :access_key_not_found} ->
        {:error,
         Error.new(:invalid_client_token_id, message: "The access key ID does not exist.")}

      {:error, :invalid_access_key_id} ->
        {:error, Error.new(:invalid_parameter_value, message: "AccessKeyId is invalid.")}
    end
  end

  defp reject_web_identity_provider_id(conn) do
    case Map.get(params(conn), "ProviderId") do
      nil ->
        :ok

      "" ->
        :ok

      _provider_id ->
        {:error,
         Error.new(:invalid_parameter_value,
           message: "ProviderId is only valid for OAuth 2.0 access tokens."
         )}
    end
  end

  defp fetch_role(role_arn) do
    case IAM.get_role_by_arn(role_arn) do
      {:ok, role} ->
        {:ok, role}

      :error ->
        {:error, Error.new(:access_denied, message: "Cannot assume the requested role.")}
    end
  end

  defp external_id(conn) do
    case Map.get(params(conn), "ExternalId") do
      nil ->
        {:ok, nil}

      value when is_binary(value) ->
        if Regex.match?(@external_id_pattern, value) do
          {:ok, value}
        else
          {:error,
           Error.new(:invalid_parameter_value,
             message: "ExternalId must be 2 to 1224 allowed characters."
           )}
        end

      _other ->
        {:error, Error.new(:invalid_parameter_value, message: "ExternalId is invalid.")}
    end
  end

  defp source_identity(conn) do
    case Map.get(params(conn), "SourceIdentity") do
      nil ->
        {:ok, nil}

      value when is_binary(value) ->
        if Regex.match?(@source_identity_pattern, value) do
          {:ok, value}
        else
          {:error,
           Error.new(:invalid_parameter_value,
             message:
               "SourceIdentity must be 2 to 64 allowed characters and must not start with aws:."
           )}
        end

      _other ->
        {:error, Error.new(:invalid_parameter_value, message: "SourceIdentity is invalid.")}
    end
  end

  defp effective_source_identity(conn, requested_source_identity) do
    inherited_source_identity = conn.assigns.principal[:source_identity]

    cond do
      is_binary(inherited_source_identity) and is_nil(requested_source_identity) ->
        {:ok, inherited_source_identity}

      is_binary(inherited_source_identity) and
          requested_source_identity == inherited_source_identity ->
        {:ok, inherited_source_identity}

      is_binary(inherited_source_identity) ->
        {:error,
         Error.new(:invalid_parameter_value,
           message: "SourceIdentity cannot be changed during role chaining."
         )}

      true ->
        {:ok, requested_source_identity}
    end
  end

  defp session_tags(conn) do
    params = params(conn)

    with {:ok, grouped} <- collect_session_tag_params(params),
         {:ok, tags} <- build_session_tags(grouped),
         :ok <- Maxio.Tags.validate(tags, :bucket),
         :ok <- reject_case_insensitive_duplicate_tag_keys(tags) do
      {:ok, tags}
    else
      _error ->
        {:error, Error.new(:invalid_parameter_value, message: "Session tags are invalid.")}
    end
  end

  defp collect_session_tag_params(params) do
    Enum.reduce_while(params, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case Regex.run(@tag_member_param_pattern, key) do
        [_, index, field] ->
          case put_session_tag_field(acc, index, field, value) do
            {:ok, updated} -> {:cont, {:ok, updated}}
            {:error, reason} -> {:halt, {:error, reason}}
          end

        nil ->
          {:cont, {:ok, acc}}
      end
    end)
  end

  defp put_session_tag_field(acc, index, field, value) do
    index
    |> String.to_integer()
    |> then(fn parsed_index ->
      if parsed_index > 0 do
        {:ok, Map.update(acc, parsed_index, %{field => value}, &Map.put(&1, field, value))}
      else
        {:error, :invalid_session_tags}
      end
    end)
  end

  defp build_session_tags(grouped) do
    tags =
      grouped
      |> Enum.sort_by(fn {index, _fields} -> index end)
      |> Enum.map(fn {_index, fields} -> {Map.get(fields, "Key"), Map.get(fields, "Value")} end)

    if Enum.all?(tags, fn {key, value} -> is_binary(key) and is_binary(value) end) do
      {:ok, tags}
    else
      {:error, :invalid_session_tags}
    end
  end

  defp reject_case_insensitive_duplicate_tag_keys(tags) do
    lower_keys = Enum.map(tags, fn {key, _value} -> String.downcase(key) end)

    if Enum.uniq(lower_keys) == lower_keys do
      :ok
    else
      {:error, :invalid_session_tags}
    end
  end

  defp transitive_tag_keys(conn, session_tags) do
    params = params(conn)

    with {:ok, grouped} <- collect_transitive_tag_key_params(params),
         {:ok, keys} <- build_transitive_tag_keys(grouped),
         :ok <- validate_transitive_tag_keys(keys, session_tags) do
      {:ok, keys}
    else
      _error ->
        {:error, Error.new(:invalid_parameter_value, message: "TransitiveTagKeys are invalid.")}
    end
  end

  defp collect_transitive_tag_key_params(params) do
    Enum.reduce_while(params, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case Regex.run(@transitive_tag_key_param_pattern, key) do
        [_, index] ->
          case put_transitive_tag_key(acc, index, value) do
            {:ok, updated} -> {:cont, {:ok, updated}}
            {:error, reason} -> {:halt, {:error, reason}}
          end

        nil ->
          {:cont, {:ok, acc}}
      end
    end)
  end

  defp put_transitive_tag_key(acc, index, value) do
    parsed_index = String.to_integer(index)

    cond do
      parsed_index <= 0 ->
        {:error, :invalid_transitive_tag_keys}

      Map.has_key?(acc, parsed_index) ->
        {:error, :invalid_transitive_tag_keys}

      not is_binary(value) ->
        {:error, :invalid_transitive_tag_keys}

      true ->
        {:ok, Map.put(acc, parsed_index, value)}
    end
  end

  defp build_transitive_tag_keys(grouped) do
    keys =
      grouped
      |> Enum.sort_by(fn {index, _value} -> index end)
      |> Enum.map(fn {_index, value} -> value end)

    if Enum.all?(keys, &is_binary/1) do
      {:ok, keys}
    else
      {:error, :invalid_transitive_tag_keys}
    end
  end

  defp validate_transitive_tag_keys([], _session_tags), do: :ok

  defp validate_transitive_tag_keys(keys, session_tags) do
    explicit_tag_keys =
      session_tags
      |> Enum.map(fn {key, _value} -> String.downcase(key) end)
      |> MapSet.new()

    lower_keys = Enum.map(keys, &String.downcase/1)

    cond do
      Maxio.Tags.validate(Enum.map(keys, &{&1, ""}), :bucket) != :ok ->
        {:error, :invalid_transitive_tag_keys}

      Enum.uniq(lower_keys) != lower_keys ->
        {:error, :invalid_transitive_tag_keys}

      not Enum.all?(lower_keys, &MapSet.member?(explicit_tag_keys, &1)) ->
        {:error, :invalid_transitive_tag_keys}

      true ->
        :ok
    end
  end

  defp session_policy(conn) do
    case Map.get(params(conn), "Policy") do
      nil ->
        {:ok, nil}

      policy when is_binary(policy) ->
        {:ok, policy}

      _other ->
        {:error, Error.new(:invalid_parameter_value, message: "Policy is invalid.")}
    end
  end

  defp policy_arns(conn) do
    params = params(conn)

    with {:ok, grouped} <- collect_policy_arn_params(params),
         {:ok, arns} <- build_policy_arns(grouped) do
      {:ok, arns}
    else
      _error ->
        {:error, Error.new(:invalid_parameter_value, message: "PolicyArns are invalid.")}
    end
  end

  defp collect_policy_arn_params(params) do
    Enum.reduce_while(params, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case Regex.run(@policy_arn_param_pattern, key) do
        [_, index] ->
          case put_policy_arn(acc, index, value) do
            {:ok, updated} -> {:cont, {:ok, updated}}
            {:error, reason} -> {:halt, {:error, reason}}
          end

        nil ->
          {:cont, {:ok, acc}}
      end
    end)
  end

  defp put_policy_arn(acc, index, value) do
    parsed_index = String.to_integer(index)

    cond do
      parsed_index <= 0 -> {:error, :invalid_policy_arns}
      Map.has_key?(acc, parsed_index) -> {:error, :invalid_policy_arns}
      not is_binary(value) -> {:error, :invalid_policy_arns}
      true -> {:ok, Map.put(acc, parsed_index, value)}
    end
  end

  defp build_policy_arns(grouped) do
    arns =
      grouped
      |> Enum.sort_by(fn {index, _value} -> index end)
      |> Enum.map(fn {_index, value} -> value end)

    if Enum.all?(arns, &is_binary/1) do
      {:ok, arns}
    else
      {:error, :invalid_policy_arns}
    end
  end

  defp mfa_context(conn) do
    serial = Map.get(params(conn), "SerialNumber")
    token_code = Map.get(params(conn), "TokenCode")

    cond do
      is_nil(serial) and is_nil(token_code) ->
        {:ok, %{present?: false, pre_issue: fn -> :ok end}}

      not valid_mfa_serial?(serial) ->
        {:error,
         Error.new(:invalid_parameter_value,
           message: "SerialNumber is required when TokenCode is present."
         )}

      not valid_mfa_token_code?(token_code) ->
        {:error,
         Error.new(:invalid_parameter_value,
           message: "TokenCode must be a six digit MFA code."
         )}

      true ->
        verify_mfa_context(conn, serial, token_code)
    end
  end

  defp valid_mfa_serial?(serial) when is_binary(serial),
    do: serial != "" and byte_size(serial) <= 512 and not String.match?(serial, ~r/\s/)

  defp valid_mfa_serial?(_serial), do: false

  defp valid_mfa_token_code?(token_code) when is_binary(token_code),
    do: String.match?(token_code, ~r/\A\d{6}\z/)

  defp valid_mfa_token_code?(_token_code), do: false

  defp verify_mfa_context(conn, serial, token_code) do
    principal = conn.assigns.principal
    now = conn.private[:maxio_now] || DateTime.utc_now()

    case IAM.verify_mfa_device(principal, serial, token_code, consume: false, time: now) do
      :ok ->
        serial_hash = sha256_hex(serial)

        {:ok,
         %{
           present?: true,
           serial: serial,
           token_code: token_code,
           serial_hash: serial_hash,
           time: now,
           pre_issue: fn ->
             IAM.verify_mfa_device(principal, serial, token_code, consume: true, time: now)
           end
         }}

      {:error, reason} ->
        Log.warn("sts mfa rejected",
          action: sts_action_log_name(conn),
          principal_arn: principal[:arn],
          mfa_serial_hash: sha256_hex(serial),
          reason: reason
        )

        {:error, Error.new(:access_denied, message: "MFA validation failed.")}
    end
  end

  defp issue_assume_role(conn, role, session_name, duration_seconds, opts) do
    external_id = Keyword.get(opts, :external_id)
    source_identity = Keyword.get(opts, :source_identity)
    session_tags = Keyword.get(opts, :session_tags, [])
    transitive_tag_keys = Keyword.get(opts, :transitive_tag_keys, [])
    session_policy = Keyword.get(opts, :session_policy)
    policy_arns = Keyword.get(opts, :policy_arns, [])
    mfa_context = Keyword.fetch!(opts, :mfa_context)

    opts =
      [
        session_name: session_name,
        external_id: external_id,
        source_identity: source_identity,
        session_tags: session_tags,
        transitive_tag_keys: transitive_tag_keys,
        session_policy: session_policy,
        policy_arns: policy_arns,
        secure_transport: conn.scheme == :https,
        source_ip: source_ip(conn),
        current_time: conn.private[:maxio_now] || DateTime.utc_now(),
        mfa_serial: Map.get(mfa_context, :serial),
        mfa_token_code: Map.get(mfa_context, :token_code)
      ]
      |> maybe_put_duration(duration_seconds)

    case STS.assume_role(conn.assigns.principal, role, opts) do
      {:ok, session} ->
        {:ok, session}

      {:error, {:assume_role_denied, _reason}} ->
        {:error, Error.new(:access_denied, message: "Cannot assume the requested role.")}

      {:error, {:caller_assume_role_denied, _reason}} ->
        {:error,
         Error.new(:access_denied,
           message: "Caller is not authorized to assume the requested role."
         )}

      {:error, {:set_source_identity_denied, _reason}} ->
        {:error,
         Error.new(:access_denied, message: "Cannot set SourceIdentity for the requested role.")}

      {:error, {:caller_set_source_identity_denied, _reason}} ->
        {:error,
         Error.new(:access_denied,
           message: "Caller is not authorized to set SourceIdentity for the requested role."
         )}

      {:error, {:caller_tag_session_denied, _reason}} ->
        {:error,
         Error.new(:access_denied,
           message: "Caller is not authorized to tag the requested role session."
         )}

      {:error, {:tag_session_denied, _reason}} ->
        {:error, Error.new(:access_denied, message: "Cannot tag the requested role session.")}

      {:error, :invalid_session_duration} ->
        {:error,
         Error.new(:invalid_parameter_value,
           message: "DurationSeconds must be between 900 and the role maximum."
         )}

      {:error, :invalid_session_name} ->
        {:error, Error.new(:invalid_parameter_value, message: "RoleSessionName is invalid.")}

      {:error, :source_identity_cannot_be_changed} ->
        {:error,
         Error.new(:invalid_parameter_value,
           message: "SourceIdentity cannot be changed during role chaining."
         )}

      {:error, :invalid_session_tags} ->
        {:error, Error.new(:invalid_parameter_value, message: "Session tags are invalid.")}

      {:error, :invalid_transitive_tag_keys} ->
        {:error, Error.new(:invalid_parameter_value, message: "TransitiveTagKeys are invalid.")}

      {:error, :invalid_session_policy} ->
        {:error, Error.new(:malformed_policy_document)}

      {:error, :inherited_transitive_tag_conflict} ->
        {:error,
         Error.new(:invalid_parameter_value,
           message: "Session tags cannot override inherited transitive tags."
         )}

      {:error, :invalid_mfa_parameters} ->
        {:error,
         Error.new(:invalid_parameter_value,
           message: "SerialNumber and TokenCode are required together."
         )}

      {:error, {:mfa_failed, _reason}} ->
        {:error, Error.new(:access_denied, message: "MFA validation failed.")}

      {:error, {:pre_issue_failed, _reason}} ->
        {:error, Error.new(:access_denied, message: "MFA validation failed.")}

      {:error, reason} ->
        Log.warn("sts assume-role failed",
          action: :assume_role,
          role_arn: role.role_arn,
          reason: inspect(reason)
        )

        {:error, Error.new(:internal_failure)}
    end
  end

  defp issue_assume_role_with_web_identity(conn, role, web_identity, session_name, opts) do
    duration_seconds = Keyword.get(opts, :duration_seconds)
    session_policy = Keyword.get(opts, :session_policy)
    policy_arns = Keyword.get(opts, :policy_arns, [])

    issue_opts =
      [
        session_name: session_name,
        session_policy: session_policy,
        policy_arns: policy_arns,
        secure_transport: conn.scheme == :https,
        source_ip: source_ip(conn),
        current_time: conn.private[:maxio_now] || DateTime.utc_now()
      ]
      |> maybe_put_duration(duration_seconds)

    case STS.assume_role_with_web_identity(role, web_identity, issue_opts) do
      {:ok, session} ->
        {:ok, session}

      {:error, {:assume_role_with_web_identity_denied, _reason}} ->
        {:error, Error.new(:access_denied, message: "Cannot assume the requested role.")}

      {:error, {:set_source_identity_denied, _reason}} ->
        {:error,
         Error.new(:access_denied, message: "Cannot set SourceIdentity for the requested role.")}

      {:error, {:tag_session_denied, _reason}} ->
        {:error, Error.new(:access_denied, message: "Cannot tag the requested role session.")}

      {:error, :invalid_session_duration} ->
        {:error,
         Error.new(:invalid_parameter_value,
           message: "DurationSeconds must be between 900 and the role maximum."
         )}

      {:error, :invalid_session_name} ->
        {:error, Error.new(:invalid_parameter_value, message: "RoleSessionName is invalid.")}

      {:error, :invalid_session_policy} ->
        {:error, Error.new(:malformed_policy_document)}

      {:error, :invalid_source_identity} ->
        {:error, Error.new(:invalid_identity_token)}

      {:error, :invalid_session_tags} ->
        {:error, Error.new(:invalid_identity_token)}

      {:error, :invalid_transitive_tag_keys} ->
        {:error, Error.new(:invalid_identity_token)}

      {:error, :malformed_trust_policy} ->
        {:error, Error.new(:access_denied, message: "Cannot assume the requested role.")}

      {:error, reason} ->
        Log.warn("sts assume-role-with-web-identity failed",
          action: :assume_role_with_web_identity,
          role_arn: role.role_arn,
          provider_arn: web_identity.provider_arn,
          subject_hash: web_identity.subject_sha256,
          reason: inspect(reason)
        )

        {:error, Error.new(:internal_failure)}
    end
  end

  defp caller_identity(%{type: :assumed_role, arn: role_arn} = principal) do
    session_name =
      principal[:session_name] ||
        principal[:session_access_key] ||
        principal[:access_key]

    role =
      case IAM.get_role_by_arn(role_arn) do
        {:ok, role} -> role
        :error -> %{}
      end

    {:ok,
     %{
       account: STS.account_id(),
       arn: STS.assumed_role_arn(role_arn, session_name),
       user_id: STS.assumed_role_id(role, session_name)
     }}
  end

  defp caller_identity(%{arn: arn, access_key: access_key})
       when is_binary(arn) and is_binary(access_key) do
    {:ok, %{account: STS.account_id(), arn: arn, user_id: access_key}}
  end

  defp caller_identity(_principal), do: {:error, Error.new(:access_denied)}

  defp maybe_put_duration(opts, nil), do: opts

  defp maybe_put_duration(opts, duration_seconds),
    do: Keyword.put(opts, :duration_seconds, duration_seconds)

  defp load_post_form(conn) do
    with :ok <- verify_form_content_type(conn),
         {:ok, conn, body} <- read_form_body(conn),
         {:ok, form_params} <- decode_form_params(body) do
      conn = assign(conn, :sts_params, form_params)

      if web_identity_action?(conn) do
        {:ok, conn}
      else
        with :ok <- require_header_auth(conn),
             :ok <- verify_payload_hash(conn, body) do
          {:ok, conn}
        end
      end
    end
  end

  defp verify_get_query_params(conn) do
    try do
      pairs = URI.query_decoder(conn.query_string || "") |> Enum.to_list()

      if duplicate_keys?(pairs) do
        {:error,
         Error.new(:invalid_parameter_value,
           message: "STS query parameters must not be repeated."
         )}
      else
        :ok
      end
    rescue
      ArgumentError ->
        {:error, Error.new(:invalid_parameter_value, message: "Invalid query encoding.")}
    end
  end

  defp require_header_auth(conn) do
    case conn.assigns[:sigv4_signed_request] do
      %{auth_type: :header, payload_mode: :single} ->
        :ok

      %{auth_type: :header} ->
        {:error,
         Error.new(:access_denied,
           message: "STS POST form requests must sign the exact payload hash."
         )}

      _other ->
        {:error,
         Error.new(:access_denied,
           message: "STS POST form requests require header SigV4 authentication."
         )}
    end
  end

  defp verify_form_content_type(conn) do
    if form_content_type?(conn) do
      :ok
    else
      {:error,
       Error.new(:invalid_request,
         message: "STS POST form requests require application/x-www-form-urlencoded."
       )}
    end
  end

  defp read_form_body(conn) do
    case read_body(conn, length: @form_limit, read_length: @form_limit) do
      {:ok, body, conn} ->
        {:ok, conn, body}

      {:more, _partial, conn} ->
        {:error,
         %{
           Error.new(:invalid_parameter_value, message: "STS form body too large.")
           | request_id: request_id(conn)
         }}

      {:error, _reason} ->
        {:error, Error.new(:invalid_request, message: "Unable to read STS form body.")}
    end
  end

  defp verify_payload_hash(conn, body) do
    signed_hash = header(conn, "x-amz-content-sha256")
    actual_hash = Signer.hex_sha256(body)

    normalized_hash =
      if is_binary(signed_hash), do: String.downcase(signed_hash), else: signed_hash

    cond do
      signed_hash in [nil, ""] ->
        {:error,
         Error.new(:access_denied,
           message: "STS POST form requests require x-amz-content-sha256."
         )}

      signed_hash == "UNSIGNED-PAYLOAD" or String.starts_with?(signed_hash, "STREAMING-") ->
        {:error,
         Error.new(:access_denied,
           message: "STS POST form requests must sign the exact payload hash."
         )}

      not payload_hash?(normalized_hash) ->
        {:error,
         Error.new(:access_denied,
           message: "STS POST form requests require a SHA256 payload hash."
         )}

      Signer.secure_compare(normalized_hash, actual_hash) ->
        :ok

      true ->
        {:error,
         Error.new(:access_denied,
           message: "Request payload hash does not match x-amz-content-sha256."
         )}
    end
  end

  defp decode_form_params(body) do
    try do
      pairs = URI.query_decoder(body) |> Enum.to_list()

      if duplicate_keys?(pairs) do
        {:error,
         Error.new(:invalid_parameter_value,
           message: "STS form parameters must not be repeated."
         )}
      else
        {:ok, Map.new(pairs)}
      end
    rescue
      ArgumentError ->
        {:error, Error.new(:invalid_parameter_value, message: "Invalid form encoding.")}
    end
  end

  defp duplicate_keys?(pairs) do
    keys = Enum.map(pairs, fn {key, _value} -> key end)
    Enum.uniq(keys) != keys
  end

  defp reject(conn, %Error{} = error) do
    error = %{error | request_id: error.request_id || request_id(conn)}
    {status, body} = View.error_response(error)

    Log.warn("sts error response",
      action: action(conn),
      code: error.code,
      status: status
    )

    conn
    |> put_resp_content_type("text/xml")
    |> send_resp(status, body)
    |> halt()
  end

  defp params(conn), do: conn.assigns[:sts_params] || conn.query_params || %{}

  defp action(conn), do: Map.get(params(conn), "Action")

  defp web_identity_action?(conn), do: action(conn) == "AssumeRoleWithWebIdentity"

  defp sts_action_log_name(conn) do
    case action(conn) do
      "AssumeRole" -> :assume_role
      "AssumeRoleWithWebIdentity" -> :assume_role_with_web_identity
      "GetSessionToken" -> :get_session_token
      "GetCallerIdentity" -> :get_caller_identity
      "GetAccessKeyInfo" -> :get_access_key_info
      other -> other
    end
  end

  defp form_content_type?(conn) do
    case header(conn, "content-type") do
      nil ->
        false

      content_type ->
        content_type
        |> String.split(";", parts: 2)
        |> List.first()
        |> String.trim()
        |> String.downcase()
        |> Kernel.==("application/x-www-form-urlencoded")
    end
  end

  defp header(conn, name), do: conn |> get_req_header(name) |> List.first()

  defp signed_sts_scope?(conn), do: match?(%{service: "sts"}, conn.assigns[:sigv4_signed_request])

  defp payload_hash?(value) when is_binary(value), do: String.match?(value, ~r/\A[0-9a-f]{64}\z/)
  defp payload_hash?(_value), do: false

  defp request_id(conn) do
    get_resp_header(conn, "x-request-id") |> List.first() ||
      get_req_header(conn, "x-request-id") |> List.first()
  end

  defp source_ip(conn) do
    case :inet.ntoa(conn.remote_ip) do
      chars when is_list(chars) -> to_string(chars)
      _other -> nil
    end
  end

  defp sha256_hex(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
