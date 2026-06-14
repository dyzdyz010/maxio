defmodule Maxio.S3.SessionTokenTest do
  use Maxio.DataCase, async: false

  import Plug.Conn

  alias Maxio.Auth.CredentialStore.MemoryStore
  alias Maxio.S3.Endpoint
  alias Maxio.Test.SigV4Request

  setup do
    MemoryStore.invalidate(:all)
    :ok
  end

  defp call(conn), do: Endpoint.call(conn, Endpoint.init([]))

  test "header-auth temporary credentials can access S3 when token is signed" do
    creds = put_temp_credential()
    bucket = unique_bucket("stsh")

    put_bucket =
      SigV4Request.signed_conn(:put, "/#{bucket}",
        access_key: creds.access_key,
        secret: creds.secret_key,
        session_token: creds.session_token
      )
      |> call()

    assert put_bucket.status == 200

    list_bucket =
      SigV4Request.signed_conn(:get, "/#{bucket}",
        query: %{"list-type" => "2"},
        access_key: creds.access_key,
        secret: creds.secret_key,
        session_token: creds.session_token
      )
      |> call()

    assert list_bucket.status == 200
  end

  test "missing or wrong session token returns InvalidToken" do
    creds = put_temp_credential()

    missing =
      SigV4Request.signed_conn(:put, "/#{unique_bucket("stsm")}",
        access_key: creds.access_key,
        secret: creds.secret_key
      )
      |> call()

    assert missing.status == 400
    assert missing.resp_body =~ "<Code>InvalidToken</Code>"

    wrong =
      SigV4Request.signed_conn(:put, "/#{unique_bucket("stsw")}",
        access_key: creds.access_key,
        secret: creds.secret_key,
        session_token: "wrong-token"
      )
      |> call()

    assert wrong.status == 400
    assert wrong.resp_body =~ "<Code>InvalidToken</Code>"
  end

  test "session token header must be part of SignedHeaders" do
    creds = put_temp_credential()

    conn =
      SigV4Request.signed_conn(:put, "/#{unique_bucket("stsu")}",
        access_key: creds.access_key,
        secret: creds.secret_key
      )
      |> put_req_header("x-amz-security-token", creds.session_token)
      |> call()

    assert conn.status == 400
    assert conn.resp_body =~ "<Code>AccessDenied</Code>"
  end

  test "mixed-case SignedHeaders token still participates in canonical request" do
    creds = put_temp_credential()

    conn =
      SigV4Request.signed_conn(:put, "/#{unique_bucket("stscase")}",
        access_key: creds.access_key,
        secret: creds.secret_key,
        signed_headers_transform: &(&1 <> ";X-Amz-Security-Token")
      )
      |> put_req_header("x-amz-security-token", creds.session_token)
      |> call()

    assert conn.status == 403
    assert conn.resp_body =~ "<Code>SignatureDoesNotMatch</Code>"
  end

  test "presigned temporary credentials require X-Amz-Security-Token query parameter" do
    creds = put_temp_credential()
    bucket = unique_bucket("stsp")

    SigV4Request.signed_conn(:put, "/#{bucket}",
      access_key: creds.access_key,
      secret: creds.secret_key,
      session_token: creds.session_token
    )
    |> call()

    presigned =
      SigV4Request.presigned_conn(:get, "/#{bucket}",
        query: %{"list-type" => "2"},
        access_key: creds.access_key,
        secret: creds.secret_key,
        session_token: creds.session_token
      )
      |> call()

    assert presigned.status == 200

    missing_token =
      SigV4Request.presigned_conn(:get, "/#{bucket}",
        query: %{"list-type" => "2"},
        access_key: creds.access_key,
        secret: creds.secret_key
      )
      |> call()

    assert missing_token.status == 400
    assert missing_token.resp_body =~ "<Code>InvalidToken</Code>"
  end

  test "expired session token fails before object write" do
    creds = put_temp_credential(expires_at: DateTime.add(DateTime.utc_now(), -1, :second))

    conn =
      SigV4Request.signed_conn(:put, "/#{unique_bucket("stse")}",
        access_key: creds.access_key,
        secret: creds.secret_key,
        session_token: creds.session_token
      )
      |> call()

    assert conn.status == 400
    assert conn.resp_body =~ "<Code>ExpiredToken</Code>"
  end

  test "aws-chunked temporary credential upload succeeds with signed token" do
    creds = put_temp_credential()
    bucket = unique_bucket("stsc")

    SigV4Request.signed_conn(:put, "/#{bucket}",
      access_key: creds.access_key,
      secret: creds.secret_key,
      session_token: creds.session_token
    )
    |> call()

    put_object =
      SigV4Request.signed_chunked_conn(:put, "/#{bucket}/stream.txt", "hello",
        access_key: creds.access_key,
        secret: creds.secret_key,
        session_token: creds.session_token
      )
      |> call()

    assert put_object.status == 200
  end

  defp put_temp_credential(opts \\ []) do
    access_key = "ASIATEST#{System.unique_integer([:positive])}"
    secret_key = "tempsecret#{System.unique_integer([:positive])}"
    session_token = "token-#{System.unique_integer([:positive])}"
    expires_at = Keyword.get(opts, :expires_at, DateTime.add(DateTime.utc_now(), 900, :second))

    :ok =
      MemoryStore.put_access_key(%{
        access_key: access_key,
        secret_key: secret_key,
        session_token: session_token,
        expires_at: expires_at,
        principal: %{
          type: :root,
          access_key: SigV4Request.access_key(),
          arn: "arn:aws:iam:::root",
          tags: %{}
        }
      })

    %{access_key: access_key, secret_key: secret_key, session_token: session_token}
  end

  defp unique_bucket(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
