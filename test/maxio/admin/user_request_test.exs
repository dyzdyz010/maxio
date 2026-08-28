defmodule Maxio.Admin.UserRequestTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Plug.Conn
  import Plug.Test

  alias Maxio.Admin.{Envelope, UserRequest}
  alias Maxio.Auth.SigningSecret
  alias Maxio.Auth.SigV4.Signer
  alias Maxio.S3.Error

  @max_encrypted_size 262_272

  setup do
    secret = SigningSecret.new("request-signing-secret")
    {:ok, secret: secret}
  end

  test "accepts a valid encrypted request without requiring Content-Type", %{secret: secret} do
    body = encrypted_body(secret, valid_json())

    {conn, request} = UserRequest.read_add_body!(request_conn(body), secret)

    assert conn.state == :unset
    assert request == %{secret_key: "12345678", policy: "", status: "enabled"}
  end

  test "ignores arbitrary Content-Type for the encrypted control body", %{secret: secret} do
    body = encrypted_body(secret, valid_json())
    conn = request_conn(body, headers: [{"content-type", "application/octet-stream; x=maxio"}])

    assert {_conn, %{secret_key: "12345678"}} = UserRequest.read_add_body!(conn, secret)
  end

  test "exact lower and upper encrypted length boundaries reach validation", %{secret: secret} do
    for body <- [<<0>>, oversized_envelope(@max_encrypted_size)] do
      assert_error(
        fn -> UserRequest.read_add_body!(request_conn(body), secret) end,
        "XMinioAdminConfigBadJSON"
      )
    end

    too_large = :binary.copy(<<0>>, @max_encrypted_size + 1)

    assert_error(
      fn -> UserRequest.read_add_body!(request_conn(too_large), secret) end,
      "XMinioAdminConfigTooLarge"
    )
  end

  test "missing, ambiguous, negative, chunked, and non-canonical lengths are too large", %{
    secret: secret
  } do
    body = <<0>>

    conns = [
      request_conn(body, content_length: :absent),
      request_conn(body, content_length: ["1", "1"]),
      request_conn(body, content_length: "-1"),
      request_conn(body, content_length: :absent, headers: [{"transfer-encoding", "chunked"}]),
      request_conn(body, content_length: "+1"),
      request_conn(body, content_length: "１"),
      request_conn(body, content_length: " 1"),
      request_conn(body, content_length: "1 ")
    ]

    for conn <- conns do
      assert_error(
        fn -> UserRequest.read_add_body!(conn, secret) end,
        "XMinioAdminConfigTooLarge"
      )
    end
  end

  test "zero and declared/read length mismatch are bad JSON", %{secret: secret} do
    assert_error(
      fn -> UserRequest.read_add_body!(request_conn(<<>>, content_length: "0"), secret) end,
      "XMinioAdminConfigBadJSON"
    )

    assert_error(
      fn -> UserRequest.read_add_body!(request_conn(<<0>>, content_length: "2"), secret) end,
      "XMinioAdminConfigBadJSON"
    )
  end

  test "authenticated ciphertext hash is checked before decrypt", %{secret: secret} do
    body = encrypted_body(secret, valid_json())

    conn =
      request_conn(body,
        signed_payload_sha256: Signer.hex_sha256("different-ciphertext")
      )

    assert_error(
      fn -> UserRequest.read_add_body!(conn, secret) end,
      "XAmzContentSHA256Mismatch"
    )
  end

  test "wrong credentials and unsupported, tampered, or truncated envelopes are bad JSON", %{
    secret: secret
  } do
    body = encrypted_body(secret, valid_json())
    wrong = SigningSecret.new("wrong-signing-secret")

    <<prefix::binary-size(50), byte, suffix::binary>> = body
    tampered = prefix <> <<Bitwise.bxor(byte, 1)>> <> suffix
    <<salt::binary-size(32), _id, rest::binary>> = body
    unsupported = salt <> <<255>> <> rest

    for {credential, invalid_body} <- [
          {wrong, body},
          {secret, unsupported},
          {secret, tampered},
          {secret, binary_part(body, 0, byte_size(body) - 1)}
        ] do
      assert_error(
        fn -> UserRequest.read_add_body!(request_conn(invalid_body), credential) end,
        "XMinioAdminConfigBadJSON"
      )
    end
  end

  test "malformed shape, unknown keys, unsupported status, and policy are bad JSON", %{
    secret: secret
  } do
    invalid_plaintexts = [
      "not-json",
      Jason.encode!(%{"secretKey" => "12345678", "status" => "enabled", "unknown" => true}),
      Jason.encode!(%{"secretKey" => "12345678", "status" => "disabled"}),
      Jason.encode!(%{"secretKey" => "12345678", "status" => "enabled", "policy" => "rw"}),
      Jason.encode!(%{"secretKey" => "12345678"})
    ]

    for plaintext <- invalid_plaintexts do
      body = encrypted_body(secret, plaintext)

      assert_error(
        fn -> UserRequest.read_add_body!(request_conn(body), secret) end,
        "XMinioAdminConfigBadJSON"
      )
    end
  end

  test "missing, empty, and seven-byte secrets have the exact secret-key error", %{secret: secret} do
    plaintexts = [
      Jason.encode!(%{"status" => "enabled"}),
      Jason.encode!(%{"secretKey" => "", "status" => "enabled"}),
      Jason.encode!(%{"secretKey" => "1234567", "status" => "enabled"})
    ]

    for plaintext <- plaintexts do
      body = encrypted_body(secret, plaintext)

      assert_error(
        fn -> UserRequest.read_add_body!(request_conn(body), secret) end,
        "XMinioAdminInvalidSecretKey"
      )
    end
  end

  test "failure terms and logs do not expose encrypted or plaintext request material", %{
    secret: secret
  } do
    plaintext = Jason.encode!(%{"secretKey" => "new-secret-sentinel", "status" => "disabled"})
    ciphertext = encrypted_body(secret, plaintext)

    log =
      capture_log(fn ->
        error =
          assert_raise Error, fn ->
            UserRequest.read_add_body!(request_conn(ciphertext), secret)
          end

        inspected = inspect(error)
        refute inspected =~ plaintext
        refute inspected =~ "new-secret-sentinel"
        refute inspected =~ Base.encode16(binary_part(ciphertext, 0, 16))
      end)

    refute log =~ plaintext
    refute log =~ "new-secret-sentinel"
  end

  defp valid_json,
    do: Jason.encode!(%{"secretKey" => "12345678", "status" => "enabled"})

  defp encrypted_body(secret, plaintext) do
    {:ok, envelope} =
      Envelope.encrypt(secret, plaintext,
        algorithm_id: 2,
        salt: :binary.copy(<<7>>, 32),
        nonce: :binary.copy(<<9>>, 8)
      )

    envelope
  end

  defp oversized_envelope(size) do
    :binary.copy(<<0>>, 32) <> <<255>> <> :binary.copy(<<0>>, size - 33)
  end

  defp request_conn(body, opts \\ []) do
    content_length = Keyword.get(opts, :content_length, Integer.to_string(byte_size(body)))

    conn =
      :put
      |> conn("/minio/admin/v3/add-user", body)
      |> delete_req_header("content-length")
      |> assign(:payload_mode, :single)
      |> assign(:sigv4_context, %{
        signed_payload_sha256: Keyword.get(opts, :signed_payload_sha256, Signer.hex_sha256(body))
      })

    conn =
      case content_length do
        :absent ->
          conn

        values when is_list(values) ->
          %{conn | req_headers: Enum.map(values, &{"content-length", &1}) ++ conn.req_headers}

        value ->
          put_req_header(conn, "content-length", value)
      end

    Enum.reduce(Keyword.get(opts, :headers, []), conn, fn {name, value}, acc ->
      put_req_header(acc, name, value)
    end)
  end

  defp assert_error(callback, code) do
    error = assert_raise Error, callback
    assert error.code == code
    error
  end
end
