defmodule Maxio.Auth.SigV4.StreamingVerifier do
  @moduledoc """
  aws-chunked（Content-Encoding: aws-chunked）流式上传的逐块签名链验证状态机（铁律 3：
  显式状态机驱动，任一异常硬失败，绝不把半验证字节交下游）。

  替换 M1 的 passthrough：M1 只验 seed 签名 + 解帧；M2 对每个数据块（含 0 大小终止块）
  按 AWS sigv4-streaming 规范复算 chunk_signature 并常数时间比对，签名链以 prev_sig 串联。

  ## string-to-sign（数据块，6 行，无尾换行）
      AWS4-HMAC-SHA256-PAYLOAD
      <amz-date>
      <scope>
      <prev-signature>
      <hex(SHA256("")) 固定常量>
      <hex(SHA256(chunk-data))>

  ## 帧格式
      <hexsize>;chunk-signature=<64hex>\\r\\n<data>\\r\\n
  终止块 size=0，仍签名验证（data hash = 空串常量）。

  ## flavor（由 x-amz-content-sha256 决定，调用方传入）
    * :signed          STREAMING-AWS4-HMAC-SHA256-PAYLOAD
    * :signed_trailer  STREAMING-AWS4-HMAC-SHA256-PAYLOAD-TRAILER（终止块后验 trailer chunk 签名）
    * :unsigned_trailer STREAMING-UNSIGNED-PAYLOAD-TRAILER（不验逐块签名，仅解帧）

  ## 用法
      v = init(k_signing:, date:, scope:, seed_signature:, expected_decoded_len:, flavor:)
      {:ok, decoded_chunks, v} = feed(v, network_bytes)   # 可多次
      :ok = finalize(v)                                    # 校验终止块 + 长度
  """
  alias Maxio.Auth.SigV4.Signer

  @empty_sha "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
  @sig_marker ";chunk-signature="

  @enforce_keys [:k_signing, :date, :scope, :prev_sig, :flavor]
  defstruct [
    :k_signing,
    :date,
    :scope,
    :prev_sig,
    :flavor,
    expected_decoded_len: nil,
    trailer_names: [],
    decoded_count: 0,
    buffer: "",
    stage: :data
  ]

  @type t :: %__MODULE__{}

  @spec init(keyword()) :: t()
  def init(opts) do
    %__MODULE__{
      k_signing: Keyword.fetch!(opts, :k_signing),
      date: Keyword.fetch!(opts, :date),
      scope: Keyword.fetch!(opts, :scope),
      prev_sig: Keyword.fetch!(opts, :seed_signature),
      flavor: Keyword.get(opts, :flavor, :signed),
      expected_decoded_len: Keyword.get(opts, :expected_decoded_len),
      trailer_names: Keyword.get(opts, :trailer_names, [])
    }
  end

  @doc "数据块 string-to-sign（6 行，无尾换行）。纯函数，供测试与内部复用。"
  @spec chunk_string_to_sign(String.t(), String.t(), String.t(), String.t()) :: String.t()
  def chunk_string_to_sign(date, scope, prev_sig, data_hash_hex) do
    Enum.join(
      [
        "AWS4-HMAC-SHA256-PAYLOAD",
        date,
        scope,
        prev_sig,
        @empty_sha,
        data_hash_hex
      ],
      "\n"
    )
  end

  @doc "trailer chunk string-to-sign（5 行，无尾换行；signed_trailer 变体用）。"
  @spec trailer_string_to_sign(String.t(), String.t(), String.t(), String.t()) :: String.t()
  def trailer_string_to_sign(date, scope, prev_sig, trailer_block_hash_hex) do
    Enum.join(
      [
        "AWS4-HMAC-SHA256-TRAILER",
        date,
        scope,
        prev_sig,
        trailer_block_hash_hex
      ],
      "\n"
    )
  end

  @doc """
  喂入网络字节，返回 {:ok, decoded_chunks, new_state} | {:error, reason}。
  decoded_chunks 是**已逐块验证通过**的纯净 data（iodata 列表，可空）。
  reason ∈ :signature_does_not_match | :incomplete_body | :invalid_chunk。
  """
  @spec feed(t(), binary()) :: {:ok, [binary()], t()} | {:error, atom()}
  def feed(%__MODULE__{} = v, bytes) when is_binary(bytes) do
    consume(%{v | buffer: v.buffer <> bytes}, [])
  end

  # 已到 done：忽略多余字节（终止块后只可能是 trailer，已在 done 前处理）
  defp consume(%__MODULE__{stage: :done} = v, acc), do: {:ok, Enum.reverse(acc), v}

  defp consume(%__MODULE__{stage: :data} = v, acc) do
    case take_frame(v.buffer) do
      :need_more ->
        {:ok, Enum.reverse(acc), v}

      {:error, reason} ->
        {:error, reason}

      {:frame, size, provided_sig, data, rest} ->
        with :ok <- verify_data_chunk(v, size, provided_sig, data) do
          expected = data_chunk_signature(v, data)
          v2 = %{v | prev_sig: expected, buffer: rest, decoded_count: v.decoded_count + size}

          cond do
            size == 0 and v.flavor == :signed_trailer ->
              # 终止块已验；进入 trailer 解析（prev_sig = 终止块签名）
              consume(%{v2 | stage: :trailer}, acc)

            size == 0 ->
              consume(%{v2 | stage: :done}, acc)

            true ->
              consume(v2, [data | acc])
          end
        end
    end
  end

  defp consume(%__MODULE__{stage: :trailer} = v, acc) do
    case parse_trailer(v.buffer) do
      :need_more ->
        {:ok, Enum.reverse(acc), v}

      {:error, reason} ->
        {:error, reason}

      {:ok, trailer_block, provided_sig, rest} ->
        sts =
          trailer_string_to_sign(v.date, v.scope, v.prev_sig, Signer.hex_sha256(trailer_block))

        expected = Signer.signature(v.k_signing, sts)

        if Signer.secure_compare(expected, provided_sig) do
          consume(%{v | stage: :done, buffer: rest}, acc)
        else
          {:error, :signature_does_not_match}
        end
    end
  end

  # ── 数据块签名验证 ──
  defp verify_data_chunk(%__MODULE__{flavor: :unsigned_trailer}, _size, _sig, _data), do: :ok

  defp verify_data_chunk(v, _size, provided_sig, data) do
    expected = data_chunk_signature(v, data)

    if Signer.secure_compare(expected, provided_sig) do
      :ok
    else
      {:error, :signature_does_not_match}
    end
  end

  defp data_chunk_signature(v, data) do
    data_hash = Signer.hex_sha256(data)
    sts = chunk_string_to_sign(v.date, v.scope, v.prev_sig, data_hash)
    Signer.signature(v.k_signing, sts)
  end

  # ── 帧解析：<hexsize>;chunk-signature=<64hex>\r\n<data>\r\n ──
  # 返回 {:frame, size, sig, data, rest} | :need_more | {:error, reason}
  defp take_frame(buffer) do
    case :binary.split(buffer, "\r\n") do
      [_only] ->
        :need_more

      [header, after_header] ->
        with {:ok, size} <- parse_size(header),
             {:ok, sig} <- parse_signature(header) do
          if byte_size(after_header) >= size + 2 do
            case after_header do
              <<data::binary-size(^size), "\r\n", rest::binary>> ->
                {:frame, size, sig, data, rest}

              _ ->
                {:error, :invalid_chunk}
            end
          else
            :need_more
          end
        end
    end
  end

  defp parse_size(header) do
    token = header |> :binary.split(";") |> List.first() |> String.trim()

    case Integer.parse(token, 16) do
      {n, ""} when n >= 0 -> {:ok, n}
      _ -> {:error, :invalid_chunk}
    end
  end

  defp parse_signature(header) do
    case :binary.match(header, @sig_marker) do
      :nomatch ->
        {:error, :invalid_chunk}

      {pos, len} ->
        sig = binary_part(header, pos + len, byte_size(header) - pos - len) |> String.trim()

        if valid_hex64?(sig), do: {:ok, sig}, else: {:error, :invalid_chunk}
    end
  end

  defp valid_hex64?(sig) do
    byte_size(sig) == 64 and String.match?(sig, ~r/\A[0-9a-fA-F]{64}\z/)
  end

  # ── trailer chunk：<name>:<value>\r\nx-amz-trailer-signature:<sig>\r\n ──
  # 返回 {:ok, trailer_block, sig, rest} | :need_more | {:error, reason}
  # trailer_block 用于哈希：每个 trailing header "name:value\n"（小写名，无空白）。
  defp parse_trailer(buffer) do
    case :binary.match(buffer, "x-amz-trailer-signature:") do
      :nomatch ->
        :need_more

      {pos, len} ->
        header_part = binary_part(buffer, 0, pos)
        after_marker = binary_part(buffer, pos + len, byte_size(buffer) - pos - len)

        case :binary.split(after_marker, "\r\n") do
          [_only] ->
            :need_more

          [sig_raw, rest] ->
            sig = String.trim(sig_raw)

            if valid_hex64?(sig) do
              {:ok, normalize_trailer_block(header_part), sig, rest}
            else
              {:error, :invalid_chunk}
            end
        end
    end
  end

  # header_part 形如 "x-amz-checksum-crc32c:sOO8/Q==\r\n"（可能多行），
  # 规整为按行 "name:value\n"（小写名、去空白）。
  defp normalize_trailer_block(header_part) do
    header_part
    |> String.split("\r\n", trim: true)
    |> Enum.map(fn line ->
      case String.split(line, ":", parts: 2) do
        [name, value] -> String.downcase(String.trim(name)) <> ":" <> String.trim(value) <> "\n"
        _ -> ""
      end
    end)
    |> Enum.join("")
  end

  @doc "校验已达终止块（stage == :done）且 decoded 长度与声明一致。"
  @spec finalize(t()) :: :ok | {:error, atom()}
  def finalize(%__MODULE__{stage: :done} = v) do
    cond do
      is_nil(v.expected_decoded_len) -> :ok
      v.decoded_count == v.expected_decoded_len -> :ok
      true -> {:error, :incomplete_body}
    end
  end

  def finalize(%__MODULE__{}), do: {:error, :incomplete_body}
end
