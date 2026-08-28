defmodule Maxio.Admin.Envelope do
  @moduledoc """
  MinIO madmin-go v3 encrypted envelope compatibility boundary.

  The wire format is `salt(32) | algorithm_id(1) | nonce(8) | headerless SIO`.
  Key derivation and authenticated framing execute synchronously in the authenticated
  request process; the signing-secret capability is never sent to another process or stored.
  """

  alias Maxio.Auth.SigningSecret

  @salt_size 32
  @nonce_size 8
  @tag_size 16
  @frame_size 16_384

  @type error :: :unexpected_header | :unsupported_algorithm | :not_authentic

  @spec decrypt(SigningSecret.t(), binary()) :: {:ok, binary()} | {:error, error()}
  def decrypt(
        %SigningSecret{secret: secret},
        <<salt::binary-size(@salt_size), algorithm_id, nonce::binary-size(@nonce_size),
          ciphertext::binary>>
      ) do
    with {:ok, cipher} <- cipher_for_id(algorithm_id),
         {:ok, key} <- derive_key(secret, salt, algorithm_id),
         {:ok, plaintext} <-
           decrypt_sio(cipher, key, nonce, ciphertext,
             associated_data: <<>>,
             frame_size: @frame_size
           ) do
      {:ok, plaintext}
    end
  rescue
    _exception -> {:error, :not_authentic}
  catch
    _kind, _reason -> {:error, :not_authentic}
  end

  def decrypt(%SigningSecret{}, envelope) when is_binary(envelope),
    do: {:error, :unexpected_header}

  @spec encrypt(SigningSecret.t(), iodata()) :: {:ok, binary()} | {:error, term()}
  def encrypt(%SigningSecret{} = secret, plaintext) do
    encrypt(secret, plaintext,
      algorithm_id: 0,
      salt: :crypto.strong_rand_bytes(@salt_size),
      nonce: :crypto.strong_rand_bytes(@nonce_size)
    )
  end

  @doc false
  @spec encrypt(SigningSecret.t(), iodata(), keyword()) :: {:ok, binary()} | {:error, term()}
  def encrypt(%SigningSecret{secret: secret}, plaintext, opts) when is_list(opts) do
    algorithm_id = Keyword.get(opts, :algorithm_id, 0)
    salt = Keyword.fetch!(opts, :salt)
    nonce = Keyword.fetch!(opts, :nonce)

    with true <- is_binary(salt) and byte_size(salt) == @salt_size,
         true <- is_binary(nonce) and byte_size(nonce) == @nonce_size,
         {:ok, cipher} <- cipher_for_id(algorithm_id),
         {:ok, key} <- derive_key(secret, salt, algorithm_id),
         {:ok, ciphertext} <-
           encrypt_sio(cipher, key, nonce, IO.iodata_to_binary(plaintext),
             associated_data: <<>>,
             frame_size: @frame_size
           ) do
      {:ok, salt <> <<algorithm_id>> <> nonce <> ciphertext}
    else
      false -> {:error, :unexpected_header}
      {:error, reason} -> {:error, reason}
    end
  rescue
    _exception -> {:error, :not_authentic}
  catch
    _kind, _reason -> {:error, :not_authentic}
  end

  @doc false
  @spec decrypt_sio(atom(), binary(), binary(), binary(), keyword()) ::
          {:ok, binary()} | {:error, :not_authentic}
  def decrypt_sio(cipher, key, base_nonce, ciphertext, opts)
      when is_binary(key) and is_binary(base_nonce) and is_binary(ciphertext) do
    associated_data = Keyword.get(opts, :associated_data, <<>>)
    frame_size = Keyword.fetch!(opts, :frame_size)

    with true <- is_integer(frame_size) and frame_size > 0,
         {:ok, binding_tag} <- binding_tag(cipher, key, base_nonce, associated_data),
         {:ok, frames} <- split_ciphertext(ciphertext, frame_size),
         {:ok, plaintext} <- decrypt_frames(frames, cipher, key, base_nonce, binding_tag) do
      {:ok, plaintext}
    else
      _other -> {:error, :not_authentic}
    end
  rescue
    _exception -> {:error, :not_authentic}
  catch
    _kind, _reason -> {:error, :not_authentic}
  end

  defp encrypt_sio(cipher, key, base_nonce, plaintext, opts) do
    associated_data = Keyword.get(opts, :associated_data, <<>>)
    frame_size = Keyword.fetch!(opts, :frame_size)

    with {:ok, binding_tag} <- binding_tag(cipher, key, base_nonce, associated_data) do
      frames = plaintext_frames(plaintext, frame_size)
      last_index = length(frames)

      encrypted =
        frames
        |> Enum.with_index(1)
        |> Enum.map(fn {frame, sequence} ->
          marker = if sequence == last_index, do: 0x80, else: 0x00
          nonce = frame_nonce(base_nonce, sequence)
          aad = <<marker>> <> binding_tag
          {ciphertext, tag} = encrypt_aead(cipher, key, nonce, frame, aad)
          [ciphertext, tag]
        end)

      {:ok, IO.iodata_to_binary(encrypted)}
    end
  end

  defp binding_tag(cipher, key, base_nonce, associated_data) do
    case encrypt_aead(cipher, key, frame_nonce(base_nonce, 0), <<>>, associated_data) do
      {<<>>, tag} when byte_size(tag) == @tag_size -> {:ok, tag}
      _other -> {:error, :not_authentic}
    end
  end

  defp plaintext_frames(<<>>, _frame_size), do: [<<>>]

  defp plaintext_frames(plaintext, frame_size) when byte_size(plaintext) < frame_size,
    do: [plaintext]

  defp plaintext_frames(plaintext, frame_size) do
    do_plaintext_frames(frame_size, plaintext, [])
  end

  defp do_plaintext_frames(_frame_size, <<>>, acc), do: Enum.reverse(acc)

  defp do_plaintext_frames(frame_size, plaintext, acc) when byte_size(plaintext) <= frame_size,
    do: Enum.reverse([plaintext | acc])

  defp do_plaintext_frames(frame_size, plaintext, acc) do
    <<frame::binary-size(^frame_size), rest::binary>> = plaintext
    do_plaintext_frames(frame_size, rest, [frame | acc])
  end

  defp split_ciphertext(ciphertext, _frame_size) when byte_size(ciphertext) < @tag_size,
    do: {:error, :not_authentic}

  defp split_ciphertext(ciphertext, frame_size) do
    full_frame_size = frame_size + @tag_size
    do_split_ciphertext(full_frame_size, ciphertext, [])
  end

  defp do_split_ciphertext(_full_frame_size, ciphertext, _acc)
       when byte_size(ciphertext) < @tag_size,
       do: {:error, :not_authentic}

  defp do_split_ciphertext(full_frame_size, ciphertext, acc)
       when byte_size(ciphertext) <= full_frame_size,
       do: {:ok, Enum.reverse([ciphertext | acc])}

  defp do_split_ciphertext(full_frame_size, ciphertext, acc) do
    <<frame::binary-size(^full_frame_size), rest::binary>> = ciphertext
    do_split_ciphertext(full_frame_size, rest, [frame | acc])
  end

  defp decrypt_frames(frames, cipher, key, base_nonce, binding_tag) do
    last_index = length(frames)

    frames
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {frame, sequence}, {:ok, acc} ->
      marker = if sequence == last_index, do: 0x80, else: 0x00

      case decrypt_frame(frame, cipher, key, base_nonce, sequence, marker, binding_tag) do
        {:ok, plaintext} -> {:cont, {:ok, [plaintext | acc]}}
        {:error, :not_authentic} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, plaintext} -> {:ok, plaintext |> Enum.reverse() |> IO.iodata_to_binary()}
      {:error, :not_authentic} = error -> error
    end
  end

  defp decrypt_frame(frame, cipher, key, base_nonce, sequence, marker, binding_tag) do
    ciphertext_size = byte_size(frame) - @tag_size

    with true <- ciphertext_size >= 0,
         <<ciphertext::binary-size(^ciphertext_size), tag::binary-size(@tag_size)>> <- frame,
         plaintext when is_binary(plaintext) <-
           decrypt_aead(
             cipher,
             key,
             frame_nonce(base_nonce, sequence),
             ciphertext,
             <<marker>> <> binding_tag,
             tag
           ) do
      {:ok, plaintext}
    else
      _other -> {:error, :not_authentic}
    end
  end

  defp frame_nonce(base_nonce, sequence), do: base_nonce <> <<sequence::little-unsigned-32>>

  defp encrypt_aead(:aes_gcm, key, nonce, plaintext, aad) do
    :crypto.crypto_one_time_aead(aes_cipher(key), key, nonce, plaintext, aad, true)
  end

  defp encrypt_aead(:chacha20_poly1305, key, nonce, plaintext, aad) do
    :crypto.crypto_one_time_aead(:chacha20_poly1305, key, nonce, plaintext, aad, true)
  end

  defp decrypt_aead(:aes_gcm, key, nonce, ciphertext, aad, tag) do
    :crypto.crypto_one_time_aead(aes_cipher(key), key, nonce, ciphertext, aad, tag, false)
  end

  defp decrypt_aead(:chacha20_poly1305, key, nonce, ciphertext, aad, tag) do
    :crypto.crypto_one_time_aead(
      :chacha20_poly1305,
      key,
      nonce,
      ciphertext,
      aad,
      tag,
      false
    )
  end

  defp aes_cipher(key) when byte_size(key) == 16, do: :aes_128_gcm
  defp aes_cipher(key) when byte_size(key) == 32, do: :aes_256_gcm

  defp cipher_for_id(0), do: {:ok, :aes_gcm}
  defp cipher_for_id(1), do: {:ok, :chacha20_poly1305}
  defp cipher_for_id(2), do: {:ok, :aes_gcm}
  defp cipher_for_id(_algorithm_id), do: {:error, :unsupported_algorithm}

  defp derive_key(secret, salt, algorithm_id) when algorithm_id in [0, 1] do
    raw_hex =
      Argon2.Base.hash_password(secret, salt,
        format: :raw_hash,
        argon2_type: 2,
        t_cost: 1,
        m_cost: 16,
        parallelism: 4,
        hashlen: 32
      )

    case Base.decode16(raw_hex, case: :mixed) do
      {:ok, key} when byte_size(key) == 32 -> {:ok, key}
      _other -> {:error, :not_authentic}
    end
  end

  defp derive_key(secret, salt, 2),
    do: {:ok, :crypto.pbkdf2_hmac(:sha256, secret, salt, 8192, 32)}

  defp derive_key(_secret, _salt, _algorithm_id), do: {:error, :unsupported_algorithm}
end
