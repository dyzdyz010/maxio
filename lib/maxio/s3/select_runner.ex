defmodule Maxio.S3.SelectRunner do
  @moduledoc """
  Shared SelectObjectContent execution runner.

  Handlers pass an already-authorized object and parsed Select request. The
  runner stages selected output in a temp file before any caller sends a
  response or commits generated output bytes.
  """

  alias Maxio.{Objects, Storage}
  alias Maxio.Cluster.Placement

  alias Maxio.S3.{
    Error,
    Log,
    SSE,
    SSEObjectReader,
    SelectCompression,
    SelectCSV,
    SelectJSON,
    SelectSQL
  }

  @spec stage_object!(Plug.Conn.t(), Objects.Object.t(), map(), keyword()) :: map()
  def stage_object!(conn, %Objects.Object{} = object, request, opts \\ []) when is_map(request) do
    bucket = Keyword.fetch!(opts, :bucket)
    key = Keyword.fetch!(opts, :key)

    unless Keyword.get(opts, :allow_archive?, false) do
      ensure_selectable_storage_class!(object, bucket, key)
    end

    ensure_supported_request!(request)
    plan = SelectSQL.parse!(request.expression)
    scan_range = normalize_scan_range!(request.scan_range, object.size, bucket, key)

    {source_stream, cleanup_source} = object_stream!(object, conn, bucket, key)

    try do
      source = SelectCompression.wrap!(source_stream, request.input.compression_type)

      try do
        source.stream
        |> stage_select_result!(request, plan, scan_range, source.compressed?)
        |> attach_source_progress(source)
        |> ensure_source_length!(object, bucket, key)
      after
        source.cleanup.()
      end
    after
      cleanup_source.()
    end
  end

  @spec cleanup_stream(map()) :: :ok | :noop | {:error, term()}
  def cleanup_stream(%{cleanup: cleanup}) when is_function(cleanup, 0), do: cleanup.()
  def cleanup_stream(%{path: path}) when is_binary(path), do: File.rm(path)
  def cleanup_stream(_stream), do: :noop

  @spec source_bytes_processed(map()) :: non_neg_integer()
  def source_bytes_processed(%{source_bytes_processed: value}) when is_integer(value), do: value
  def source_bytes_processed(stream), do: stream.bytes_processed

  @spec validate_sse_read_headers!(Plug.Conn.t(), Objects.Object.t(), String.t(), String.t()) ::
          :ok
  def validate_sse_read_headers!(conn, object, bucket, key) do
    SSE.validate_read_headers!(conn.req_headers, object.sse_algorithm, object.sse_envelope,
      resource: "/#{bucket}/#{key}"
    )
  end

  @spec ensure_supported_request!(map()) :: :ok
  def ensure_supported_request!(request) do
    cond do
      String.upcase(request.expression_type) != "SQL" ->
        unsupported!("Only SQL ExpressionType is implemented for SelectObjectContent")

      unsupported_serialization?(request.input.format, request.output.format) ->
        unsupported!("Only CSV/JSON input and CSV/JSON output are implemented")

      unsupported_compression?(request.input.compression_type) ->
        unsupported!("BZIP2 SelectObjectContent input is not implemented")

      compressed_scan_range?(request) ->
        raise Error.new(:invalid_request,
                message: "ScanRange is not supported for compressed SelectObjectContent input"
              )

      true ->
        :ok
    end
  end

  defp object_stream!(object, conn, bucket, key) do
    cond do
      object.sse_algorithm in ["AES256", "aws:kms", "aws:kms:dsse"] ->
        {:ok, raw_stream} =
          Storage.get(bucket, key, object.version_id, nil, Placement.storage_opts(object))

        stream =
          SSEObjectReader.decrypt_stream(
            raw_stream,
            object.sse_algorithm,
            object.sse_envelope,
            nil
          )

        {stream, fn -> :ok end}

      object.sse_algorithm == "SSE-C" ->
        {customer_key, _key_md5_b64} =
          SSE.resolve_customer_read!(conn.req_headers, object.sse_envelope,
            resource: "/#{bucket}/#{key}"
          )

        {:ok, raw_stream} =
          Storage.get(bucket, key, object.version_id, nil, Placement.storage_opts(object))

        stream =
          SSEObjectReader.decrypt_stream(
            raw_stream,
            object.sse_algorithm,
            object.sse_envelope,
            nil,
            customer_key: customer_key
          )

        {stream, fn -> :ok end}

      true ->
        {:ok, stream} =
          Storage.get(bucket, key, object.version_id, nil, Placement.storage_opts(object))

        {stream, fn -> :ok end}
    end
  end

  defp stage_select_result!(
         stream,
         %{input: %{format: "CSV"}} = request,
         plan,
         scan_range,
         drain_on_halt?
       ) do
    SelectCSV.stage!(
      stream,
      plan,
      request.input.csv_options,
      output_options(request),
      scan_range,
      drain_on_halt?: drain_on_halt?,
      output_format: request.output.format
    )
  end

  defp stage_select_result!(
         stream,
         %{input: %{format: "JSON"}} = request,
         plan,
         scan_range,
         drain_on_halt?
       ) do
    SelectJSON.stage!(
      stream,
      plan,
      request.input.json_options,
      output_options(request),
      scan_range,
      drain_on_halt?: drain_on_halt?,
      output_format: request.output.format
    )
  end

  defp output_options(%{output: %{format: "CSV", csv_options: options}}), do: options
  defp output_options(%{output: %{format: "JSON", json_options: options}}), do: options

  defp attach_source_progress(stream, %{compressed?: true} = source) do
    Map.put(stream, :source_bytes_processed, source.source_bytes_processed.())
  end

  defp attach_source_progress(stream, _source), do: stream

  defp ensure_source_length!(
         %{halt_reason: reason, source_complete?: false} = stream,
         _object,
         _bucket,
         _key
       )
       when reason in [:limit, :scan_range],
       do: stream

  defp ensure_source_length!(stream, %{size: expected}, bucket, key) when is_integer(expected) do
    if source_bytes_processed(stream) == expected do
      stream
    else
      source_length_mismatch!(stream, expected, bucket, key)
    end
  end

  defp ensure_source_length!(stream, _object, _bucket, _key), do: stream

  defp source_length_mismatch!(stream, expected, bucket, key) do
    Log.warn("select object source length mismatch before response",
      action: :select_object_content,
      bucket: bucket,
      key: key,
      expected_size: expected,
      actual_size: source_bytes_processed(stream)
    )

    cleanup_stream(stream)
    raise Error.new(:internal_error, resource: "/#{bucket}/#{key}")
  end

  defp normalize_scan_range!(nil, _object_size, _bucket, _key), do: nil

  defp normalize_scan_range!(scan_range, object_size, bucket, key) when is_integer(object_size) do
    case scan_range do
      %{start: start, end: nil} when is_integer(start) ->
        %{start: start, end: nil, empty?: false}

      %{start: nil, end: bytes_from_end} when is_integer(bytes_from_end) ->
        end_offset = object_size - 1
        start_offset = max(object_size - bytes_from_end, 0)
        empty? = bytes_from_end == 0 or object_size == 0
        %{start: start_offset, end: end_offset, empty?: empty?}

      %{start: start, end: end_offset}
      when is_integer(start) and is_integer(end_offset) and start <= end_offset ->
        %{start: start, end: end_offset, empty?: false}

      %{start: start, end: end_offset}
      when is_integer(start) and is_integer(end_offset) ->
        raise Error.new(:invalid_argument,
                message: "ScanRange Start must be less than or equal to End",
                resource: "/#{bucket}/#{key}"
              )
    end
  end

  defp normalize_scan_range!(_scan_range, _object_size, bucket, key) do
    raise Error.new(:internal_error, resource: "/#{bucket}/#{key}")
  end

  defp ensure_selectable_storage_class!(object, bucket, key) do
    if object.storage_class in ["GLACIER", "DEEP_ARCHIVE", "REDUCED_REDUNDANCY"] do
      raise Error.new(:invalid_object_state, resource: "/#{bucket}/#{key}")
    end

    :ok
  end

  defp unsupported_compression?(nil), do: false
  defp unsupported_compression?(""), do: false

  defp unsupported_compression?(value) do
    value = SelectCompression.normalize_type(value)
    value == "BZIP2"
  end

  defp compressed_scan_range?(%{scan_range: nil}), do: false

  defp compressed_scan_range?(%{input: %{compression_type: compression}}) do
    compression
    |> SelectCompression.normalize_type()
    |> case do
      "NONE" -> false
      "GZIP" -> true
      _other -> false
    end
  end

  defp unsupported_serialization?(input, output)
       when input in ["CSV", "JSON"] and output in ["CSV", "JSON"],
       do: false

  defp unsupported_serialization?(_input, _output), do: true

  defp unsupported!(message), do: raise(Error.new(:not_implemented, message: message))
end
