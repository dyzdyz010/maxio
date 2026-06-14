defmodule Maxio.IAM.TOTPTest do
  use ExUnit.Case, async: true

  alias Maxio.IAM.TOTP

  @rfc_sha1_secret "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"

  test "generates RFC 6238 SHA1 vectors with 8 digits" do
    assert {:ok, "94287082"} = TOTP.code(@rfc_sha1_secret, time: 59, digits: 8)
    assert {:ok, "07081804"} = TOTP.code(@rfc_sha1_secret, time: 1_111_111_109, digits: 8)
    assert {:ok, "14050471"} = TOTP.code(@rfc_sha1_secret, time: 1_111_111_111, digits: 8)
    assert {:ok, "89005924"} = TOTP.code(@rfc_sha1_secret, time: 1_234_567_890, digits: 8)
    assert {:ok, "69279037"} = TOTP.code(@rfc_sha1_secret, time: 2_000_000_000, digits: 8)
    assert {:ok, "65353130"} = TOTP.code(@rfc_sha1_secret, time: 20_000_000_000, digits: 8)
  end

  test "accepts codes inside the configured drift window only" do
    secret = TOTP.generate_secret()
    issued_at = 1_800
    assert {:ok, code} = TOTP.code(secret, time: issued_at)

    assert :ok = TOTP.verify(secret, code, time: issued_at + 30, drift_steps: 1)

    assert {:error, :totp_code_mismatch} =
             TOTP.verify(secret, code, time: issued_at + 60, drift_steps: 1)
  end

  test "rejects malformed secrets and codes" do
    assert {:error, :invalid_totp_secret} = TOTP.code("not-base32!", time: 0)
    assert {:error, :invalid_totp_code} = TOTP.verify(@rfc_sha1_secret, "12345", time: 59)
    assert {:error, :invalid_totp_code} = TOTP.verify(@rfc_sha1_secret, "abcdef", time: 59)
  end

  test "verification URI contains the expected otpauth parameters" do
    secret = TOTP.generate_secret()
    uri = TOTP.verification_uri(secret, issuer: "maxio", label: "root")

    assert uri =~ "otpauth://totp/maxio%3Aroot?"
    assert uri =~ "secret=#{secret}"
    assert uri =~ "issuer=maxio"
    assert uri =~ "algorithm=SHA1"
    assert uri =~ "digits=6"
    assert uri =~ "period=30"
  end
end
