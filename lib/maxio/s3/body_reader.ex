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
    streaming_resource(conn, nil)
  end

  def stream(conn, mode) do
    {stream, _get_trailers, _discard_trailers} = stream_with_trailers(conn, mode)
    stream
  end

  @doc """
  Returns `{stream, get_trailers, discard_trailers}`.

  `get_trailers` yields verified aws-chunked trailing headers after the stream
  has been fully consumed. For non-trailer payloads it returns `%{}`.
  """
  @spec stream_with_trailers(Plug.Conn.t(), :single | :unsigned | :streaming) ::
          {Enumerable.t(), (-> %{String.t() => String.t()}), (-> :ok)}
  def stream_with_trailers(conn, :streaming) do
    {:ok, trailer_agent} = Agent.start_link(fn -> %{} end)

    stream = streaming_resource(conn, trailer_agent)

    get_trailers = fn ->
      get_and_stop_agent(trailer_agent)
    end

    {stream, get_trailers, fn -> stop_agent(trailer_agent) end}
  end

  def stream_with_trailers(conn, _mode) do
    stream =
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

    {stream, fn -> %{} end, fn -> :ok end}
  end

  @doc """
  Reads a small request body with the same decoded-byte semantics as `stream_with_trailers/2`.

  Streaming aws-chunked callers get the decoded payload and verified trailing
  headers; ordinary callers get the body from `Plug.Conn.read_body/2` and an
  empty trailer map. `limit` applies to decoded bytes.
  """
  @spec read_small_with_trailers!(Plug.Conn.t(), pos_integer(), String.t()) ::
          {Plug.Conn.t(), binary(), %{String.t() => String.t()}}
  def read_small_with_trailers!(
        %Plug.Conn{assigns: %{payload_mode: :streaming}} = conn,
        limit,
        too_large_message
      )
      when is_integer(limit) and limit > 0 do
    if decoded_content_length_exceeds?(conn, limit) do
      raise Error.new(:malformed_xml, message: too_large_message)
    end

    {stream, get_trailers, discard_trailers} =
      stream_with_trailers(conn, :streaming,
        decoded_limit: limit,
        decoded_limit_message: too_large_message,
        read_opts: [length: limit, read_length: limit, read_timeout: 30_000]
      )

    try do
      body = collect_limited_stream!(stream, limit, too_large_message)
      {conn, body, get_trailers.()}
    rescue
      err ->
        discard_trailers.()
        reraise(err, __STACKTRACE__)
    catch
      kind, reason ->
        discard_trailers.()
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  def read_small_with_trailers!(conn, limit, too_large_message)
      when is_integer(limit) and limit > 0 do
    case Plug.Conn.read_body(conn, length: limit, read_length: limit) do
      {:ok, body, conn} ->
        {conn, body, %{}}

      {:more, _partial, _conn} ->
        raise Error.new(:malformed_xml, message: too_large_message)

      {:error, _reason} ->
        raise Error.new(:malformed_xml)
    end
  end

  defp collect_limited_stream!(stream, limit, too_large_message) do
    case Enum.reduce_while(stream, {[], 0}, fn chunk, {chunks, size} ->
           chunk = IO.iodata_to_binary(chunk)
           size = size + byte_size(chunk)

           if size > limit do
             {:halt, :too_large}
           else
             {:cont, {[chunk | chunks], size}}
           end
         end) do
      :too_large ->
        raise Error.new(:malformed_xml, message: too_large_message)

      {chunks, _size} ->
        chunks |> Enum.reverse() |> IO.iodata_to_binary()
    end
  end

  defp stream_with_trailers(conn, :streaming, opts) do
    {:ok, trailer_agent} = Agent.start_link(fn -> %{} end)

    stream = streaming_resource(conn, trailer_agent, opts)

    get_trailers = fn ->
      get_and_stop_agent(trailer_agent)
    end

    {stream, get_trailers, fn -> stop_agent(trailer_agent) end}
  end

  defp decoded_content_length_exceeds?(conn, limit) do
    case parse_int(req_header(conn, "x-amz-decoded-content-length")) do
      n when is_integer(n) and n > limit -> true
      _ -> false
    end
  end

  defp streaming_resource(conn, trailer_agent, opts \\ []) do
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
        decoded_limit: Keyword.get(opts, :decoded_limit),
        flavor: flavor,
        trailer_names: trailer_names
      )

    Log.info("aws-chunked streaming verify start", payload_mode: :streaming, reason: flavor)

    Stream.resource(
      fn -> {conn, verifier, :reading, trailer_agent, opts} end,
      &verify_step/1,
      fn _ -> :ok end
    )
  end

  # ── aws-chunked 逐块签名验证驱动（StreamingVerifier 状态机）──
  # body 读尽后切到 {:done, v2}，下一迭代过 finalize 校验终止块 + decoded 长度再 :halt。
  defp verify_step({:done, verifier, trailer_agent, opts}) do
    case StreamingVerifier.finalize(verifier) do
      :ok ->
        if trailer_agent do
          Agent.update(trailer_agent, fn _ -> StreamingVerifier.trailers(verifier) end)
        end

        {:halt, :ok}

      {:error, reason} ->
        raise streaming_error(reason, opts)
    end
  end

  defp verify_step({conn, verifier, :reading, trailer_agent, opts}) do
    read_opts = Keyword.get(opts, :read_opts, @read_opts)

    case Plug.Conn.read_body(conn, read_opts) do
      {:ok, more, _conn2} ->
        case StreamingVerifier.feed(verifier, more) do
          {:ok, chunks, v2} -> {chunks, {:done, v2, trailer_agent, opts}}
          {:error, reason} -> raise streaming_error(reason, opts)
        end

      {:more, more, conn2} ->
        case StreamingVerifier.feed(verifier, more) do
          {:ok, chunks, v2} -> {chunks, {conn2, v2, :reading, trailer_agent, opts}}
          {:error, reason} -> raise streaming_error(reason, opts)
        end

      {:error, _} ->
        raise streaming_error(:incomplete_body, opts)
    end
  end

  defp streaming_error(:decoded_length_exceeded, opts) do
    case Keyword.get(opts, :decoded_limit_message) do
      message when is_binary(message) -> Error.new(:malformed_xml, message: message)
      _ -> Error.new(:incomplete_body, message: "invalid aws-chunked frame")
    end
  end

  defp streaming_error(:signature_does_not_match, _opts), do: Error.new(:signature_does_not_match)
  defp streaming_error(:incomplete_body, _opts), do: Error.new(:incomplete_body)

  defp streaming_error(_reason, _opts),
    do: Error.new(:incomplete_body, message: "invalid aws-chunked frame")

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

  defp stop_agent(agent) do
    Agent.stop(agent)
  catch
    :exit, _reason -> :ok
  end

  defp get_and_stop_agent(agent) do
    try do
      Agent.get(agent, & &1)
    catch
      :exit, _reason -> %{}
    after
      stop_agent(agent)
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
