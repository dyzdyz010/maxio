defmodule Maxio.Admin.ConfigKV.RequestTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Plug.Conn
  import Plug.Test

  alias Maxio.Admin.ConfigKV.Request
  alias Maxio.Admin.Envelope
  alias Maxio.Auth.SigningSecret
  alias Maxio.S3.Error

  @max_encrypted_size 262_272
  @too_large_message "Configuration data provided exceeds the allowed maximum of 262272 bytes"
  @bad_json_message "JSON configuration provided is of incorrect format"
  @hash_mismatch_message "The provided 'x-amz-content-sha256' header does not match what was computed."

  @empty_sha256 "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
  @max_boundary_sha256 "b06c04c2b160eaee276e7debc14420428d4632774d6e87becdede02585d35206"

  @oracle_secret "maxio-madmin-v3.0.109-public-fixture-password"
  @oracle_plaintext <<0x11>>
  @oracle_ciphertext Base.decode16!(
                       "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f022021222324252627e5f748928e082fdabd5572ea0cdc193119",
                       case: :lower
                     )
  @oracle_ciphertext_sha256 "c95fbc75bff7166916815a3b88944eced2f63d1c6c784139916d252506f39af6"

  test "one ASCII decimal Content-Length is accepted through the inclusive maximum" do
    for {header, expected} <- [{"0", 0}, {"58", 58}, {"262272", 262_272}] do
      conn = mutation_conn(<<>>, content_length: header)

      assert Request.declared_mutation_length!(conn) == expected
    end
  end

  test "missing, duplicate, negative, non-decimal, and overflowing lengths are TooLarge" do
    invalid_lengths = [
      :absent,
      ["58", "58"],
      "-1",
      "+1",
      "1.0",
      " 1",
      "1 ",
      "１",
      "262273",
      String.duplicate("9", 80)
    ]

    for content_length <- invalid_lengths do
      error =
        assert_raise Error, fn ->
          mutation_conn(<<>>, content_length: content_length)
          |> Request.declared_mutation_length!()
        end

      assert_admin_error(error, "XMinioAdminConfigTooLarge", @too_large_message)
    end
  end

  test "any Transfer-Encoding presence is TooLarge even with a valid Content-Length" do
    transfer_encodings = [
      [{"transfer-encoding", "chunked"}],
      [{"transfer-encoding", "identity"}],
      [{"transfer-encoding", ""}],
      [{"transfer-encoding", "gzip"}, {"transfer-encoding", "chunked"}]
    ]

    for headers <- transfer_encodings do
      error =
        assert_raise Error, fn ->
          mutation_conn(<<>>, content_length: "0", headers: headers)
          |> Request.declared_mutation_length!()
        end

      assert_admin_error(error, "XMinioAdminConfigTooLarge", @too_large_message)
    end
  end

  test "Content-Length zero reaches envelope decryption and becomes BadJSON" do
    secret = SigningSecret.new(@oracle_secret)
    conn = mutation_conn(<<>>, content_length: "0", signed_payload_sha256: @empty_sha256)
    declared_length = Request.declared_mutation_length!(conn)

    error =
      assert_raise Error, fn ->
        Request.read_mutation!(conn, secret, declared_length)
      end

    assert_admin_error(error, "XMinioAdminConfigBadJSON", @bad_json_message)
  end

  test "262272 actual ciphertext bytes pass framing and reach envelope decryption" do
    secret = SigningSecret.new(@oracle_secret)
    body = :binary.copy(<<0>>, 32) <> <<255>> <> :binary.copy(<<0>>, @max_encrypted_size - 33)

    conn =
      mutation_conn(body,
        content_length: "262272",
        signed_payload_sha256: @max_boundary_sha256
      )

    declared_length = Request.declared_mutation_length!(conn)

    error =
      assert_raise Error, fn ->
        Request.read_mutation!(conn, secret, declared_length)
      end

    assert_admin_error(error, "XMinioAdminConfigBadJSON", @bad_json_message)
  end

  test "actual-length mismatch precedes hash mismatch, and hash mismatch precedes decrypt" do
    secret = SigningSecret.new(@oracle_secret)

    short_conn =
      mutation_conn(<<0>>,
        content_length: "2",
        signed_payload_sha256: String.duplicate("0", 64)
      )

    declared_length = Request.declared_mutation_length!(short_conn)

    length_error =
      assert_raise Error, fn ->
        Request.read_mutation!(short_conn, secret, declared_length)
      end

    assert_admin_error(length_error, "XMinioAdminConfigBadJSON", @bad_json_message)

    wrong_hash_conn =
      mutation_conn(<<0>>,
        content_length: "1",
        signed_payload_sha256: String.duplicate("0", 64)
      )

    declared_length = Request.declared_mutation_length!(wrong_hash_conn)

    hash_error =
      assert_raise Error, fn ->
        Request.read_mutation!(wrong_hash_conn, secret, declared_length)
      end

    assert_admin_error(hash_error, "XAmzContentSHA256Mismatch", @hash_mismatch_message)
  end

  test "absent, arbitrary, and multiple Content-Type headers do not gate a mutation" do
    secret = SigningSecret.new(@oracle_secret)

    content_type_headers = [
      [],
      [{"content-type", "application/octet-stream; x=maxio"}],
      [{"content-type", "text/plain"}, {"content-type", "application/json"}]
    ]

    for headers <- content_type_headers do
      conn =
        mutation_conn(@oracle_ciphertext,
          content_length: "58",
          signed_payload_sha256: @oracle_ciphertext_sha256,
          headers: headers
        )

      declared_length = Request.declared_mutation_length!(conn)

      assert {_conn, @oracle_plaintext} =
               Request.read_mutation!(conn, secret, declared_length)
    end
  end

  test "a pinned SIO oracle returns opaque plaintext only with the caller secret" do
    caller_secret = SigningSecret.new(@oracle_secret)

    conn =
      mutation_conn(@oracle_ciphertext,
        content_length: "58",
        signed_payload_sha256: @oracle_ciphertext_sha256
      )

    assert {_conn, @oracle_plaintext} = Request.read_mutation!(conn, caller_secret, 58)
  end

  test "wrong, root, and another rotated secret all map decrypt failure to BadJSON" do
    secrets = [
      SigningSecret.new("wrong-caller-secret"),
      SigningSecret.new("configured-root-secret"),
      SigningSecret.new("other-credential-rotated-secret")
    ]

    for secret <- secrets do
      conn =
        mutation_conn(@oracle_ciphertext,
          content_length: "58",
          signed_payload_sha256: @oracle_ciphertext_sha256
        )

      error =
        assert_raise Error, fn ->
          Request.read_mutation!(conn, secret, 58)
        end

      assert_admin_error(error, "XMinioAdminConfigBadJSON", @bad_json_message)
    end
  end

  test "GET encryption round-trips only with the authenticated caller secret" do
    caller_secret = SigningSecret.new("get-caller-secret")
    root_secret = SigningSecret.new("get-root-secret")
    plaintext = "s3 clock_skew_ms=900000\n"

    ciphertext = Request.encrypt_get!(caller_secret, plaintext)

    assert is_binary(ciphertext)
    refute ciphertext == plaintext
    assert {:ok, ^plaintext} = Envelope.decrypt(caller_secret, ciphertext)
    assert {:error, :not_authentic} = Envelope.decrypt(root_secret, ciphertext)
  end

  test "decrypt failure logs expose no ciphertext, plaintext, or secret material" do
    caller_secret_text = "capture-caller-secret-sentinel"
    wrong_secret_text = "capture-wrong-secret-sentinel"
    plaintext = "capture-plaintext-kvs-sentinel"
    caller_secret = SigningSecret.new(caller_secret_text)
    wrong_secret = SigningSecret.new(wrong_secret_text)

    {:ok, ciphertext} =
      Envelope.encrypt(caller_secret, plaintext,
        algorithm_id: 2,
        salt: :binary.copy(<<7>>, 32),
        nonce: :binary.copy(<<9>>, 8)
      )

    ciphertext_sha256 = :crypto.hash(:sha256, ciphertext) |> Base.encode16(case: :lower)

    conn =
      mutation_conn(ciphertext,
        content_length: Integer.to_string(byte_size(ciphertext)),
        signed_payload_sha256: ciphertext_sha256
      )

    log =
      capture_log(fn ->
        error =
          assert_raise Error, fn ->
            Request.read_mutation!(conn, wrong_secret, byte_size(ciphertext))
          end

        assert_admin_error(error, "XMinioAdminConfigBadJSON", @bad_json_message)
      end)

    refute log =~ plaintext
    refute log =~ caller_secret_text
    refute log =~ wrong_secret_text
    refute log =~ ciphertext
    refute log =~ inspect(ciphertext)
    refute log =~ Base.encode16(ciphertext, case: :lower)
  end

  defp mutation_conn(body, opts) do
    content_length = Keyword.fetch!(opts, :content_length)

    conn =
      :put
      |> conn("/minio/admin/v3/set-config-kv", body)
      |> delete_req_header("content-length")
      |> delete_req_header("transfer-encoding")
      |> delete_req_header("content-type")
      |> assign(:payload_mode, :single)
      |> assign(:sigv4_context, %{
        signed_payload_sha256: Keyword.get(opts, :signed_payload_sha256, @empty_sha256)
      })

    conn = put_content_length(conn, content_length)
    %{conn | req_headers: Keyword.get(opts, :headers, []) ++ conn.req_headers}
  end

  defp put_content_length(conn, :absent), do: conn

  defp put_content_length(conn, values) when is_list(values) do
    headers = Enum.map(values, &{"content-length", &1})
    %{conn | req_headers: headers ++ conn.req_headers}
  end

  defp put_content_length(conn, value), do: put_req_header(conn, "content-length", value)

  defp assert_admin_error(error, code, message) do
    assert error.code == code
    assert error.http_status == 400
    assert error.message == message
  end
end
