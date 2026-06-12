defmodule Maxio.Crypto.SSE do
  @moduledoc """
  SSE-S3 真实 at-rest 加密（AES-256-GCM 信封加密，流式友好，铁律 4 不全缓冲）。

  信封模型（诚实 MVP）：
    * 每对象生成随机 256-bit DEK（data encryption key）。
    * 对象字节按固定块（64KB）独立 AES-256-GCM 加密（每块随机 12B IV + 16B tag）；
      密文流帧 = <ct_len::32><iv::96><tag::128><ciphertext>，逐块产出（流式）。
    * DEK 用服务端主密钥（config :maxio, :sse, master_key —— base64 32B；prod 经 env）以
      AES-256-GCM 包裹，wrapped DEK + IV + tag 作为信封头随对象元数据存（对象级一个）。
    * 主密钥是单一静态密钥（MVP 简化密钥管理：无轮转/HSM/KMS——README/启动日志已声明）。
  GCM 认证失败（密文/tag 被篡改）→ raise（绝不静默返回错数据，铁律 3）。
  """
  @chunk 65_536
  @aad "maxio-sse-s3"
  @frame_header_size 4 + 12 + 16

  @doc "SSE-S3 plaintext block size used for frame mapping."
  @spec plaintext_block_size() :: pos_integer()
  def plaintext_block_size, do: @chunk

  @doc "SSE-S3 per-frame header size: ct_len + iv + tag."
  @spec frame_header_size() :: pos_integer()
  def frame_header_size, do: @frame_header_size

  @doc "把明文 chunks 流加密为密文帧流，并返回随元数据存的信封头 map。"
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

    # 把任意分块的明文流重切成 64KB 块再逐块加密（保证帧确定性，与读出无关）。
    cipher_stream =
      chunks
      |> rechunk(@chunk)
      |> Stream.map(fn plain_block -> encrypt_block(dek, plain_block) end)

    {cipher_stream, envelope}
  end

  @doc "把密文帧流用信封头解密还原明文流。GCM 认证失败 → raise。"
  @spec unwrap_stream(Enumerable.t(), map()) :: Enumerable.t()
  def unwrap_stream(cipher_chunks, envelope) do
    dek = unwrap_dek(envelope)

    cipher_chunks
    |> Stream.transform(
      fn -> <<>> end,
      fn data, buf ->
        decrypt_available_frames(buf <> data, dek, [])
      end,
      fn
        <<>> -> {[], <<>>}
        _garbage -> raise("SSE-S3 decryption failed: malformed ciphertext frame")
      end,
      fn _ -> :ok end
    )
  end

  # ── 块加解密 ──
  defp encrypt_block(dek, plain) do
    iv = :crypto.strong_rand_bytes(12)
    {ct, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, dek, iv, plain, @aad, true)
    <<byte_size(ct)::32, iv::binary-size(12), tag::binary-size(16), ct::binary>>
  end

  # 逐帧懒解密：只缓存不足一帧的尾部，避免 SSE GET/CopyObject 把完整对象读入内存。
  defp decrypt_available_frames(buf, _dek, acc) when byte_size(buf) < 4,
    do: {Enum.reverse(acc), buf}

  defp decrypt_available_frames(<<ct_len::32, _rest::binary>>, _dek, _acc)
       when ct_len > @chunk do
    raise "SSE-S3 decryption failed: malformed ciphertext frame"
  end

  defp decrypt_available_frames(<<ct_len::32, rest::binary>> = buf, dek, acc) do
    if byte_size(rest) < @frame_header_size - 4 + ct_len do
      {Enum.reverse(acc), buf}
    else
      <<iv::binary-size(12), tag::binary-size(16), ct::binary-size(^ct_len), tail::binary>> = rest

      case :crypto.crypto_one_time_aead(:aes_256_gcm, dek, iv, ct, @aad, tag, false) do
        :error -> raise "SSE-S3 decryption failed: GCM authentication tag mismatch"
        plain -> decrypt_available_frames(tail, dek, [plain | acc])
      end
    end
  end

  # ── DEK 包裹/解裹（主密钥 AES-256-GCM）──
  defp wrap_dek(dek) do
    mk = master_key()
    iv = :crypto.strong_rand_bytes(12)
    {wrapped, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, mk, iv, dek, @aad, true)
    {wrapped, iv, tag}
  end

  defp unwrap_dek(%{} = env) do
    mk = master_key()
    wrapped = b64(env, :wrapped_dek_b64)
    iv = b64(env, :dek_iv_b64)
    tag = b64(env, :dek_tag_b64)

    case :crypto.crypto_one_time_aead(:aes_256_gcm, mk, iv, wrapped, @aad, tag, false) do
      :error -> raise "SSE-S3 DEK unwrap failed: master key/tag mismatch"
      dek -> dek
    end
  end

  # envelope 既可能是 atom-key（刚生成）也可能是 string-key（从 jsonb 读出）。
  defp b64(env, key) do
    val = Map.get(env, key) || Map.get(env, Atom.to_string(key))
    Base.decode64!(val)
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

  # 把任意分块流重切成固定大小块（最后一块可短）。
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
