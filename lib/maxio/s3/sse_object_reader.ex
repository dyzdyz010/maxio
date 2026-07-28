defmodule Maxio.S3.SSEObjectReader do
  @moduledoc """
  Shared plaintext-range reader helpers for SSE-encrypted object bytes.

  S3 Range operates on plaintext bytes, while the storage layer stores framed
  ciphertext for SSE objects. This module maps plaintext ranges to ciphertext
  frame ranges and exposes a decrypting stream that trims the resulting
  plaintext back to the requested range.
  """

  @server_side_algorithms ["AES256", "aws:kms", "aws:kms:dsse"]

  @type byte_range :: {non_neg_integer(), non_neg_integer()}
  @type requested_range :: nil | :full | byte_range()
  @type plain_slice :: nil | :full | byte_range()

  @spec server_side_encrypted?(String.t() | nil) :: boolean()
  def server_side_encrypted?(algorithm), do: algorithm in @server_side_algorithms

  @spec storage_range(requested_range(), non_neg_integer(), String.t()) ::
          {byte_range() | nil, plain_slice()}
  def storage_range(nil, _total, _algorithm), do: {nil, nil}
  def storage_range(:full, _total, _algorithm), do: {nil, :full}

  def storage_range({first, last}, total, algorithm) do
    block_size = Maxio.Crypto.SSE.plaintext_block_size()
    frame_header_size = Maxio.Crypto.SSE.frame_header_size(algorithm)
    full_frame_size = frame_header_size + block_size
    first_frame = div(first, block_size)
    last_frame = div(last, block_size)

    cipher_first = first_frame * full_frame_size
    last_frame_plain_size = min(block_size, total - last_frame * block_size)
    cipher_last = last_frame * full_frame_size + frame_header_size + last_frame_plain_size - 1

    plain_first = rem(first, block_size)
    plain_last = plain_first + last - first

    {{cipher_first, cipher_last}, {plain_first, plain_last}}
  end

  @spec decrypt_stream(Enumerable.t(), String.t(), map() | nil, plain_slice(), keyword()) ::
          Enumerable.t()
  def decrypt_stream(raw_stream, algorithm, envelope, plain_slice, opts \\ []) do
    raw_stream
    |> unwrap_stream(algorithm, envelope, Keyword.get(opts, :customer_key))
    |> slice_plain_stream(plain_slice)
  end

  defp unwrap_stream(raw_stream, "SSE-C", envelope, customer_key)
       when is_binary(customer_key) do
    Maxio.Crypto.SSE.unwrap_stream_with_customer_key(raw_stream, envelope, customer_key)
  end

  defp unwrap_stream(_raw_stream, "SSE-C", _envelope, _customer_key) do
    raise "SSE-C decryption failed: missing customer key"
  end

  defp unwrap_stream(raw_stream, "aws:kms", envelope, _customer_key) do
    Maxio.Crypto.SSE.unwrap_stream_with_kms_key(raw_stream, envelope)
  end

  defp unwrap_stream(raw_stream, "aws:kms:dsse", envelope, _customer_key) do
    Maxio.Crypto.SSE.unwrap_stream_with_dsse_kms_key(raw_stream, envelope)
  end

  defp unwrap_stream(raw_stream, "AES256", envelope, _customer_key) do
    Maxio.Crypto.SSE.unwrap_stream(raw_stream, envelope)
  end

  defp slice_plain_stream(stream, nil), do: stream
  defp slice_plain_stream(stream, :full), do: stream

  defp slice_plain_stream(stream, {first, last}) do
    Stream.transform(stream, {first, last - first + 1}, fn chunk, {skip, remaining} ->
      cond do
        remaining <= 0 ->
          {:halt, {0, 0}}

        true ->
          chunk
          |> IO.iodata_to_binary()
          |> slice_chunk(skip, remaining)
      end
    end)
  end

  defp slice_chunk(chunk, skip, remaining) when skip >= byte_size(chunk),
    do: {[], {skip - byte_size(chunk), remaining}}

  defp slice_chunk(chunk, skip, remaining) when skip > 0 do
    <<_skipped::binary-size(^skip), rest::binary>> = chunk
    emit_slice(rest, remaining)
  end

  defp slice_chunk(chunk, 0, remaining), do: emit_slice(chunk, remaining)

  defp emit_slice(chunk, remaining) do
    emit_size = min(byte_size(chunk), remaining)
    <<emit::binary-size(^emit_size), _tail::binary>> = chunk
    {[emit], {0, remaining - emit_size}}
  end
end
