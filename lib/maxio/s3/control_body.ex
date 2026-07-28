defmodule Maxio.S3.ControlBody do
  @moduledoc """
  Bounded small-body reader for S3 control-plane handlers.

  It keeps XML/JSON control bodies out of Plug.Parsers, supports verified
  aws-chunked trailers through `BodyReader`, and applies modeled checksum
  validation before callers parse or persist configuration.
  """

  import Plug.Conn

  alias Maxio.S3.{BodyReader, Checksum, Error}

  @type integrity_requirement :: :optional | :content_md5 | :content_md5_or_flexible

  @spec read!(Plug.Conn.t(), pos_integer(), String.t(), keyword()) ::
          {Plug.Conn.t(), binary(), %{String.t() => String.t()}}
  def read!(conn, limit, too_large_message, opts \\ []) do
    read_small_with_error_mapping!(conn, limit, too_large_message, opts)
  end

  @spec read_and_verify!(Plug.Conn.t(), pos_integer(), String.t(), keyword()) ::
          {Plug.Conn.t(), binary()}
  def read_and_verify!(conn, limit, too_large_message, opts \\ []) do
    {conn, body, trailers} = read!(conn, limit, too_large_message, opts)
    verify_checksums!(conn, body, trailers, opts)
    {conn, body}
  end

  @spec verify_checksums!(Plug.Conn.t(), binary(), map(), keyword()) :: :ok
  def verify_checksums!(conn, body, trailers, opts \\ []) do
    requirement = Keyword.get(opts, :require_integrity, :optional)

    case get_req_header(conn, "content-md5") do
      [_value] ->
        verify_body_checksums!(conn, body, trailers)

      [] ->
        verify_without_content_md5!(conn, body, trailers, requirement)

      _multiple ->
        raise Error.new(:bad_digest, resource: resource(conn))
    end
  end

  defp read_small_with_error_mapping!(conn, limit, too_large_message, opts) do
    BodyReader.read_small_with_trailers!(conn, limit, too_large_message)
  rescue
    err in Error ->
      if err.code == "MalformedXML" and err.message == too_large_message do
        too_large_code = Keyword.get(opts, :too_large_error, :malformed_xml)
        raise Error.new(too_large_code, message: too_large_message, resource: resource(conn))
      else
        reraise(err, __STACKTRACE__)
      end
  end

  defp verify_without_content_md5!(conn, body, trailers, :optional) do
    verify_body_checksums!(conn, body, trailers)
  end

  defp verify_without_content_md5!(conn, _body, _trailers, :content_md5) do
    raise Error.new(:missing_security_header,
            message: "Missing required Content-MD5 header",
            resource: resource(conn)
          )
  end

  defp verify_without_content_md5!(conn, body, trailers, :content_md5_or_flexible) do
    if Checksum.flexible_body_checksum_request?(conn) do
      verify_body_checksums!(conn, body, trailers)
    else
      raise Error.new(:missing_security_header,
              message: "Missing required Content-MD5 header",
              resource: resource(conn)
            )
    end
  end

  defp verify_body_checksums!(conn, body, trailers) do
    checksum = Checksum.from_conn!(conn, fn -> trailers end)
    {stream, get_context, _discard_context} = Checksum.wrap_stream([body], checksum)
    _ = Enum.to_list(stream)
    checksum = get_context.()
    checksum.verify!.()
  end

  defp resource(%Plug.Conn{assigns: %{s3_bucket: bucket, s3_key: key}})
       when is_binary(bucket) and is_binary(key),
       do: "/#{bucket}/#{key}"

  defp resource(%Plug.Conn{assigns: %{s3_bucket: bucket}}) when is_binary(bucket),
    do: "/" <> bucket

  defp resource(_conn), do: nil
end
