defmodule Maxio.Crypto.SSETest do
  use ExUnit.Case, async: false
  alias Maxio.KMS
  alias Maxio.Crypto.SSE

  setup do
    prev = Application.get_env(:maxio, :sse)
    prev_kms = Application.get_env(:maxio, :kms)
    key = :crypto.strong_rand_bytes(32) |> Base.encode64()
    Application.put_env(:maxio, :sse, master_key: key)

    Application.put_env(:maxio, :kms,
      provider: Maxio.KMS.LocalProvider,
      default_key_id: "alias/test"
    )

    on_exit(fn ->
      Application.put_env(:maxio, :sse, prev)

      if prev_kms do
        Application.put_env(:maxio, :kms, prev_kms)
      else
        Application.delete_env(:maxio, :kms)
      end
    end)

    :ok
  end

  test "wrap/unwrap 往返还原明文（单块）" do
    plain = "Welcome to Amazon S3 SSE-S3."
    {cipher_stream, envelope} = SSE.wrap_stream([plain])
    cipher = Enum.to_list(cipher_stream) |> IO.iodata_to_binary()
    refute cipher == plain

    out = SSE.unwrap_stream([cipher], envelope) |> Enum.to_list() |> IO.iodata_to_binary()
    assert out == plain
  end

  test "多块流往返（>64KB）" do
    plain = :crypto.strong_rand_bytes(200_000)
    {cipher_stream, envelope} = SSE.wrap_stream([plain])
    cipher = Enum.to_list(cipher_stream) |> IO.iodata_to_binary()

    out = SSE.unwrap_stream([cipher], envelope) |> Enum.to_list() |> IO.iodata_to_binary()
    assert out == plain
  end

  test "unwrap_stream 支持密文帧跨输入 chunk 切分" do
    plain = :crypto.strong_rand_bytes(80_000)
    {cipher_stream, envelope} = SSE.wrap_stream([plain])
    cipher = Enum.to_list(cipher_stream) |> IO.iodata_to_binary()

    split_cipher =
      cipher
      |> :binary.bin_to_list()
      |> Enum.chunk_every(7)
      |> Enum.map(&:erlang.list_to_binary/1)

    out = SSE.unwrap_stream(split_cipher, envelope) |> Enum.to_list() |> IO.iodata_to_binary()
    assert out == plain
  end

  test "篡改密文 → 解密 raise（GCM 认证失败，绝不静默）" do
    {cipher_stream, envelope} = SSE.wrap_stream(["data"])
    cipher = Enum.to_list(cipher_stream) |> IO.iodata_to_binary()

    tampered =
      cipher
      |> :binary.bin_to_list()
      |> List.update_at(-1, &Bitwise.bxor(&1, 0xFF))
      |> :erlang.list_to_binary()

    assert_raise RuntimeError, fn ->
      SSE.unwrap_stream([tampered], envelope) |> Enum.to_list()
    end
  end

  test "SSE-KMS wrap/unwrap uses provider-wrapped data keys" do
    plain = :crypto.strong_rand_bytes(90_000)
    context_b64 = Base.encode64(~s({"bucket":"kms","key":"object"}))

    {cipher_stream, envelope} =
      SSE.wrap_stream_with_kms_key([plain], "alias/test", context_b64, bucket_key_enabled: true)

    cipher = Enum.to_list(cipher_stream) |> IO.iodata_to_binary()
    refute cipher == plain
    assert envelope.mode == "SSE-KMS"
    assert envelope.kms_key_id == "alias/test"
    assert envelope.kms_encryption_context_b64 == context_b64
    assert envelope.bucket_key_enabled == true

    out =
      [cipher]
      |> SSE.unwrap_stream_with_kms_key(envelope)
      |> Enum.to_list()
      |> IO.iodata_to_binary()

    assert out == plain
  end

  test "KMS status declares local compatibility boundary without exposing key material" do
    status = KMS.status()

    assert status.provider == Maxio.KMS.LocalProvider
    assert status.provider_name == "Maxio.KMS.LocalProvider"
    assert status.mode == :local_compat
    assert status.default_key_id == "alias/test"
    assert status.local_provider? == true
    assert status.external_provider? == false
    assert status.production_hsm? == false
    assert status.local_master_key_configured? == true
    assert status.local_named_key_count == 0
    assert status.boundary == "local compatibility provider; not external KMS/HSM"

    master_key = Application.fetch_env!(:maxio, :sse) |> Keyword.fetch!(:master_key)
    refute inspect(status) =~ master_key
  end

  test "first optional KMS callback loads the configured provider before probing exports" do
    provider = Maxio.Test.UnloadedKMSProvider
    Application.put_env(:maxio, :kms, provider: provider)

    _purged? = :code.purge(provider)
    _deleted? = :code.delete(provider)
    refute Code.loaded?(provider)

    assert KMS.default_key_id() == "alias/unloaded-provider"

    status = KMS.status()
    assert status.provider == provider
    assert status.production_hsm? == true
  end

  test "SSE-KMS can encrypt with an existing envelope" do
    plain = :crypto.strong_rand_bytes(32_000)
    context_b64 = Base.encode64(~s({"upload":"mpu"}))
    envelope = SSE.kms_envelope("alias/mpu", context_b64, bucket_key_enabled: true)

    cipher =
      [plain]
      |> SSE.encrypt_stream_with_kms_envelope(envelope)
      |> Enum.to_list()
      |> IO.iodata_to_binary()

    refute cipher == plain

    out =
      [cipher]
      |> SSE.unwrap_stream_with_kms_key(envelope)
      |> Enum.to_list()
      |> IO.iodata_to_binary()

    assert out == plain
  end

  test "DSSE-KMS wrap/unwrap uses two provider-wrapped data keys" do
    plain = :crypto.strong_rand_bytes(140_000)
    context_b64 = Base.encode64(~s({"bucket":"dsse","key":"object"}))

    {cipher_stream, envelope} =
      SSE.wrap_stream_with_dsse_kms_key([plain], "alias/test", context_b64)

    cipher = Enum.to_list(cipher_stream) |> IO.iodata_to_binary()
    refute cipher == plain
    assert envelope.mode == "DSSE-KMS"
    assert envelope.kms_key_id == "alias/test"
    assert envelope.kms_encryption_context_b64 == context_b64
    assert envelope.bucket_key_enabled == false
    assert is_map(envelope.dsse_inner)
    assert is_map(envelope.dsse_outer)
    refute inspect(envelope) =~ "plaintext_key"

    out =
      [cipher]
      |> SSE.unwrap_stream_with_dsse_kms_key(envelope)
      |> Enum.to_list()
      |> IO.iodata_to_binary()

    assert out == plain
  end

  test "DSSE-KMS can encrypt with an existing envelope" do
    plain = :crypto.strong_rand_bytes(90_000)
    context_b64 = Base.encode64(~s({"upload":"dsse-mpu"}))
    envelope = SSE.dsse_kms_envelope("alias/dsse-mpu", context_b64)

    cipher =
      [plain]
      |> SSE.encrypt_stream_with_dsse_kms_envelope(envelope)
      |> Enum.to_list()
      |> IO.iodata_to_binary()

    refute cipher == plain

    out =
      [cipher]
      |> SSE.unwrap_stream_with_dsse_kms_key(envelope)
      |> Enum.to_list()
      |> IO.iodata_to_binary()

    assert out == plain
  end

  test "DSSE-KMS encrypts small metadata with both data keys" do
    envelope = SSE.dsse_kms_envelope("alias/dsse-metadata", nil)
    metadata = %{"ChecksumCRC64NVME" => "local-checksum", "ChecksumType" => "FULL_OBJECT"}

    encrypted = SSE.encrypt_metadata_with_dsse_kms_key(metadata, envelope, "checksum")

    assert encrypted["mode"] == "DSSE-KMS-METADATA"
    assert encrypted["label"] == "checksum"
    refute inspect(encrypted) =~ "local-checksum"

    assert SSE.decrypt_metadata_with_dsse_kms_key(encrypted, envelope, "checksum") == metadata

    tampered = Map.put(encrypted, "label", "object_parts")

    assert_raise RuntimeError, ~r/label mismatch/, fn ->
      SSE.decrypt_metadata_with_dsse_kms_key(tampered, envelope, "checksum")
    end
  end
end
