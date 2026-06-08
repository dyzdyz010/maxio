defmodule Maxio.S3.BodyReader do
  @moduledoc """
  把 Plug.Conn 的请求 body 包成产出**纯净对象字节块**的 Stream（绝不全缓冲，铁律 4）。

  - :single / :unsigned —— 直接逐块产出 read_body 的 chunk。
  - :streaming（aws-chunked, STREAMING-AWS4-HMAC-SHA256-PAYLOAD）—— 边读边解帧，
    剥去每个 chunk 的 `<hexsize>;chunk-signature=<sig>\\r\\n` 头与尾随 \\r\\n，
    输出纯净 data；遇 size=0 终止块停止。逐块签名链验证 **M1 跳过但显式日志记为 M2 缺口**
    （seed 签名已在 SigV4 plug 验过，且 handler 会校验解帧总长 == x-amz-decoded-content-length）。

  返回逐块产出纯净对象字节的 Stream；调用方 Enum 消费（如交 Storage.put/4）。
  注意：因 read_body 会推进 conn，stream 内部持有并推进 conn——消费必须在同一进程内一次性完成。
  """
  alias Maxio.S3.Log

  @read_opts [length: 1_048_576, read_length: 1_048_576, read_timeout: 30_000]

  @doc "返回逐块产出纯净对象字节的 Stream.resource。"
  @spec stream(Plug.Conn.t(), :single | :unsigned | :streaming) :: Enumerable.t()
  def stream(conn, :streaming) do
    # 铁律 3：逐块签名验证是已知 M2 缺口——显式日志记录，绝不静默跳过。
    Log.warn("aws-chunked de-frame (per-chunk sig verify deferred to M2)",
      payload_mode: :streaming,
      reason: :m2_per_chunk_verify_skipped
    )

    Stream.resource(
      fn -> {conn, ""} end,
      &deframe_step/1,
      fn _acc -> :ok end
    )
  end

  def stream(conn, _mode) do
    Stream.resource(
      fn -> conn end,
      fn
        :done ->
          {:halt, :done}

        c ->
          case Plug.Conn.read_body(c, @read_opts) do
            {:ok, chunk, _c2} -> {[chunk], :done}
            {:more, chunk, c2} -> {[chunk], c2}
            {:error, _} -> {:halt, :done}
          end
      end,
      fn _ -> :ok end
    )
  end

  # ── aws-chunked 解帧状态机 ──
  # acc = {conn, buffer}；逐步从 buffer 解出帧；buffer 不足则再 read_body 补。
  defp deframe_step(:done), do: {:halt, :done}

  defp deframe_step({conn, buffer}) do
    case parse_chunk(buffer) do
      {:chunk, data, rest} ->
        {[data], {conn, rest}}

      :terminator ->
        {:halt, :done}

      :need_more ->
        case Plug.Conn.read_body(conn, @read_opts) do
          {:ok, "", _conn2} -> {:halt, :done}
          {:ok, more, conn2} -> deframe_step({conn2, buffer <> more})
          {:more, more, conn2} -> deframe_step({conn2, buffer <> more})
          {:error, _} -> {:halt, :done}
        end
    end
  end

  # 解析一个 chunk 帧：`<hexsize>;chunk-signature=<64hex>\r\n<data>\r\n`
  # 返回 {:chunk, data, rest} | :terminator | :need_more
  defp parse_chunk(buffer) do
    case :binary.split(buffer, "\r\n") do
      [header, after_header] ->
        size = chunk_size(header)

        cond do
          size == 0 ->
            :terminator

          byte_size(after_header) >= size + 2 ->
            <<data::binary-size(^size), "\r\n", rest::binary>> = after_header
            {:chunk, data, rest}

          true ->
            :need_more
        end

      [_only] ->
        :need_more
    end
  end

  # header 形如 "10000;chunk-signature=..."，取分号前的 hex 转整数。
  defp chunk_size(header) do
    header
    |> :binary.split(";")
    |> List.first()
    |> String.trim()
    |> String.to_integer(16)
  rescue
    _ -> 0
  end
end
