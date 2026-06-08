defmodule Maxio.S3.BodyReader do
  @moduledoc """
  把 Plug.Conn 的请求 body 包成产出**纯净对象字节块**的 Stream（绝不全缓冲，铁律 4）。

  - :single / :unsigned —— 直接逐块产出 read_body 的 chunk。
  - :streaming（aws-chunked）—— 边读边解帧，剥去每个 chunk 的
    `<hexsize>;chunk-signature=<sig>\\r\\n` 头与尾随 \\r\\n，输出纯净 data；遇 size=0 终止块停止。
    M2-3 起逐块签名链由 Maxio.Auth.SigV4.StreamingVerifier 验证（接入见 M2-3）。

  解帧帧头解析见 parse_chunk_header/1：区分真正的 0 终止块（帧头数值 "0"）与
  非 hex 垃圾帧头（→ IncompleteBody，绝不静默当 0，铁律 3）。

  返回逐块产出纯净对象字节的 Stream；调用方 Enum 消费（如交 Storage.put/4）。
  注意：因 read_body 会推进 conn，stream 内部持有并推进 conn——消费必须在同一进程内一次性完成。
  """
  alias Maxio.S3.{Error, Log}

  @read_opts [length: 1_048_576, read_length: 1_048_576, read_timeout: 30_000]

  @doc "返回逐块产出纯净对象字节的 Stream.resource。"
  @spec stream(Plug.Conn.t(), :single | :unsigned | :streaming) :: Enumerable.t()
  def stream(conn, :streaming) do
    # 铁律 3：M2-3 起逐块签名验证由 StreamingVerifier 完成；本路径在 verifier 接入前
    # 仅做解帧（非 hex 帧头硬失败，不静默截断）。
    Log.warn("aws-chunked de-frame (per-chunk sig verify wired in M2-3)",
      payload_mode: :streaming,
      reason: :m2_3_streaming_verify_pending
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

  # 解析一个 chunk 帧。返回 {:chunk, data, rest} | :terminator | :need_more。
  # 帧头非法（非 hex、空）→ raise IncompleteBody（铁律 3，不静默当 0）。
  defp parse_chunk(buffer) do
    case :binary.split(buffer, "\r\n") do
      [header, after_header] ->
        case parse_chunk_header(header) do
          {:ok, 0} ->
            :terminator

          {:ok, size} when byte_size(after_header) >= size + 2 ->
            <<data::binary-size(^size), "\r\n", rest::binary>> = after_header
            {:chunk, data, rest}

          {:ok, _size} ->
            :need_more

          :error ->
            Log.warn("aws-chunked malformed frame header", reason: :incomplete_body)
            raise Error.new(:incomplete_body, message: "malformed aws-chunked frame header")
        end

      [_only] ->
        :need_more
    end
  end

  @doc """
  解析 aws-chunked 帧头（`<hexsize>[;chunk-signature=...][;ext...]`）。
  取首个分号前的 token 作为 hex 大小。

    * 合法 hex（含 "0"）→ {:ok, size}
    * 非 hex / 空 / 仅空白 → :error（调用方应 raise IncompleteBody，绝不静默当 0）
  """
  @spec parse_chunk_header(binary()) :: {:ok, non_neg_integer()} | :error
  def parse_chunk_header(header) when is_binary(header) do
    token =
      header
      |> :binary.split(";")
      |> List.first()
      |> String.trim()

    case token do
      "" ->
        :error

      hex ->
        case Integer.parse(hex, 16) do
          {n, ""} when n >= 0 -> {:ok, n}
          _ -> :error
        end
    end
  end
end
