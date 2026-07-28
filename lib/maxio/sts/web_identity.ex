defmodule Maxio.STS.WebIdentity do
  @moduledoc """
  Verifies OIDC web identity tokens for STS AssumeRoleWithWebIdentity.

  Providers are loaded from explicit `:providers`, static
  `config :maxio, :web_identity_providers`, and persisted IAM OIDC provider
  rows. Each provider must include `:issuer`, `:audiences` or `:client_ids`,
  and static `:jwks`/`:keys`/`:jwk` material. Verification is deliberately
  fail-closed: the JWS signature, allowed algorithm, issuer, audience and time
  claims must all validate before STS sees a normalized identity.
  """

  @default_allowed_algs ~w(RS256 RS384 RS512 ES256 ES384 ES512)
  @default_clock_skew_seconds 300
  @max_clock_skew_seconds 3_600
  @max_token_bytes 20_000

  @type verified :: %{
          issuer: String.t(),
          issuer_host_path: String.t(),
          provider_arn: String.t(),
          provider: String.t(),
          subject: String.t(),
          subject_sha256: String.t(),
          audience: String.t(),
          audiences: [String.t()],
          claims: map()
        }

  @spec verify(String.t(), keyword()) :: {:ok, verified()} | {:error, atom()}
  def verify(token, opts \\ [])

  def verify(token, opts) when is_binary(token) do
    with :ok <- validate_token_size(token),
         {:ok, unverified_claims} <- peek_claims(token),
         {:ok, issuer} <- string_claim(unverified_claims, "iss"),
         {:ok, provider} <- provider_for_issuer(issuer, opts),
         {:ok, jwks} <- provider_jwks(provider),
         {:ok, allowed_algs} <- provider_allowed_algs(provider),
         {:ok, verified_claims} <- verify_signature(token, jwks, allowed_algs),
         :ok <- verified_issuer_matches?(verified_claims, issuer),
         {:ok, subject} <- string_claim(verified_claims, "sub"),
         {:ok, audience, audiences} <- validate_audience(verified_claims, provider),
         :ok <- validate_time_claims(verified_claims, provider, opts),
         {:ok, issuer_host_path} <- issuer_host_path(issuer) do
      {:ok,
       %{
         issuer: issuer,
         issuer_host_path: issuer_host_path,
         provider_arn: provider_arn(provider, issuer_host_path),
         provider: provider_name(provider, issuer),
         subject: subject,
         subject_sha256: sha256_hex(subject),
         audience: audience,
         audiences: audiences,
         claims: verified_claims
       }}
    else
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _other -> {:error, :invalid_identity_token}
    end
  end

  def verify(_token, _opts), do: {:error, :invalid_identity_token}

  @doc false
  @spec oidc_provider_arn(String.t()) :: {:ok, String.t()} | {:error, atom()}
  def oidc_provider_arn(issuer) when is_binary(issuer) do
    with {:ok, host_path} <- issuer_host_path(issuer) do
      {:ok, "arn:aws:iam:::oidc-provider/#{host_path}"}
    end
  end

  def oidc_provider_arn(_issuer), do: {:error, :invalid_provider_issuer}

  @doc false
  @spec issuer_host_path(String.t()) :: {:ok, String.t()} | {:error, atom()}
  def issuer_host_path(issuer) when is_binary(issuer) do
    uri = URI.parse(issuer)

    cond do
      uri.scheme != "https" ->
        {:error, :invalid_provider_issuer}

      not is_binary(uri.host) or uri.host == "" ->
        {:error, :invalid_provider_issuer}

      is_binary(uri.userinfo) ->
        {:error, :invalid_provider_issuer}

      is_binary(uri.query) or is_binary(uri.fragment) ->
        {:error, :invalid_provider_issuer}

      true ->
        host =
          uri.host
          |> String.downcase()
          |> maybe_put_port(uri.port)

        path =
          uri.path
          |> to_string()
          |> String.trim_trailing("/")

        host_path =
          (host <> path)
          |> String.trim_trailing("/")

        if host_path == "", do: {:error, :invalid_provider_issuer}, else: {:ok, host_path}
    end
  end

  def issuer_host_path(_issuer), do: {:error, :invalid_provider_issuer}

  defp validate_token_size(token) do
    if byte_size(token) >= 4 and byte_size(token) <= @max_token_bytes do
      :ok
    else
      {:error, :invalid_identity_token}
    end
  end

  defp peek_claims(token) do
    case JOSE.JWT.peek(token) do
      %JOSE.JWT{fields: %{} = claims} -> {:ok, claims}
      _other -> {:error, :invalid_identity_token}
    end
  rescue
    _error -> {:error, :invalid_identity_token}
  catch
    _class, _reason -> {:error, :invalid_identity_token}
  end

  defp provider_for_issuer(issuer, opts) do
    if Keyword.has_key?(opts, :providers) do
      opts
      |> Keyword.fetch!(:providers)
      |> List.wrap()
      |> find_provider_for_issuer(issuer)
      |> case do
        {:ok, provider} -> {:ok, provider}
        :error -> {:error, :unknown_identity_provider}
      end
    else
      stored_or_static_provider_for_issuer(issuer, opts)
    end
  end

  defp stored_or_static_provider_for_issuer(issuer, opts) do
    if Keyword.get(opts, :stored_providers?, true) do
      case Maxio.IAM.web_identity_provider_lookup_for_issuer(issuer) do
        {:ok, providers} ->
          providers
          |> find_provider_for_issuer(issuer)
          |> case do
            {:ok, provider} -> {:ok, provider}
            :error -> {:error, :unknown_identity_provider}
          end

        {:error, :identity_provider_disabled} ->
          {:error, :identity_provider_disabled}

        :error ->
          static_provider_for_issuer(issuer)
      end
    else
      static_provider_for_issuer(issuer)
    end
  end

  defp static_provider_for_issuer(issuer) do
    :maxio
    |> Application.get_env(:web_identity_providers, [])
    |> List.wrap()
    |> find_provider_for_issuer(issuer)
    |> case do
      {:ok, provider} -> {:ok, provider}
      :error -> {:error, :unknown_identity_provider}
    end
  end

  defp find_provider_for_issuer(providers, issuer) do
    providers
    |> Enum.find_value(fn provider ->
      if provider_field(provider, :issuer) == issuer do
        {:ok, provider}
      else
        false
      end
    end)
    |> case do
      {:ok, provider} -> {:ok, provider}
      _other -> :error
    end
  end

  defp provider_jwks(provider) do
    provider
    |> provider_key_material()
    |> normalize_jwks()
  end

  defp provider_key_material(provider) do
    provider_field(provider, :jwks) ||
      provider_field(provider, :keys) ||
      provider_field(provider, :jwk)
  end

  defp normalize_jwks(nil), do: {:error, :identity_provider_keys_missing}

  defp normalize_jwks(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, decoded} -> normalize_jwks(decoded)
      _error -> {:error, :identity_provider_keys_malformed}
    end
  end

  defp normalize_jwks(%JOSE.JWK{} = jwk), do: {:ok, [jwk]}

  defp normalize_jwks(%{"keys" => keys}), do: normalize_jwks(keys)
  defp normalize_jwks(%{keys: keys}), do: normalize_jwks(keys)

  defp normalize_jwks(%{} = jwk_map), do: normalize_jwks([jwk_map])

  defp normalize_jwks(keys) when is_list(keys) and keys != [] do
    keys
    |> Enum.reduce_while({:ok, []}, fn raw_key, {:ok, acc} ->
      case normalize_jwk(raw_key) do
        {:ok, jwk} -> {:cont, {:ok, [jwk | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, jwks} -> {:ok, Enum.reverse(jwks)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_jwks(_raw), do: {:error, :identity_provider_keys_malformed}

  defp normalize_jwk(%JOSE.JWK{} = jwk), do: {:ok, jwk}

  defp normalize_jwk(%{} = jwk_map) do
    {:ok, JOSE.JWK.from_map(stringify_keys(jwk_map))}
  rescue
    _error -> {:error, :identity_provider_keys_malformed}
  catch
    _class, _reason -> {:error, :identity_provider_keys_malformed}
  end

  defp normalize_jwk(_raw), do: {:error, :identity_provider_keys_malformed}

  defp provider_allowed_algs(provider) do
    value = provider_field(provider, :allowed_algs) || provider_field(provider, :algorithms)
    allowed = if is_nil(value), do: @default_allowed_algs, else: List.wrap(value)

    if allowed != [] and Enum.all?(allowed, &(is_binary(&1) and &1 != "none")) do
      {:ok, allowed}
    else
      {:error, :identity_provider_algs_malformed}
    end
  end

  defp verify_signature(token, jwks, allowed_algs) do
    Enum.reduce_while(jwks, {:error, :invalid_signature}, fn jwk, _acc ->
      case verify_signature_with_key(token, jwk, allowed_algs) do
        {:ok, claims} -> {:halt, {:ok, claims}}
        {:error, :invalid_signature} -> {:cont, {:error, :invalid_signature}}
      end
    end)
  end

  defp verify_signature_with_key(token, jwk, allowed_algs) do
    case JOSE.JWT.verify_strict(jwk, allowed_algs, token) do
      {true, %JOSE.JWT{fields: %{} = claims}, _jws} -> {:ok, claims}
      _other -> {:error, :invalid_signature}
    end
  rescue
    _error -> {:error, :invalid_signature}
  catch
    _class, _reason -> {:error, :invalid_signature}
  end

  defp verified_issuer_matches?(claims, issuer) do
    case string_claim(claims, "iss") do
      {:ok, ^issuer} -> :ok
      _other -> {:error, :invalid_issuer}
    end
  end

  defp validate_audience(claims, provider) do
    with {:ok, allowed} <- provider_audiences(provider),
         {:ok, audiences} <- claim_audiences(claims),
         audience when is_binary(audience) <- Enum.find(audiences, &(&1 in allowed)) do
      {:ok, audience, audiences}
    else
      _error -> {:error, :invalid_audience}
    end
  end

  defp provider_audiences(provider) do
    value =
      provider_field(provider, :audiences) ||
        provider_field(provider, :client_ids) ||
        provider_field(provider, :audience) ||
        provider_field(provider, :client_id)

    audiences = List.wrap(value)

    if audiences != [] and Enum.all?(audiences, &(is_binary(&1) and &1 != "")) do
      {:ok, audiences}
    else
      {:error, :identity_provider_audiences_missing}
    end
  end

  defp claim_audiences(claims) do
    case Map.get(claims, "aud") do
      audience when is_binary(audience) and audience != "" ->
        {:ok, [audience]}

      audiences when is_list(audiences) and audiences != [] ->
        if Enum.all?(audiences, &(is_binary(&1) and &1 != "")) do
          {:ok, audiences}
        else
          {:error, :invalid_audience}
        end

      _other ->
        {:error, :invalid_audience}
    end
  end

  defp validate_time_claims(claims, provider, opts) do
    now = now_unix(opts)

    with {:ok, skew} <- clock_skew_seconds(provider, opts),
         {:ok, exp} <- integer_claim(claims, "exp"),
         :ok <- reject_expired(now, exp, skew),
         :ok <- reject_not_before(claims, now, skew),
         :ok <- reject_issued_in_future(claims, now, skew) do
      :ok
    end
  end

  defp reject_expired(now, exp, skew) do
    if now <= exp + skew, do: :ok, else: {:error, :expired}
  end

  defp reject_not_before(claims, now, skew) do
    case integer_claim(claims, "nbf", required?: false) do
      {:ok, nbf} when now + skew < nbf -> {:error, :not_yet_valid}
      _other -> :ok
    end
  end

  defp reject_issued_in_future(claims, now, skew) do
    case integer_claim(claims, "iat", required?: false) do
      {:ok, iat} when now + skew < iat -> {:error, :issued_in_future}
      _other -> :ok
    end
  end

  defp string_claim(claims, name) do
    case Map.get(claims, name) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, :invalid_claims}
    end
  end

  defp integer_claim(claims, name, opts \\ []) do
    required? = Keyword.get(opts, :required?, true)

    case Map.get(claims, name) do
      nil when not required? ->
        :missing

      value when is_integer(value) ->
        {:ok, value}

      value when is_float(value) ->
        {:ok, trunc(value)}

      value when is_binary(value) ->
        case Integer.parse(value) do
          {integer, ""} -> {:ok, integer}
          _other -> {:error, :invalid_claims}
        end

      _other ->
        {:error, :invalid_claims}
    end
  end

  defp provider_arn(_provider, issuer_host_path),
    do: "arn:aws:iam:::oidc-provider/#{issuer_host_path}"

  defp provider_name(provider, issuer), do: provider_field(provider, :provider) || issuer

  defp provider_field(provider, key) when is_list(provider) do
    Keyword.get(provider, key)
  end

  defp provider_field(provider, key) when is_map(provider) do
    Map.get(provider, key) || Map.get(provider, Atom.to_string(key))
  end

  defp provider_field(_provider, _key), do: nil

  defp stringify_keys(%{} = map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), stringify_keys(value)}
      {key, value} -> {key, stringify_keys(value)}
    end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp maybe_put_port(host, nil), do: host
  defp maybe_put_port(host, 443), do: host
  defp maybe_put_port(host, port), do: "#{host}:#{port}"

  defp now_unix(opts) do
    case Keyword.get(opts, :now) do
      %DateTime{} = now -> DateTime.to_unix(now)
      integer when is_integer(integer) -> integer
      _other -> DateTime.utc_now() |> DateTime.to_unix()
    end
  end

  defp clock_skew_seconds(provider, opts) do
    provider_field(provider, :clock_skew_seconds)
    |> case do
      nil -> Keyword.get(opts, :clock_skew_seconds, @default_clock_skew_seconds)
      value -> value
    end
    |> normalize_clock_skew_seconds()
  end

  defp normalize_clock_skew_seconds(value)
       when is_integer(value) and value >= 0 and value <= @max_clock_skew_seconds,
       do: {:ok, value}

  defp normalize_clock_skew_seconds(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> normalize_clock_skew_seconds(integer)
      _other -> {:error, :identity_provider_clock_skew_malformed}
    end
  end

  defp normalize_clock_skew_seconds(_value), do: {:error, :identity_provider_clock_skew_malformed}

  defp sha256_hex(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
