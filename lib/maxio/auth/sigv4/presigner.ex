defmodule Maxio.Auth.SigV4.Presigner do
  @moduledoc """
  SigV4 presigned URL generator.

  This module is intentionally transport-free: callers provide the externally
  visible S3 base URL, decoded request path, credentials, and optional query
  parameters/headers. The generated URL uses `UNSIGNED-PAYLOAD`; by default it
  signs only `host`, but callers may bind additional request headers such as
  `content-type`. The HTTP method is part of the canonical request, so a URL
  presigned for one method cannot be replayed with another method.
  """

  alias Maxio.Auth.SigV4.{Canonical, Signer}

  @algorithm "AWS4-HMAC-SHA256"
  @service "s3"
  @max_expires 604_800
  @reserved_query_params MapSet.new([
                           "x-amz-algorithm",
                           "x-amz-credential",
                           "x-amz-date",
                           "x-amz-expires",
                           "x-amz-security-token",
                           "x-amz-signature",
                           "x-amz-signedheaders"
                         ])
  @reserved_signed_headers MapSet.new([
                             "authorization",
                             "host",
                             "x-amz-security-token"
                           ])
  @header_name_re ~r/^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$/

  @type credentials :: %{
          required(:access_key) => String.t(),
          required(:secret_key) => String.t(),
          optional(:session_token) => String.t() | nil
        }

  @spec presign_url(atom() | String.t(), String.t(), String.t(), credentials(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def presign_url(method, base_url, path, credentials, opts \\ []) do
    with {:ok, expires} <- expires(opts),
         {:ok, uri} <- base_uri(base_url),
         {:ok, access_key} <- credential(credentials, :access_key),
         {:ok, secret_key} <- credential(credentials, :secret_key),
         {:ok, query} <- stringify_query(Keyword.get(opts, :query, %{})),
         {:ok, signed_headers} <- signed_headers(Keyword.get(opts, :headers, []), uri) do
      now = Keyword.get(opts, :now, DateTime.utc_now())
      region = Keyword.get(opts, :region, region())

      session_token =
        Map.get(credentials, :session_token) || Map.get(credentials, "session_token")

      amz_date = Calendar.strftime(now, "%Y%m%dT%H%M%SZ")
      scope_date = Calendar.strftime(now, "%Y%m%d")
      scope = "#{scope_date}/#{region}/#{@service}/aws4_request"
      request_path = normalized_path(path)

      signing_query =
        query
        |> Map.merge(%{
          "X-Amz-Algorithm" => @algorithm,
          "X-Amz-Credential" => "#{access_key}/#{scope}",
          "X-Amz-Date" => amz_date,
          "X-Amz-Expires" => Integer.to_string(expires),
          "X-Amz-SignedHeaders" => Canonical.signed_headers(signed_headers)
        })
        |> maybe_put_session_token(session_token)

      canonical_req = %{
        method: method |> to_string() |> String.upcase(),
        path: request_path,
        query: signing_query,
        headers: signed_headers,
        payload_hash: "UNSIGNED-PAYLOAD"
      }

      canonical = Canonical.canonical_request(canonical_req)
      sts = Signer.string_to_sign(amz_date, scope, canonical, @algorithm)
      signing_key = Signer.derive_signing_key(secret_key, scope_date, region, @service)
      signature = Signer.signature(signing_key, sts)

      query = Map.put(signing_query, "X-Amz-Signature", signature)
      {:ok, build_url(uri, request_path, query)}
    end
  end

  @spec max_expires() :: pos_integer()
  def max_expires, do: @max_expires

  defp expires(opts) do
    value = Keyword.get(opts, :expires, 900)

    cond do
      is_integer(value) and value in 1..@max_expires ->
        {:ok, value}

      is_binary(value) ->
        case Integer.parse(value) do
          {integer, ""} when integer in 1..@max_expires -> {:ok, integer}
          _other -> {:error, :invalid_expires}
        end

      true ->
        {:error, :invalid_expires}
    end
  end

  defp base_uri(base_url) when is_binary(base_url) do
    uri = URI.parse(String.trim_trailing(base_url, "/"))

    cond do
      uri.scheme not in ["http", "https"] -> {:error, :invalid_base_url}
      is_nil(uri.host) or uri.host == "" -> {:error, :invalid_base_url}
      is_binary(uri.path) and uri.path not in ["", "/"] -> {:error, :invalid_base_url}
      not is_nil(uri.query) -> {:error, :invalid_base_url}
      not is_nil(uri.fragment) -> {:error, :invalid_base_url}
      true -> {:ok, %{uri | path: nil}}
    end
  end

  defp base_uri(_base_url), do: {:error, :invalid_base_url}

  defp credential(credentials, field) when is_map(credentials) do
    case Map.get(credentials, field) || Map.get(credentials, Atom.to_string(field)) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, {:missing_credential, field}}
    end
  end

  defp credential(_credentials, field), do: {:error, {:missing_credential, field}}

  defp normalized_path("/" <> _rest = path), do: path
  defp normalized_path(path), do: "/" <> to_string(path)

  defp stringify_query(query) when is_map(query) do
    query =
      Map.new(query, fn {key, value} -> {to_string(key), to_string(value)} end)

    if Enum.any?(Map.keys(query), &reserved_query_param?/1) do
      {:error, :reserved_query_param}
    else
      {:ok, query}
    end
  end

  defp stringify_query(_query), do: {:ok, %{}}

  defp reserved_query_param?(key) do
    key
    |> String.downcase()
    |> then(&MapSet.member?(@reserved_query_params, &1))
  end

  defp signed_headers(headers, uri) do
    with {:ok, caller_headers} <- normalize_headers(headers) do
      {:ok, [{"host", host_header(uri)} | caller_headers]}
    end
  end

  defp normalize_headers(headers) when is_map(headers) do
    headers
    |> Enum.map(fn {name, value} -> {name, value} end)
    |> normalize_headers()
  end

  defp normalize_headers(headers) when is_list(headers) do
    Enum.reduce_while(headers, {:ok, [], MapSet.new()}, fn
      {raw_name, raw_value}, {:ok, acc, seen} ->
        with {:ok, name} <- normalize_header_name(raw_name),
             :ok <- reject_reserved_signed_header(name),
             :ok <- reject_duplicate_signed_header(name, seen),
             {:ok, value} <- normalize_header_value(raw_value) do
          {:cont, {:ok, [{name, value} | acc], MapSet.put(seen, name)}}
        else
          {:error, reason} -> {:halt, {:error, reason}}
        end

      _other, {:ok, _acc, _seen} ->
        {:halt, {:error, :invalid_signed_header}}
    end)
    |> case do
      {:ok, normalized, _seen} -> {:ok, Enum.reverse(normalized)}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_headers(_headers), do: {:error, :invalid_signed_header}

  defp normalize_header_name(name) do
    with {:ok, name} <- string_value(name) do
      name = name |> String.trim() |> String.downcase()

      cond do
        name == "" -> {:error, :invalid_signed_header}
        not Regex.match?(@header_name_re, name) -> {:error, :invalid_signed_header}
        String.contains?(name, <<0>>) -> {:error, :invalid_signed_header}
        true -> {:ok, name}
      end
    end
  end

  defp reject_reserved_signed_header(name) do
    if MapSet.member?(@reserved_signed_headers, name),
      do: {:error, :reserved_signed_header},
      else: :ok
  end

  defp reject_duplicate_signed_header(name, seen) do
    if MapSet.member?(seen, name),
      do: {:error, :duplicate_signed_header},
      else: :ok
  end

  defp normalize_header_value(value) do
    with {:ok, value} <- string_value(value) do
      value = String.trim(value)

      if String.contains?(value, ["\r", "\n", <<0>>]),
        do: {:error, :invalid_signed_header},
        else: {:ok, value}
    end
  end

  defp string_value(value) do
    {:ok, to_string(value)}
  rescue
    _error -> {:error, :invalid_signed_header}
  end

  defp maybe_put_session_token(query, nil), do: query
  defp maybe_put_session_token(query, ""), do: query
  defp maybe_put_session_token(query, token), do: Map.put(query, "X-Amz-Security-Token", token)

  defp build_url(%URI{} = uri, path, query) do
    encoded_path = Canonical.canonical_uri(path)
    encoded_query = Canonical.canonical_query(query)

    %URI{uri | path: encoded_path, query: encoded_query}
    |> URI.to_string()
  end

  defp host_header(%URI{host: host, port: nil}), do: host
  defp host_header(%URI{scheme: "http", host: host, port: 80}), do: host
  defp host_header(%URI{scheme: "https", host: host, port: 443}), do: host
  defp host_header(%URI{host: host, port: port}), do: "#{host}:#{port}"

  defp region do
    Application.fetch_env!(:maxio, :s3)
    |> Keyword.fetch!(:region)
  end
end
