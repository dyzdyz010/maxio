defmodule Maxio.S3.PrometheusToken do
  @moduledoc """
  MinIO-style Prometheus bearer token helper.

  Tokens are compact JWTs signed with the access key secret. The endpoint uses
  the `sub` claim as the access key id, verifies the HMAC signature, then
  evaluates `admin:Prometheus` through the normal identity policy evaluator.
  """

  alias Maxio.Auth.CredentialStore

  @default_alg "HS512"
  @issuer "prometheus"
  @audience "prometheus"
  @default_ttl_seconds 365 * 24 * 60 * 60
  @supported_algs ["HS512", "HS256"]

  @type reason ::
          :malformed_token
          | :unsupported_alg
          | :missing_access_key
          | :unknown_access_key
          | :credential_requires_session_token
          | :invalid_claims
          | :invalid_signature
          | :expired
          | :not_yet_valid
          | :missing_exp

  @spec generate(String.t(), String.t(), keyword()) :: String.t()
  def generate(access_key, secret_key, opts \\ [])
      when is_binary(access_key) and is_binary(secret_key) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    alg = Keyword.get(opts, :alg, @default_alg)
    expires_at = Keyword.get(opts, :expires_at, DateTime.add(now, ttl_seconds(opts), :second))

    header = %{"alg" => alg, "typ" => "JWT"}

    payload = %{
      "iss" => Keyword.get(opts, :issuer, @issuer),
      "sub" => access_key,
      "aud" => Keyword.get(opts, :audience, @audience),
      "iat" => DateTime.to_unix(now),
      "exp" => DateTime.to_unix(expires_at)
    }

    sign(header, payload, secret_key)
  end

  @spec default_ttl_seconds() :: pos_integer()
  def default_ttl_seconds, do: @default_ttl_seconds

  @spec authenticate(String.t(), keyword()) :: {:ok, map(), map()} | {:error, reason()}
  def authenticate(token, opts \\ [])

  def authenticate(token, opts) when is_binary(token) do
    with {:ok, header, payload, signing_input, signature} <- decode(token),
         {:ok, alg} <- supported_alg(header),
         {:ok, access_key} <- access_key(payload),
         :ok <- verify_issuer_and_audience(payload),
         {:ok, %{secret_key: secret_key, principal: principal}} <- lookup_secret(access_key),
         :ok <- verify_signature(alg, secret_key, signing_input, signature),
         :ok <- verify_time(payload, Keyword.get(opts, :now, DateTime.utc_now())) do
      {:ok, principal, payload}
    else
      :error ->
        {:error, :unknown_access_key}

      {:error, reason} when reason in [:missing_session_token, :invalid_token, :expired_token] ->
        {:error, :credential_requires_session_token}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def authenticate(_token, _opts), do: {:error, :malformed_token}

  defp ttl_seconds(opts) do
    case Keyword.get(opts, :ttl_seconds, @default_ttl_seconds) do
      seconds when is_integer(seconds) and seconds > 0 -> seconds
      _other -> @default_ttl_seconds
    end
  end

  defp sign(header, payload, secret_key) do
    signing_input =
      [encode_json(header), ".", encode_json(payload)]
      |> IO.iodata_to_binary()

    signature =
      header
      |> Map.fetch!("alg")
      |> mac(secret_key, signing_input)
      |> b64()

    signing_input <> "." <> signature
  end

  defp decode(token) do
    case String.split(token, ".", parts: 3) do
      [encoded_header, encoded_payload, encoded_signature] ->
        with {:ok, header_json} <- b64_decode(encoded_header),
             {:ok, payload_json} <- b64_decode(encoded_payload),
             {:ok, %{} = header} <- Jason.decode(header_json),
             {:ok, %{} = payload} <- Jason.decode(payload_json),
             {:ok, signature} <- b64_decode(encoded_signature) do
          {:ok, header, payload, encoded_header <> "." <> encoded_payload, signature}
        else
          _other -> {:error, :malformed_token}
        end

      _other ->
        {:error, :malformed_token}
    end
  end

  defp encode_json(value) do
    value
    |> Jason.encode!()
    |> b64()
  end

  defp b64(binary), do: Base.url_encode64(binary, padding: false)

  defp b64_decode(value) when is_binary(value) do
    Base.url_decode64(value, padding: false)
  end

  defp supported_alg(%{"alg" => alg}) when alg in @supported_algs, do: {:ok, alg}
  defp supported_alg(_header), do: {:error, :unsupported_alg}

  defp access_key(payload) do
    case Map.get(payload, "sub") do
      access_key when is_binary(access_key) and access_key != "" -> {:ok, access_key}
      _other -> {:error, :missing_access_key}
    end
  end

  defp lookup_secret(access_key), do: CredentialStore.get_secret(access_key)

  defp verify_issuer_and_audience(%{"iss" => @issuer, "aud" => @audience}), do: :ok
  defp verify_issuer_and_audience(_payload), do: {:error, :invalid_claims}

  defp verify_signature(alg, secret_key, signing_input, signature) do
    expected = mac(alg, secret_key, signing_input)

    if byte_size(expected) == byte_size(signature) and
         Plug.Crypto.secure_compare(expected, signature) do
      :ok
    else
      {:error, :invalid_signature}
    end
  end

  defp mac("HS512", secret_key, data), do: :crypto.mac(:hmac, :sha512, secret_key, data)
  defp mac("HS256", secret_key, data), do: :crypto.mac(:hmac, :sha256, secret_key, data)

  defp verify_time(payload, now) do
    now_unix = DateTime.to_unix(now)

    cond do
      not integer_claim?(Map.get(payload, "exp")) ->
        {:error, :missing_exp}

      now_unix >= Map.fetch!(payload, "exp") ->
        {:error, :expired}

      integer_claim?(Map.get(payload, "nbf")) and now_unix < Map.fetch!(payload, "nbf") ->
        {:error, :not_yet_valid}

      true ->
        :ok
    end
  end

  defp integer_claim?(value), do: is_integer(value)
end
