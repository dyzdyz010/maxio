defmodule Maxio.Crypto.SSE do
  @moduledoc """
  Streaming at-rest encryption for S3 server-side encryption modes.

  Ciphertext is framed as `<ct_len::32><iv::96><tag::128><ciphertext>` per
  plaintext block. Keeping the same frame format for SSE-S3 and SSE-C lets the
  object layer map S3 Range requests before decrypting.
  """

  @chunk 65_536
  @sse_s3_aad "maxio-sse-s3"
  @sse_c_aad "maxio-sse-c"
  @sse_kms_aad "maxio-sse-kms"
  @sse_dsse_inner_aad "maxio-sse-dsse-kms-inner"
  @sse_dsse_outer_aad "maxio-sse-dsse-kms-outer"
  @frame_header_size 4 + 12 + 16
  @dsse_frame_header_size 4 + 12 + 16 + 12 + 16

  @doc "Plaintext block size used for encrypted object frame mapping."
  @spec plaintext_block_size() :: pos_integer()
  def plaintext_block_size, do: @chunk

  @doc "Per-frame header size: ct_len + iv + tag."
  @spec frame_header_size() :: pos_integer()
  def frame_header_size, do: @frame_header_size

  @doc "Per-frame header size for a stored SSE algorithm."
  @spec frame_header_size(String.t() | nil) :: pos_integer()
  def frame_header_size("aws:kms:dsse"), do: @dsse_frame_header_size
  def frame_header_size(_algorithm), do: @frame_header_size

  @doc "Encrypt plaintext chunks with an object DEK wrapped by the server master key."
  @spec wrap_stream(Enumerable.t()) ::
          {Enumerable.t(),
           %{wrapped_dek_b64: String.t(), dek_iv_b64: String.t(), dek_tag_b64: String.t()}}
  def wrap_stream(chunks) do
    dek = :crypto.strong_rand_bytes(32)
    {wrapped, wrap_iv, wrap_tag} = wrap_dek(dek)

    envelope = %{
      wrapped_dek_b64: Base.encode64(wrapped),
      dek_iv_b64: Base.encode64(wrap_iv),
      dek_tag_b64: Base.encode64(wrap_tag)
    }

    cipher_stream =
      chunks
      |> rechunk(@chunk)
      |> Stream.map(fn plain_block -> encrypt_block(dek, plain_block, @sse_s3_aad) end)

    {cipher_stream, envelope}
  end

  @doc "Encrypt plaintext chunks with a customer-provided SSE-C key."
  @spec wrap_stream_with_customer_key(Enumerable.t(), binary(), String.t()) ::
          {Enumerable.t(),
           %{
             mode: String.t(),
             customer_key_md5_b64: String.t(),
             customer_key_hmac_salt_b64: String.t(),
             customer_key_hmac_b64: String.t()
           }}
  def wrap_stream_with_customer_key(chunks, customer_key, key_md5_b64)
      when is_binary(customer_key) and byte_size(customer_key) == 32 do
    envelope = customer_key_envelope(customer_key, key_md5_b64)
    {encrypt_stream_with_customer_key(chunks, customer_key), envelope}
  end

  @doc "Encrypt plaintext chunks with a KMS-generated object DEK."
  @spec wrap_stream_with_kms_key(Enumerable.t(), String.t() | nil, String.t() | nil, keyword()) ::
          {Enumerable.t(), map()}
  def wrap_stream_with_kms_key(chunks, key_id, context_b64, opts \\ []) do
    {envelope, dek} = kms_envelope_and_dek(key_id, context_b64, opts)

    {encrypt_stream_with_key(chunks, dek, @sse_kms_aad), envelope}
  end

  @doc "Encrypt plaintext chunks with two independent KMS-generated object DEKs."
  @spec wrap_stream_with_dsse_kms_key(
          Enumerable.t(),
          String.t() | nil,
          String.t() | nil,
          keyword()
        ) :: {Enumerable.t(), map()}
  def wrap_stream_with_dsse_kms_key(chunks, key_id, context_b64, opts \\ []) do
    {envelope, {inner_dek, outer_dek}} = dsse_kms_envelope_and_deks(key_id, context_b64, opts)

    {encrypt_stream_with_dsse_keys(chunks, inner_dek, outer_dek), envelope}
  end

  @doc "Build an SSE-KMS envelope without retaining the plaintext data key."
  @spec kms_envelope(String.t() | nil, String.t() | nil, keyword()) :: map()
  def kms_envelope(key_id, context_b64, opts \\ []) do
    {envelope, _dek} = kms_envelope_and_dek(key_id, context_b64, opts)
    envelope
  end

  @doc "Build a DSSE-KMS envelope without retaining plaintext data keys."
  @spec dsse_kms_envelope(String.t() | nil, String.t() | nil, keyword()) :: map()
  def dsse_kms_envelope(key_id, context_b64, opts \\ []) do
    {envelope, {_inner_dek, _outer_dek}} =
      dsse_kms_envelope_and_deks(key_id, context_b64, opts)

    envelope
  end

  @doc "Encrypt plaintext chunks with a data key recovered from an existing SSE-KMS envelope."
  @spec encrypt_stream_with_kms_envelope(Enumerable.t(), map()) :: Enumerable.t()
  def encrypt_stream_with_kms_envelope(chunks, %{} = envelope) do
    dek = Maxio.KMS.decrypt_data_key!(envelope)
    encrypt_stream_with_key(chunks, dek, @sse_kms_aad)
  end

  @doc "Encrypt plaintext chunks with data keys recovered from an existing DSSE-KMS envelope."
  @spec encrypt_stream_with_dsse_kms_envelope(Enumerable.t(), map()) :: Enumerable.t()
  def encrypt_stream_with_dsse_kms_envelope(chunks, %{} = envelope) do
    {inner_dek, outer_dek} = dsse_deks!(envelope)
    encrypt_stream_with_dsse_keys(chunks, inner_dek, outer_dek)
  end

  defp kms_envelope_and_dek(key_id, context_b64, opts) do
    data_key = Maxio.KMS.generate_data_key!(key_id, context_b64)
    dek = Map.fetch!(data_key, :plaintext_key)

    envelope = %{
      mode: "SSE-KMS",
      kms_key_id: Map.fetch!(data_key, :key_id),
      kms_encrypted_dek_b64: Map.fetch!(data_key, :encrypted_data_key_b64),
      kms_dek_iv_b64: Map.fetch!(data_key, :key_iv_b64),
      kms_dek_tag_b64: Map.fetch!(data_key, :key_tag_b64),
      kms_encryption_context_b64: context_b64,
      bucket_key_enabled: Keyword.get(opts, :bucket_key_enabled, false)
    }

    {envelope, dek}
  end

  defp dsse_kms_envelope_and_deks(key_id, context_b64, _opts) do
    inner_data_key = Maxio.KMS.generate_data_key!(key_id, context_b64)
    outer_data_key = Maxio.KMS.generate_data_key!(key_id, context_b64)

    key_id = Map.fetch!(outer_data_key, :key_id)

    envelope = %{
      mode: "DSSE-KMS",
      kms_key_id: key_id,
      kms_encryption_context_b64: context_b64,
      bucket_key_enabled: false,
      dsse_inner: kms_layer_envelope(inner_data_key, context_b64),
      dsse_outer: kms_layer_envelope(outer_data_key, context_b64)
    }

    {envelope,
     {Map.fetch!(inner_data_key, :plaintext_key), Map.fetch!(outer_data_key, :plaintext_key)}}
  end

  defp kms_layer_envelope(data_key, context_b64) do
    %{
      mode: "SSE-KMS",
      kms_key_id: Map.fetch!(data_key, :key_id),
      kms_encrypted_dek_b64: Map.fetch!(data_key, :encrypted_data_key_b64),
      kms_dek_iv_b64: Map.fetch!(data_key, :key_iv_b64),
      kms_dek_tag_b64: Map.fetch!(data_key, :key_tag_b64),
      kms_encryption_context_b64: context_b64,
      bucket_key_enabled: false
    }
  end

  @doc "Build the stored SSE-C key verification envelope without storing the raw key."
  @spec customer_key_envelope(binary(), String.t()) :: %{
          mode: String.t(),
          customer_key_md5_b64: String.t(),
          customer_key_hmac_salt_b64: String.t(),
          customer_key_hmac_b64: String.t()
        }
  def customer_key_envelope(customer_key, key_md5_b64)
      when is_binary(customer_key) and byte_size(customer_key) == 32 do
    salt = :crypto.strong_rand_bytes(16)
    key_hmac = customer_key_hmac(customer_key, salt)

    %{
      mode: "SSE-C",
      customer_key_md5_b64: key_md5_b64,
      customer_key_hmac_salt_b64: Base.encode64(salt),
      customer_key_hmac_b64: Base.encode64(key_hmac)
    }
  end

  @doc "Encrypt plaintext chunks directly with an already-validated SSE-C key."
  @spec encrypt_stream_with_customer_key(Enumerable.t(), binary()) :: Enumerable.t()
  def encrypt_stream_with_customer_key(chunks, customer_key)
      when is_binary(customer_key) and byte_size(customer_key) == 32 do
    encrypt_stream_with_key(chunks, customer_key, @sse_c_aad)
  end

  defp encrypt_stream_with_key(chunks, key, aad) do
    chunks
    |> rechunk(@chunk)
    |> Stream.map(fn plain_block -> encrypt_block(key, plain_block, aad) end)
  end

  defp encrypt_stream_with_dsse_keys(chunks, inner_key, outer_key) do
    chunks
    |> rechunk(@chunk)
    |> Stream.map(fn plain_block -> encrypt_dsse_block(inner_key, outer_key, plain_block) end)
  end

  @doc "Decrypt SSE-S3 ciphertext frames with the stored envelope."
  @spec unwrap_stream(Enumerable.t(), map()) :: Enumerable.t()
  def unwrap_stream(cipher_chunks, envelope) do
    dek = unwrap_dek(envelope)
    decrypt_stream(cipher_chunks, dek, @sse_s3_aad, "SSE-S3")
  end

  @doc "Decrypt SSE-C ciphertext frames after validating the provided customer key."
  @spec unwrap_stream_with_customer_key(Enumerable.t(), map(), binary()) :: Enumerable.t()
  def unwrap_stream_with_customer_key(cipher_chunks, envelope, customer_key)
      when is_binary(customer_key) and byte_size(customer_key) == 32 do
    unless customer_key_matches?(envelope, customer_key) do
      raise "SSE-C decryption failed: customer key verification failed"
    end

    decrypt_stream(cipher_chunks, customer_key, @sse_c_aad, "SSE-C")
  end

  @doc "Decrypt SSE-KMS ciphertext frames with a provider-unwrapped object DEK."
  @spec unwrap_stream_with_kms_key(Enumerable.t(), map()) :: Enumerable.t()
  def unwrap_stream_with_kms_key(cipher_chunks, envelope) do
    dek = Maxio.KMS.decrypt_data_key!(envelope)
    decrypt_stream(cipher_chunks, dek, @sse_kms_aad, "SSE-KMS")
  end

  @doc "Decrypt DSSE-KMS ciphertext frames with provider-unwrapped object DEKs."
  @spec unwrap_stream_with_dsse_kms_key(Enumerable.t(), map()) :: Enumerable.t()
  def unwrap_stream_with_dsse_kms_key(cipher_chunks, envelope) do
    {inner_dek, outer_dek} = dsse_deks!(envelope)
    decrypt_dsse_stream(cipher_chunks, inner_dek, outer_dek)
  end

  @doc "Encrypt a small object metadata map with an existing DSSE-KMS envelope."
  @spec encrypt_metadata_with_dsse_kms_key(map(), map(), String.t()) :: map()
  def encrypt_metadata_with_dsse_kms_key(%{} = metadata, envelope, label)
      when is_binary(label) do
    {inner_key, outer_key} = dsse_deks!(envelope)
    plain = Jason.encode!(metadata)

    inner_iv = :crypto.strong_rand_bytes(12)
    inner_aad = dsse_metadata_inner_aad(label)

    {inner_ct, inner_tag} =
      :crypto.crypto_one_time_aead(
        :aes_256_gcm,
        inner_key,
        inner_iv,
        plain,
        inner_aad,
        true
      )

    outer_iv = :crypto.strong_rand_bytes(12)
    outer_aad = dsse_metadata_outer_aad(label, inner_iv, inner_tag)

    {outer_ct, outer_tag} =
      :crypto.crypto_one_time_aead(
        :aes_256_gcm,
        outer_key,
        outer_iv,
        inner_ct,
        outer_aad,
        true
      )

    %{
      "mode" => "DSSE-KMS-METADATA",
      "label" => label,
      "inner_iv_b64" => Base.encode64(inner_iv),
      "inner_tag_b64" => Base.encode64(inner_tag),
      "outer_iv_b64" => Base.encode64(outer_iv),
      "outer_tag_b64" => Base.encode64(outer_tag),
      "ciphertext_b64" => Base.encode64(outer_ct)
    }
  end

  @doc "Decrypt a small object metadata map stored with DSSE-KMS metadata encryption."
  @spec decrypt_metadata_with_dsse_kms_key(map(), map(), String.t()) :: map()
  def decrypt_metadata_with_dsse_kms_key(%{} = encrypted, envelope, label)
      when is_binary(label) do
    unless envelope_value(encrypted, :mode) == "DSSE-KMS-METADATA" and
             envelope_value(encrypted, :label) == label do
      raise "DSSE-KMS metadata decrypt failed: metadata envelope label mismatch"
    end

    {inner_key, outer_key} = dsse_deks!(envelope)
    inner_iv = b64(encrypted, :inner_iv_b64)
    inner_tag = b64(encrypted, :inner_tag_b64)
    outer_iv = b64(encrypted, :outer_iv_b64)
    outer_tag = b64(encrypted, :outer_tag_b64)
    outer_ct = b64(encrypted, :ciphertext_b64)
    outer_aad = dsse_metadata_outer_aad(label, inner_iv, inner_tag)

    inner_ct =
      case :crypto.crypto_one_time_aead(
             :aes_256_gcm,
             outer_key,
             outer_iv,
             outer_ct,
             outer_aad,
             outer_tag,
             false
           ) do
        :error -> raise "DSSE-KMS metadata decrypt failed: outer GCM authentication tag mismatch"
        inner_ct -> inner_ct
      end

    inner_aad = dsse_metadata_inner_aad(label)

    plain =
      case :crypto.crypto_one_time_aead(
             :aes_256_gcm,
             inner_key,
             inner_iv,
             inner_ct,
             inner_aad,
             inner_tag,
             false
           ) do
        :error -> raise "DSSE-KMS metadata decrypt failed: inner GCM authentication tag mismatch"
        plain -> plain
      end

    Jason.decode!(plain)
  end

  @doc "Return true when the supplied raw customer key matches an SSE-C envelope."
  @spec customer_key_matches?(map() | nil, binary()) :: boolean()
  def customer_key_matches?(%{} = envelope, customer_key)
      when is_binary(customer_key) and byte_size(customer_key) == 32 do
    with {:ok, salt} <- b64_value(envelope, :customer_key_hmac_salt_b64),
         {:ok, expected_hmac} <- b64_value(envelope, :customer_key_hmac_b64),
         hmac <- customer_key_hmac(customer_key, salt),
         true <- byte_size(hmac) == byte_size(expected_hmac) do
      Plug.Crypto.secure_compare(hmac, expected_hmac)
    else
      _ -> false
    end
  end

  def customer_key_matches?(_envelope, _customer_key), do: false

  defp decrypt_stream(cipher_chunks, key, aad, label) do
    cipher_chunks
    |> Stream.transform(
      fn -> <<>> end,
      fn data, buf ->
        decrypt_available_frames(buf <> data, key, aad, label, [])
      end,
      fn
        <<>> -> {[], <<>>}
        _garbage -> raise("#{label} decryption failed: malformed ciphertext frame")
      end,
      fn _ -> :ok end
    )
  end

  defp encrypt_block(key, plain, aad) do
    iv = :crypto.strong_rand_bytes(12)
    {ct, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, plain, aad, true)
    <<byte_size(ct)::32, iv::binary-size(12), tag::binary-size(16), ct::binary>>
  end

  defp encrypt_dsse_block(inner_key, outer_key, plain) do
    inner_iv = :crypto.strong_rand_bytes(12)

    {inner_ct, inner_tag} =
      :crypto.crypto_one_time_aead(
        :aes_256_gcm,
        inner_key,
        inner_iv,
        plain,
        @sse_dsse_inner_aad,
        true
      )

    outer_iv = :crypto.strong_rand_bytes(12)
    outer_aad = dsse_outer_aad(inner_iv, inner_tag)

    {outer_ct, outer_tag} =
      :crypto.crypto_one_time_aead(
        :aes_256_gcm,
        outer_key,
        outer_iv,
        inner_ct,
        outer_aad,
        true
      )

    <<
      byte_size(outer_ct)::32,
      inner_iv::binary-size(12),
      inner_tag::binary-size(16),
      outer_iv::binary-size(12),
      outer_tag::binary-size(16),
      outer_ct::binary
    >>
  end

  defp decrypt_available_frames(buf, _key, _aad, _label, acc) when byte_size(buf) < 4,
    do: {Enum.reverse(acc), buf}

  defp decrypt_available_frames(<<ct_len::32, _rest::binary>>, _key, _aad, label, _acc)
       when ct_len > @chunk do
    raise "#{label} decryption failed: malformed ciphertext frame"
  end

  defp decrypt_available_frames(<<ct_len::32, rest::binary>> = buf, key, aad, label, acc) do
    if byte_size(rest) < @frame_header_size - 4 + ct_len do
      {Enum.reverse(acc), buf}
    else
      <<iv::binary-size(12), tag::binary-size(16), ct::binary-size(^ct_len), tail::binary>> =
        rest

      case :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, ct, aad, tag, false) do
        :error -> raise "#{label} decryption failed: GCM authentication tag mismatch"
        plain -> decrypt_available_frames(tail, key, aad, label, [plain | acc])
      end
    end
  end

  defp decrypt_dsse_stream(cipher_chunks, inner_key, outer_key) do
    cipher_chunks
    |> Stream.transform(
      fn -> <<>> end,
      fn data, buf ->
        decrypt_available_dsse_frames(buf <> data, inner_key, outer_key, [])
      end,
      fn
        <<>> -> {[], <<>>}
        _garbage -> raise("DSSE-KMS decryption failed: malformed ciphertext frame")
      end,
      fn _ -> :ok end
    )
  end

  defp decrypt_available_dsse_frames(buf, _inner_key, _outer_key, acc)
       when byte_size(buf) < 4,
       do: {Enum.reverse(acc), buf}

  defp decrypt_available_dsse_frames(<<ct_len::32, _rest::binary>>, _inner_key, _outer_key, _acc)
       when ct_len > @chunk do
    raise "DSSE-KMS decryption failed: malformed ciphertext frame"
  end

  defp decrypt_available_dsse_frames(
         <<ct_len::32, rest::binary>> = buf,
         inner_key,
         outer_key,
         acc
       ) do
    if byte_size(rest) < @dsse_frame_header_size - 4 + ct_len do
      {Enum.reverse(acc), buf}
    else
      <<
        inner_iv::binary-size(12),
        inner_tag::binary-size(16),
        outer_iv::binary-size(12),
        outer_tag::binary-size(16),
        outer_ct::binary-size(^ct_len),
        tail::binary
      >> = rest

      outer_aad = dsse_outer_aad(inner_iv, inner_tag)

      inner_ct =
        case :crypto.crypto_one_time_aead(
               :aes_256_gcm,
               outer_key,
               outer_iv,
               outer_ct,
               outer_aad,
               outer_tag,
               false
             ) do
          :error -> raise "DSSE-KMS decryption failed: outer GCM authentication tag mismatch"
          inner_ct -> inner_ct
        end

      plain =
        case :crypto.crypto_one_time_aead(
               :aes_256_gcm,
               inner_key,
               inner_iv,
               inner_ct,
               @sse_dsse_inner_aad,
               inner_tag,
               false
             ) do
          :error -> raise "DSSE-KMS decryption failed: inner GCM authentication tag mismatch"
          plain -> plain
        end

      decrypt_available_dsse_frames(tail, inner_key, outer_key, [plain | acc])
    end
  end

  defp dsse_outer_aad(inner_iv, inner_tag),
    do: IO.iodata_to_binary([@sse_dsse_outer_aad, 0, inner_iv, 0, inner_tag])

  defp dsse_metadata_inner_aad(label),
    do: IO.iodata_to_binary([@sse_dsse_inner_aad, 0, "metadata", 0, label])

  defp dsse_metadata_outer_aad(label, inner_iv, inner_tag),
    do:
      IO.iodata_to_binary([
        @sse_dsse_outer_aad,
        0,
        "metadata",
        0,
        label,
        0,
        inner_iv,
        0,
        inner_tag
      ])

  defp dsse_deks!(%{} = envelope) do
    inner = envelope_value(envelope, :dsse_inner)
    outer = envelope_value(envelope, :dsse_outer)

    unless is_map(inner) and is_map(outer) do
      raise "DSSE-KMS DEK unwrap failed: envelope is missing data key layers"
    end

    {Maxio.KMS.decrypt_data_key!(inner), Maxio.KMS.decrypt_data_key!(outer)}
  end

  defp wrap_dek(dek) do
    mk = master_key()
    iv = :crypto.strong_rand_bytes(12)
    {wrapped, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, mk, iv, dek, @sse_s3_aad, true)
    {wrapped, iv, tag}
  end

  defp unwrap_dek(%{} = env) do
    mk = master_key()
    wrapped = b64(env, :wrapped_dek_b64)
    iv = b64(env, :dek_iv_b64)
    tag = b64(env, :dek_tag_b64)

    case :crypto.crypto_one_time_aead(:aes_256_gcm, mk, iv, wrapped, @sse_s3_aad, tag, false) do
      :error -> raise "SSE-S3 DEK unwrap failed: master key/tag mismatch"
      dek -> dek
    end
  end

  defp b64(env, key) do
    val = Map.get(env, key) || Map.get(env, Atom.to_string(key))
    Base.decode64!(val)
  end

  defp envelope_value(envelope, key),
    do: Map.get(envelope, key) || Map.get(envelope, Atom.to_string(key))

  defp b64_value(env, key) do
    val = Map.get(env, key) || Map.get(env, Atom.to_string(key))

    with value when is_binary(value) <- val,
         {:ok, decoded} <- Base.decode64(value) do
      {:ok, decoded}
    else
      _ -> :error
    end
  end

  defp master_key do
    cfg = Application.get_env(:maxio, :sse, [])

    case Keyword.get(cfg, :master_key) do
      nil ->
        raise "maxio SSE master key not configured (config :maxio, :sse, master_key: <base64 32B>)"

      b64 ->
        Base.decode64!(b64)
    end
  end

  defp customer_key_hmac(customer_key, salt) do
    :crypto.mac(:hmac, :sha256, customer_key, salt)
  end

  defp rechunk(chunks, size) do
    Stream.transform(
      chunks,
      fn -> <<>> end,
      fn data, buf ->
        combined = buf <> data
        emit_blocks(combined, size, [])
      end,
      fn buf -> if buf == <<>>, do: {[], <<>>}, else: {[buf], <<>>} end,
      fn _ -> :ok end
    )
  end

  defp emit_blocks(buf, size, acc) when byte_size(buf) >= size do
    <<block::binary-size(^size), rest::binary>> = buf
    emit_blocks(rest, size, [block | acc])
  end

  defp emit_blocks(buf, _size, acc), do: {Enum.reverse(acc), buf}
end
