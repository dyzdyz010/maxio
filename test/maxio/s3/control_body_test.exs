defmodule Maxio.S3.ControlBodyTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias Maxio.Auth.SigV4.Signer
  alias Maxio.S3.{ControlBody, Error}

  test "opt-in expected length and authenticated payload hash return only a verified body" do
    body = "verified-control-body"
    conn = control_conn(body)

    assert {_conn, ^body, %{}} =
             ControlBody.read!(conn, 100, "too large",
               expected_length: byte_size(body),
               length_mismatch_error: :admin_config_bad_json,
               verify_payload_sha256: Signer.hex_sha256(body)
             )
  end

  test "a length mismatch wins before a simultaneously malformed payload hash" do
    error =
      assert_raise Error, fn ->
        ControlBody.read!(control_conn("short"), 100, "too large",
          expected_length: 6,
          length_mismatch_error: :admin_config_bad_json,
          verify_payload_sha256: "not-a-concrete-sha256"
        )
      end

    assert error.code == "XMinioAdminConfigBadJSON"
    refute error.code == "XAmzContentSHA256Mismatch"
  end

  test "a concrete lowercase authenticated payload hash must match the read bytes" do
    for expected <- [
          String.duplicate("0", 64),
          String.duplicate("A", 64),
          nil,
          "UNSIGNED-PAYLOAD"
        ] do
      error =
        assert_raise Error, fn ->
          ControlBody.read!(control_conn("body"), 100, "too large",
            expected_length: 4,
            length_mismatch_error: :admin_config_bad_json,
            verify_payload_sha256: expected
          )
        end

      assert error.code == "XAmzContentSHA256Mismatch"
    end
  end

  test "malformed opt-in lengths fail without returning the body" do
    for expected <- [nil, "4", -1] do
      error =
        assert_raise Error, fn ->
          ControlBody.read!(control_conn("body"), 100, "too large",
            expected_length: expected,
            length_mismatch_error: :admin_config_bad_json,
            verify_payload_sha256: Signer.hex_sha256("body")
          )
        end

      assert error.code == "XMinioAdminConfigBadJSON"
    end
  end

  test "an over-limit body keeps the caller's error mapping before length and hash checks" do
    error =
      assert_raise Error, fn ->
        ControlBody.read!(control_conn("12345"), 4, "admin config body too large",
          too_large_error: :admin_config_too_large,
          expected_length: 4,
          length_mismatch_error: :admin_config_bad_json,
          verify_payload_sha256: String.duplicate("0", 64)
        )
      end

    assert error.code == "XMinioAdminConfigTooLarge"
    assert error.http_status == 400
    assert error.message == "admin config body too large"
  end

  test "existing callers remain unchanged when verification options are absent" do
    assert {_conn, "legacy", %{}} =
             ControlBody.read!(control_conn("legacy"), 100, "too large")
  end

  defp control_conn(body) do
    :put
    |> conn("/control", body)
    |> assign(:payload_mode, :single)
  end
end
