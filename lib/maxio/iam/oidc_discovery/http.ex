defmodule Maxio.IAM.OIDCDiscovery.HTTP do
  @moduledoc """
  Bounded HTTP OpenID Connect discovery implementation.

  This runs only on IAM management actions, not during STS token verification.
  """

  @behaviour Maxio.IAM.OIDCDiscovery

  @max_json_bytes 65_536
  @timeout_ms 5_000

  @impl true
  def discover(issuer_url, opts \\ [])

  def discover(issuer_url, opts) when is_binary(issuer_url) do
    with {:ok, issuer_url} <- normalize_issuer(issuer_url),
         {:ok, discovery} <- fetch_json(discovery_url(issuer_url), opts),
         :ok <- validate_discovery_issuer(discovery, issuer_url),
         {:ok, jwks_uri} <- jwks_uri(discovery),
         {:ok, jwks} <- fetch_json(jwks_uri, opts),
         :ok <- validate_jwks(jwks),
         {:ok, thumbprints} <- tls_thumbprints([issuer_url, jwks_uri], opts) do
      {:ok,
       %{
         discovery_document: discovery,
         jwks: jwks,
         jwks_fetched_at: DateTime.utc_now(),
         thumbprints: thumbprints
       }}
    end
  end

  def discover(_issuer_url, _opts), do: {:error, :invalid_provider_issuer}

  defp normalize_issuer(issuer_url) do
    issuer_url = issuer_url |> String.trim() |> String.trim_trailing("/")

    case Maxio.STS.WebIdentity.issuer_host_path(issuer_url) do
      {:ok, _host_path} -> {:ok, issuer_url}
      {:error, reason} -> {:error, reason}
    end
  end

  defp discovery_url(issuer_url), do: issuer_url <> "/.well-known/openid-configuration"

  defp fetch_json(url, opts) do
    limit = Keyword.get(opts, :max_json_bytes, @max_json_bytes)
    timeout = Keyword.get(opts, :timeout_ms, @timeout_ms)

    case req_fetch_json(url, opts, limit, timeout) do
      {:error, :oidc_discovery_http_error} = error ->
        thumbprint_fetch_json(url, opts, limit, timeout, error)

      result ->
        result
    end
  rescue
    _error -> {:error, :oidc_discovery_http_error}
  end

  defp req_fetch_json(url, opts, limit, timeout) do
    req_request = Keyword.get(opts, :req_request_fun, &Req.request/1)

    case req_request.(
           method: :get,
           url: url,
           receive_timeout: timeout,
           redirect: false,
           decode_body: false,
           into: bounded_body(limit)
         ) do
      {:ok, %Req.Response{status: 200, private: private}} ->
        with {:ok, body} <- fetched_body(private),
             {:ok, decoded} <- decode_json_body(body),
             do: {:ok, decoded}

      {:ok, %Req.Response{private: %{maxio_oidc_body_too_large?: true}}} ->
        {:error, :oidc_discovery_response_too_large}

      {:ok, %Req.Response{}} ->
        {:error, :oidc_discovery_http_error}

      {:error, _reason} ->
        {:error, :oidc_discovery_http_error}
    end
  end

  defp bounded_body(limit) do
    fn {:data, data}, {request, response} ->
      body = Map.get(response.private, :maxio_oidc_body, "")
      next_body = body <> data

      if byte_size(next_body) > limit do
        response =
          put_in(response.private[:maxio_oidc_body_too_large?], true)

        {:halt, {request, response}}
      else
        response = put_in(response.private[:maxio_oidc_body], next_body)
        {:cont, {request, response}}
      end
    end
  end

  defp fetched_body(%{maxio_oidc_body_too_large?: true}),
    do: {:error, :oidc_discovery_response_too_large}

  defp fetched_body(%{maxio_oidc_body: body}) when is_binary(body), do: {:ok, body}
  defp fetched_body(_private), do: {:error, :oidc_discovery_malformed_json}

  defp thumbprint_fetch_json(url, opts, limit, timeout, original_error) do
    if configured_thumbprints(opts) == [] do
      original_error
    else
      case thumbprint_https_get(url, opts, limit, timeout) do
        {:ok, body} ->
          decode_json_body(body)

        {:error, :oidc_discovery_thumbprint_mismatch} = error ->
          error

        {:error, :oidc_discovery_response_too_large} = error ->
          error

        {:error, :oidc_discovery_malformed_json} = error ->
          error

        {:error, _reason} ->
          original_error
      end
    end
  end

  defp thumbprint_https_get(url, opts, limit, timeout) do
    with {:ok, uri} <- https_uri(url),
         {:ok, socket} <- connect_thumbprint_socket(uri, opts, timeout) do
      result =
        with :ok <- send_thumbprint_request(socket, uri),
             {:ok, body} <- recv_thumbprint_response(socket, limit, timeout) do
          {:ok, body}
        end

      :ssl.close(socket)
      result
    end
  rescue
    _error -> {:error, :oidc_discovery_http_error}
  catch
    _kind, _reason -> {:error, :oidc_discovery_http_error}
  end

  defp connect_thumbprint_socket(%URI{host: host, port: port}, opts, timeout) do
    _ = Application.ensure_all_started(:ssl)
    _ = Application.ensure_all_started(:public_key)

    parent = self()
    ref = make_ref()

    verify_fun = fn cert, event, state ->
      if event in [:valid, :valid_peer] or match?({:bad_cert, _reason}, event) do
        send(parent, {ref, :cert, cert})
      end

      case event do
        {:bad_cert, reason} ->
          if thumbprint_trust_fallback_reason?(reason) do
            {:valid, state}
          else
            {:fail, reason}
          end

        {:extension, _extension} ->
          {:unknown, state}

        :valid ->
          {:valid, state}

        :valid_peer ->
          {:valid, state}
      end
    end

    char_host = String.to_charlist(host)

    ssl_opts = [
      verify: :verify_peer,
      cacerts: Keyword.get(opts, :cacerts, :public_key.cacerts_get()),
      server_name_indication: char_host,
      customize_hostname_check: [
        match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
      ],
      verify_fun: {verify_fun, []},
      active: false,
      mode: :binary
    ]

    case :ssl.connect(char_host, port, ssl_opts, timeout) do
      {:ok, socket} ->
        case validate_thumbprint_socket(socket, ref, host, opts) do
          :ok ->
            {:ok, socket}

          {:error, reason} ->
            :ssl.close(socket)
            {:error, reason}
        end

      {:error, _reason} ->
        {:error, :oidc_discovery_http_error}
    end
  end

  defp validate_thumbprint_socket(socket, ref, host, opts) do
    certs = collect_certs(ref, [])

    with :ok <- Maxio.IAM.OIDCThumbprint.hostname_matches?(certs, host),
         {:ok, selected} <- Maxio.IAM.OIDCThumbprint.top_intermediate_or_leaf(certs),
         :ok <- configured_thumbprint_allowed?(selected.der, opts) do
      :ok
    else
      # 三个 `with` 步骤的返回**值形状**穷尽为 `:ok | {:ok, _} | {:error, atom()}`，`{:error, reason}`
      # 已覆盖全部可进入 `else` 的形状，故 `_other` 兜底是纯死代码。（依据是值形状而非异常防护：
      # `hostname_matches?/2` 确有 rescue+catch，但 `top_intermediate_or_leaf/1` 两者都没有；
      # 而 `else` 子句本来就接不到异常。）
      # 删除还是**净改进**：本函数真实的失败通道是异常，由下面的 `rescue` 接管，而 `rescue`
      # 会 `:ssl.close(socket)`，被删的 `_other` 分支直接返回、**不关 socket** —— 少一条泄漏路径。
      {:error, reason} -> {:error, reason}
    end
  rescue
    _error ->
      :ssl.close(socket)
      {:error, :oidc_discovery_http_error}
  end

  defp collect_certs(ref, acc) do
    receive do
      {^ref, :cert, cert} -> collect_certs(ref, acc ++ [cert])
    after
      0 -> acc
    end
  end

  defp send_thumbprint_request(socket, uri) do
    request = [
      "GET ",
      request_target(uri),
      " HTTP/1.1\r\n",
      "Host: ",
      host_header(uri),
      "\r\nAccept: application/json\r\nUser-Agent: maxio-oidc-discovery\r\nConnection: close\r\n\r\n"
    ]

    case :ssl.send(socket, request) do
      :ok -> :ok
      {:error, _reason} -> {:error, :oidc_discovery_http_error}
    end
  end

  defp recv_thumbprint_response(socket, limit, timeout) do
    recv_thumbprint_response(socket, "", limit + 16_384, timeout)
  end

  defp recv_thumbprint_response(socket, acc, cap, timeout) do
    case :ssl.recv(socket, 0, timeout) do
      {:ok, data} ->
        next = acc <> data

        if byte_size(next) > cap do
          {:error, :oidc_discovery_response_too_large}
        else
          recv_thumbprint_response(socket, next, cap, timeout)
        end

      {:error, :closed} ->
        parse_http_response(acc, cap - 16_384)

      {:error, _reason} ->
        {:error, :oidc_discovery_http_error}
    end
  end

  defp parse_http_response(raw, limit) do
    with [head, body] <- :binary.split(raw, "\r\n\r\n"),
         {:ok, status} <- status_code(head),
         true <- status == 200,
         {:ok, headers} <- response_headers(head),
         {:ok, body} <- response_body(body, headers, limit) do
      {:ok, body}
    else
      false -> {:error, :oidc_discovery_http_error}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :oidc_discovery_http_error}
    end
  end

  defp status_code(head) do
    head
    |> String.split("\r\n", parts: 2)
    |> List.first("")
    |> String.split(" ", parts: 3)
    |> case do
      ["HTTP/" <> _version, code | _rest] ->
        case Integer.parse(code) do
          {status, ""} -> {:ok, status}
          _other -> {:error, :oidc_discovery_http_error}
        end

      _other ->
        {:error, :oidc_discovery_http_error}
    end
  end

  defp response_headers(head) do
    [_status | headers] = String.split(head, "\r\n")

    headers =
      Enum.reduce(headers, %{}, fn header, acc ->
        case String.split(header, ":", parts: 2) do
          [name, value] -> Map.put(acc, String.downcase(String.trim(name)), String.trim(value))
          _other -> acc
        end
      end)

    {:ok, headers}
  rescue
    _error -> {:error, :oidc_discovery_http_error}
  end

  defp response_body(body, headers, limit) do
    transfer_encoding = headers |> Map.get("transfer-encoding", "") |> String.downcase()

    cond do
      String.contains?(transfer_encoding, "chunked") ->
        decode_chunked_body(body, limit)

      byte_size(body) > limit ->
        {:error, :oidc_discovery_response_too_large}

      true ->
        {:ok, body}
    end
  end

  defp decode_chunked_body(body, limit), do: decode_chunked_body(body, "", limit)

  defp decode_chunked_body(body, acc, limit) do
    with [line, rest] <- :binary.split(body, "\r\n"),
         {:ok, size} <- chunk_size(line),
         true <- byte_size(rest) >= size + 2 do
      cond do
        size == 0 ->
          {:ok, acc}

        byte_size(acc) + size > limit ->
          {:error, :oidc_discovery_response_too_large}

        true ->
          <<chunk::binary-size(^size), "\r\n", tail::binary>> = rest
          decode_chunked_body(tail, acc <> chunk, limit)
      end
    else
      {:error, reason} -> {:error, reason}
      _other -> {:error, :oidc_discovery_http_error}
    end
  end

  defp chunk_size(line) do
    line
    |> String.split(";", parts: 2)
    |> List.first("")
    |> String.trim()
    |> Integer.parse(16)
    |> case do
      {size, ""} when size >= 0 -> {:ok, size}
      _other -> {:error, :oidc_discovery_http_error}
    end
  end

  defp decode_json_body(body) when is_binary(body) do
    with {:ok, decoded} <- Jason.decode(body),
         true <- is_map(decoded) do
      {:ok, decoded}
    else
      {:error, _reason} -> {:error, :oidc_discovery_malformed_json}
      _other -> {:error, :oidc_discovery_malformed_json}
    end
  end

  defp https_uri(url) do
    uri = URI.parse(url)

    cond do
      uri.scheme != "https" -> {:error, :oidc_discovery_http_error}
      not is_binary(uri.host) or uri.host == "" -> {:error, :oidc_discovery_http_error}
      is_binary(uri.userinfo) -> {:error, :oidc_discovery_http_error}
      true -> {:ok, %URI{uri | port: uri.port || 443}}
    end
  rescue
    _error -> {:error, :oidc_discovery_http_error}
  end

  defp request_target(%URI{path: nil, query: nil}), do: "/"
  defp request_target(%URI{path: "", query: nil}), do: "/"

  defp request_target(%URI{path: path, query: nil}) when path in [nil, ""], do: "/"
  defp request_target(%URI{path: path, query: nil}), do: path

  defp request_target(%URI{path: path, query: query}) when path in [nil, ""],
    do: "/?" <> query

  defp request_target(%URI{path: path, query: query}), do: path <> "?" <> query

  defp host_header(%URI{host: host, port: 443}), do: host
  defp host_header(%URI{host: host, port: port}), do: "#{host}:#{port}"

  defp configured_thumbprint_allowed?(der, opts) do
    configured = MapSet.new(configured_thumbprints(opts))

    if MapSet.member?(configured, sha1_hex(der)) do
      :ok
    else
      {:error, :oidc_discovery_thumbprint_mismatch}
    end
  end

  defp configured_thumbprints(opts) do
    opts
    |> Keyword.get(:thumbprints, [])
    |> List.wrap()
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&String.downcase/1)
    |> Enum.uniq()
  end

  defp thumbprint_trust_fallback_reason?({:bad_cert, reason}),
    do: thumbprint_trust_fallback_reason?(reason)

  defp thumbprint_trust_fallback_reason?(reason)
       when reason in [:unknown_ca, :selfsigned_peer, :issuer_not_found, :invalid_issuer],
       do: true

  defp thumbprint_trust_fallback_reason?(_reason), do: false

  defp sha1_hex(der), do: :crypto.hash(:sha, der) |> Base.encode16(case: :lower)

  defp validate_discovery_issuer(%{"issuer" => issuer}, issuer), do: :ok

  defp validate_discovery_issuer(_discovery, _issuer),
    do: {:error, :oidc_discovery_issuer_mismatch}

  defp jwks_uri(%{"jwks_uri" => uri}) when is_binary(uri) do
    case Maxio.STS.WebIdentity.issuer_host_path(uri) do
      {:ok, _host_path} -> {:ok, uri}
      {:error, _reason} -> {:error, :oidc_discovery_invalid_jwks_uri}
    end
  end

  defp jwks_uri(_discovery), do: {:error, :oidc_discovery_invalid_jwks_uri}

  defp validate_jwks(%{"keys" => keys}) when is_list(keys) and keys != [] do
    if Enum.all?(keys, &valid_jwk?/1), do: :ok, else: {:error, :identity_provider_keys_malformed}
  end

  defp validate_jwks(_jwks), do: {:error, :identity_provider_keys_missing}

  defp tls_thumbprints(urls, opts) do
    thumbprint_module = Keyword.get(opts, :thumbprint_module, Maxio.IAM.OIDCThumbprint)

    thumbprint_opts =
      opts
      |> Keyword.get(:thumbprint_opts, [])
      |> Keyword.put_new(:timeout_ms, Keyword.get(opts, :timeout_ms, @timeout_ms))

    thumbprint_opts =
      case configured_thumbprints(opts) do
        [] -> thumbprint_opts
        thumbprints -> Keyword.put(thumbprint_opts, :thumbprints, thumbprints)
      end

    with true <- is_atom(thumbprint_module),
         {:module, ^thumbprint_module} <- Code.ensure_loaded(thumbprint_module),
         true <- function_exported?(thumbprint_module, :thumbprints_for_urls, 2) do
      thumbprint_module.thumbprints_for_urls(urls, thumbprint_opts)
    else
      _other -> {:error, :oidc_discovery_tls_thumbprint_failed}
    end
  end

  defp valid_jwk?(%{} = jwk) do
    _jwk = JOSE.JWK.from_map(jwk)
    true
  rescue
    _error -> false
  catch
    _class, _reason -> false
  end

  defp valid_jwk?(_jwk), do: false
end
