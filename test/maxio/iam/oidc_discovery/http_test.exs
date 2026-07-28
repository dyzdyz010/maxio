defmodule Maxio.IAM.OIDCDiscovery.HTTPTest do
  use ExUnit.Case, async: false

  alias Maxio.IAM.OIDCDiscovery.HTTP

  test "discovers private CA OIDC endpoints when ThumbprintList matches" do
    jwk = JOSE.JWK.generate_key({:rsa, 2048})
    jwks = public_jwks(jwk)
    {issuer, thumbprint} = start_oidc_tls_server(jwks)

    assert {:ok, discovery} =
             HTTP.discover(issuer, thumbprints: [String.upcase(thumbprint)], timeout_ms: 2_000)

    assert discovery.discovery_document["issuer"] == issuer
    assert discovery.discovery_document["jwks_uri"] == issuer <> "/keys"
    assert discovery.jwks == jwks
    assert discovery.thumbprints == [thumbprint]
  end

  test "rejects private CA OIDC endpoints when ThumbprintList does not match" do
    jwk = JOSE.JWK.generate_key({:rsa, 2048})
    {issuer, _thumbprint} = start_oidc_tls_server(public_jwks(jwk))

    assert {:error, :oidc_discovery_thumbprint_mismatch} =
             HTTP.discover(issuer, thumbprints: [sha1_hex("wrong-ca")], timeout_ms: 2_000)
  end

  test "does not treat ThumbprintList as a hostname verification bypass" do
    jwk = JOSE.JWK.generate_key({:rsa, 2048})
    wrong_host = wrong_hostname(certificate_hostname())
    {issuer, thumbprint} = start_oidc_tls_server(public_jwks(jwk), issuer_host: wrong_host)

    assert {:error, :oidc_discovery_http_error} =
             HTTP.discover(issuer, thumbprints: [thumbprint], timeout_ms: 2_000)
  end

  test "Req discovery fetch disables automatic redirects and fails closed on redirect responses" do
    parent = self()

    req_request = fn opts ->
      send(parent, {:req_options, opts})
      {:ok, %Req.Response{status: 302, private: %{}}}
    end

    assert {:error, :oidc_discovery_http_error} =
             HTTP.discover("https://issuer.example.test",
               req_request_fun: req_request,
               timeout_ms: 2_000
             )

    assert_receive {:req_options, opts}
    assert opts[:redirect] == false
  end

  test "thumbprint fallback discovery fetch rejects redirect responses" do
    jwk = JOSE.JWK.generate_key({:rsa, 2048})
    {issuer, thumbprint} = start_oidc_tls_server(public_jwks(jwk), discovery_status: 302)

    assert {:error, :oidc_discovery_http_error} =
             HTTP.discover(issuer, thumbprints: [thumbprint], timeout_ms: 2_000)
  end

  defp start_oidc_tls_server(jwks, opts \\ []) do
    Application.ensure_all_started(:ssl)
    Application.ensure_all_started(:public_key)

    chain =
      :public_key.pkix_test_data(%{
        root: [key: {:rsa, 2048, 65_537}],
        peer: [key: {:rsa, 2048, 65_537}]
      })

    cert = Keyword.fetch!(chain, :cert)
    key = Keyword.fetch!(chain, :key)

    {:ok, listen} =
      :ssl.listen(0,
        cert: cert,
        key: key,
        active: false,
        mode: :binary,
        reuseaddr: true
      )

    {:ok, {_addr, port}} = :ssl.sockname(listen)
    issuer_host = Keyword.get(opts, :issuer_host, certificate_hostname())
    issuer = "https://#{issuer_host}:#{port}"

    discovery_document = %{
      "issuer" => issuer,
      "jwks_uri" => issuer <> "/keys"
    }

    discovery_status = Keyword.get(opts, :discovery_status, 200)

    start_supervised!(
      {Task, fn -> serve_oidc_tls(listen, discovery_document, jwks, discovery_status) end}
    )

    on_exit(fn -> :ssl.close(listen) end)

    {issuer, sha1_hex(cert)}
  end

  defp certificate_hostname, do: :net_adm.localhost() |> to_string()

  defp wrong_hostname("localhost"), do: "127.0.0.1"
  defp wrong_hostname(_certificate_hostname), do: "localhost"

  defp serve_oidc_tls(listen, discovery_document, jwks, discovery_status) do
    case :ssl.transport_accept(listen, 1_000) do
      {:ok, socket} ->
        handle_oidc_tls_socket(socket, discovery_document, jwks, discovery_status)
        serve_oidc_tls(listen, discovery_document, jwks, discovery_status)

      {:error, :closed} ->
        :ok

      {:error, :timeout} ->
        serve_oidc_tls(listen, discovery_document, jwks, discovery_status)

      {:error, _reason} ->
        :ok
    end
  end

  defp handle_oidc_tls_socket(socket, discovery_document, jwks, discovery_status) do
    case :ssl.handshake(socket, 1_000) do
      {:ok, socket} ->
        socket
        |> recv_request_path()
        |> response_for_path(discovery_document, jwks, discovery_status)
        |> send_response(socket)

        :ssl.close(socket)

      {:error, _reason} ->
        :ssl.close(socket)
    end
  end

  defp recv_request_path(socket) do
    case :ssl.recv(socket, 0, 1_000) do
      {:ok, request} ->
        request
        |> String.split("\r\n", parts: 2)
        |> List.first("")
        |> String.split(" ", parts: 3)
        |> case do
          ["GET", path, "HTTP/" <> _version] -> path
          _other -> :no_request
        end

      {:error, _reason} ->
        :no_request
    end
  end

  defp response_for_path("/.well-known/openid-configuration", discovery_document, _jwks, status),
    do: {status, discovery_document}

  defp response_for_path("/keys", _discovery_document, jwks, _status), do: {200, jwks}

  defp response_for_path(_path, _discovery_document, _jwks, _status),
    do: {404, %{"error" => "not_found"}}

  defp send_response({status, body}, socket) do
    body = Jason.encode!(body)

    response = [
      "HTTP/1.1 ",
      Integer.to_string(status),
      " OK\r\ncontent-type: application/json\r\ncontent-length: ",
      Integer.to_string(byte_size(body)),
      "\r\nconnection: close\r\n\r\n",
      body
    ]

    :ssl.send(socket, response)
  end

  defp public_jwks(jwk) do
    {_metadata, public_jwk} = JOSE.JWK.to_public_map(jwk)
    %{"keys" => [Map.put(public_jwk, "kid", "maxio-test")]}
  end

  defp sha1_hex(value), do: :crypto.hash(:sha, value) |> Base.encode16(case: :lower)
end
