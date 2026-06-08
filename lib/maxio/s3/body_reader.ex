defmodule Maxio.S3.BodyReader do
  @moduledoc """
  把 Plug.Conn 的请求 body 包成产出**纯净对象字节块**的 Stream（绝不全缓冲，铁律 4）。

  - :single / :unsigned —— 直接逐块产出 read_body 的 chunk。
  - :streaming（aws-chunked）—— 由 Maxio.Auth.SigV4.StreamingVerifier 显式状态机驱动：
    边读边解帧、逐块复算 chunk-signature 常数时间比对（坏块硬停 SignatureDoesNotMatch）、
    剥去 `<hexsize>;chunk-signature=<sig>\\r\\n` 头与尾随 \\r\\n 输出纯净 data；遇 size=0 终止块停止；
    读尽后过 finalize 校验 decoded 长度（不符 → IncompleteBody）。
    flavor（:signed / :signed_trailer / :unsigned_trailer）由 x-amz-content-sha256 决定；
    kSigning/scope/seed/amz_date 经 conn.assigns.sigv4_context 由 SigV4 plug 透传（不重推，铁律 2）。

  parse_chunk_header/1：解析 aws-chunked 帧头，区分真正的 0 终止块（帧头数值 "0"）与
  非 hex 垃圾帧头（→ :error，绝不静默当 0，铁律 3）；纯函数，供单测直接调。

  返回逐块产出纯净对象字节的 Stream；调用方 Enum 消费（如交 Storage.put/4）。
  注意：因 read_body 会推进 conn，stream 内部持有并推进 conn——消费必须在同一进程内一次性完成。
  """
  alias Maxio.Auth.SigV4.StreamingVerifier
  alias Maxio.S3.{Error, Log}

  @read_opts [length: 1_048_576, read_length: 1_048_576, read_timeout: 30_000]

  @doc "返回逐块产出纯净对象字节的 Stream.resource。"
  @spec stream(Plug.Conn.t(), :single | :unsigned | :streaming) :: Enumerable.t()
  def stream(conn, :streaming) do
    # 铁律 3：aws-chunked 逐块签名验证由 StreamingVerifier 显式状态机驱动；
    # 坏块/截断/长度不符在 emit 前硬 raise Maxio.S3.Error（绝不把半验证字节交下游）。
    ctx = conn.assigns[:sigv4_context]
    content_sha = req_header(conn, "x-amz-content-sha256") || ""
    flavor = flavor_of(content_sha)
    decoded_len = parse_int(req_header(conn, "x-amz-decoded-content-length"))
    trailer_names = parse_trailer_names(req_header(conn, "x-amz-trailer"))

    verifier =
      StreamingVerifier.init(
        k_signing: ctx.k_signing,
        date: ctx.amz_date,
        scope: ctx.scope,
        seed_signature: ctx.seed_signature,
        expected_decoded_len: decoded_len,
        flavor: flavor,
        trailer_names: trailer_names
      )

    Log.info("aws-chunked streaming verify start", payload_mode: :streaming, reason: flavor)

    Stream.resource(
      fn -> {conn, verifier, :reading} end,
      &verify_step/1,
      fn _ -> :ok end
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

  # ── aws-chunked 逐块签名验证驱动（StreamingVerifier 状态机）──
  # body 读尽后切到 {:done, v2}，下一迭代过 finalize 校验终止块 + decoded 长度再 :halt。
  defp verify_step({:done, verifier}) do
    case StreamingVerifier.finalize(verifier) do
      :ok -> {:halt, :ok}
      {:error, reason} -> raise streaming_error(reason)
    end
  end

  defp verify_step({conn, verifier, :reading}) do
    case Plug.Conn.read_body(conn, @read_opts) do
      {:ok, more, _conn2} ->
        case StreamingVerifier.feed(verifier, more) do
          {:ok, chunks, v2} -> {chunks, {:done, v2}}
          {:error, reason} -> raise streaming_error(reason)
        end

      {:more, more, conn2} ->
        case StreamingVerifier.feed(verifier, more) do
          {:ok, chunks, v2} -> {chunks, {conn2, v2, :reading}}
          {:error, reason} -> raise streaming_error(reason)
        end

      {:error, _} ->
        raise streaming_error(:incomplete_body)
    end
  end

  defp streaming_error(:signature_does_not_match), do: Error.new(:signature_does_not_match)
  defp streaming_error(:incomplete_body), do: Error.new(:incomplete_body)
  defp streaming_error(_), do: Error.new(:incomplete_body, message: "invalid aws-chunked frame")

  # flavor 由 x-amz-content-sha256 决定（调用方未声明流式时默认 :signed）。
  defp flavor_of("STREAMING-AWS4-HMAC-SHA256-PAYLOAD"), do: :signed
  defp flavor_of("STREAMING-AWS4-HMAC-SHA256-PAYLOAD-TRAILER"), do: :signed_trailer
  defp flavor_of("STREAMING-UNSIGNED-PAYLOAD-TRAILER"), do: :unsigned_trailer
  defp flavor_of(_), do: :signed

  defp req_header(conn, name), do: conn |> Plug.Conn.get_req_header(name) |> List.first()

  defp parse_int(nil), do: nil

  defp parse_int(str) do
    case Integer.parse(str) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp parse_trailer_names(nil), do: []

  defp parse_trailer_names(str) do
    str |> String.split(",", trim: true) |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
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
