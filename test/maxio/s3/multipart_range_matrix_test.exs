defmodule Maxio.S3.MultipartRangeMatrixTest do
  @moduledoc """
  Compact compatibility matrix for byte-range GETs and multipart upload basics.

  This suite is intentionally small enough for the default compat matrix while
  pinning the S3 data-plane semantics most likely to regress across storage
  backends and handler refactors.
  """

  use Maxio.DataCase, async: false

  import Plug.Conn

  alias Maxio.S3.Endpoint
  alias Maxio.Test.SigV4Request

  @data_dir Path.join(System.tmp_dir!(), "maxio_multipart_range_matrix")
  @unset {__MODULE__, :unset}

  setup do
    File.rm_rf(@data_dir)
    File.mkdir_p!(@data_dir)

    prev_s3 = Application.get_env(:maxio, :s3, [])
    prev_min_part_size = Application.get_env(:maxio, :multipart_min_part_size, @unset)

    Application.put_env(:maxio, :s3, Keyword.put(prev_s3, :data_dir, @data_dir))
    Application.put_env(:maxio, :multipart_min_part_size, 1)

    on_exit(fn ->
      Application.put_env(:maxio, :s3, prev_s3)
      restore_env(:multipart_min_part_size, prev_min_part_size)
      File.rm_rf(@data_dir)
    end)

    :ok
  end

  defp call(conn), do: Endpoint.call(conn, Endpoint.init([]))

  test "GetObject Range matrix covers full, single ranges, invalid ranges, and unsupported multi-range behavior" do
    bucket = "mrange"
    key = "r.txt"
    body = "0123456789"

    create_bucket(bucket)
    put_object(bucket, key, body)

    full = get_object(bucket, key)
    assert full.status == 200
    assert full.resp_body == body
    assert get_resp_header(full, "content-range") == []

    bounded = get_object(bucket, key, [{"range", "bytes=2-5"}])
    assert bounded.status == 206
    assert bounded.resp_body == "2345"
    assert get_resp_header(bounded, "content-range") == ["bytes 2-5/10"]
    assert get_resp_header(bounded, "content-length") == ["4"]

    suffix = get_object(bucket, key, [{"range", "bytes=-4"}])
    assert suffix.status == 206
    assert suffix.resp_body == "6789"
    assert get_resp_header(suffix, "content-range") == ["bytes 6-9/10"]

    open_ended = get_object(bucket, key, [{"range", "bytes=7-"}])
    assert open_ended.status == 206
    assert open_ended.resp_body == "789"
    assert get_resp_header(open_ended, "content-range") == ["bytes 7-9/10"]

    invalid = get_object(bucket, key, [{"range", "bytes=10-20"}])
    assert_s3_error(invalid, 416, "InvalidRange")

    reversed = get_object(bucket, key, [{"range", "bytes=7-2"}])
    assert_s3_error(reversed, 416, "InvalidRange")

    malformed = get_object(bucket, key, [{"range", "bytes=abc-4"}])
    assert_s3_error(malformed, 416, "InvalidRange")

    wrong_unit = get_object(bucket, key, [{"range", "items=0-1"}])
    assert_s3_error(wrong_unit, 416, "InvalidRange")

    # S3 does not support retrieving multiple byte ranges in one GET. Maxio's
    # documented compatibility contract treats that unsupported request as a
    # full-object 200 rather than emitting multipart/byteranges.
    multi_range = get_object(bucket, key, [{"range", "bytes=0-1,4-5"}])
    assert multi_range.status == 200
    assert multi_range.resp_body == body
    assert get_resp_header(multi_range, "content-range") == []
  end

  test "multipart lifecycle matrix lists parts, completes in part order, and exposes multipart ETag" do
    bucket = "mpmatrixlife"
    key = "big.bin"

    create_bucket(bucket)
    upload_id = initiate_upload(bucket, key)

    etag2 = upload_part(bucket, key, upload_id, 2, "TWO")
    etag1 = upload_part(bucket, key, upload_id, 1, "ONE-")

    parts = list_parts(bucket, key, upload_id)
    assert parts.status == 200
    assert parts.resp_body =~ "<PartNumber>1</PartNumber>"
    assert parts.resp_body =~ "<PartNumber>2</PartNumber>"
    assert_xml_etag(parts.resp_body, etag1)
    assert_xml_etag(parts.resp_body, etag2)

    complete = complete_upload(bucket, key, upload_id, [{1, etag1}, {2, etag2}])
    assert complete.status == 200
    assert complete.resp_body =~ "<ETag>"
    assert complete.resp_body =~ "-2&quot;</ETag>" or complete.resp_body =~ ~s(-2"</ETag>)

    get = get_object(bucket, key)
    assert get.status == 200
    assert get.resp_body == "ONE-TWO"

    [multipart_etag] = get_resp_header(get, "etag")
    assert multipart_etag =~ "-2\""
  end

  test "multipart abort matrix removes upload and rejects later ListParts or CompleteMultipartUpload" do
    bucket = "mpmatrixabort"
    key = "object.bin"

    create_bucket(bucket)
    upload_id = initiate_upload(bucket, key)
    etag = upload_part(bucket, key, upload_id, 1, "body")

    abort =
      SigV4Request.signed_conn(:delete, "/#{bucket}/#{key}", query: %{"uploadId" => upload_id})
      |> call()

    assert abort.status == 204

    assert_s3_error(list_parts(bucket, key, upload_id), 404, "NoSuchUpload")

    complete = complete_upload(bucket, key, upload_id, [{1, etag}])
    assert_s3_error(complete, 404, "NoSuchUpload")
  end

  test "CompleteMultipartUpload conditional matrix keeps failed uploads retryable" do
    bucket = "mpmatrixcond"
    key = "object.bin"

    create_bucket(bucket)
    put_object(bucket, key, "old body")

    {none_match_upload, none_match_etag} = stage_single_part(bucket, key, "none-match body")

    rejected_none =
      complete_upload(bucket, key, none_match_upload, [{1, none_match_etag}], [
        {"if-none-match", "*"}
      ])

    assert_s3_error(rejected_none, 412, "PreconditionFailed")
    assert get_object(bucket, key).resp_body == "old body"

    retried_none = complete_upload(bucket, key, none_match_upload, [{1, none_match_etag}])
    assert retried_none.status == 200
    assert get_object(bucket, key).resp_body == "none-match body"

    [current_etag] = get_resp_header(head_object(bucket, key), "etag")
    {match_upload, match_etag} = stage_single_part(bucket, key, "matched body")

    rejected_match =
      complete_upload(bucket, key, match_upload, [{1, match_etag}], [
        {"if-match", "\"not-current\""}
      ])

    assert_s3_error(rejected_match, 412, "PreconditionFailed")
    assert get_object(bucket, key).resp_body == "none-match body"

    accepted_match =
      complete_upload(bucket, key, match_upload, [{1, match_etag}], [{"if-match", current_etag}])

    assert accepted_match.status == 200
    assert get_object(bucket, key).resp_body == "matched body"
  end

  test "malformed CompleteMultipartUpload XML does not commit and leaves upload retryable" do
    bucket = "mpmatrixbadxml"
    key = "object.bin"
    body = "retryable multipart body"

    create_bucket(bucket)
    {upload_id, etag} = stage_single_part(bucket, key, body)

    malformed_xml =
      "<CompleteMultipartUpload><Part><PartNumber>1</PartNumber><ETag>#{etag}</ETag><ETag>#{etag}</ETag></Part></CompleteMultipartUpload>"

    malformed =
      SigV4Request.signed_conn(:post, "/#{bucket}/#{key}",
        query: %{"uploadId" => upload_id},
        body: malformed_xml
      )
      |> call()

    assert_s3_error(malformed, 400, "MalformedXML")
    assert_s3_error(get_object(bucket, key), 404, "NoSuchKey")

    parts = list_parts(bucket, key, upload_id)
    assert parts.status == 200
    assert parts.resp_body =~ "<PartNumber>1</PartNumber>"

    retry = complete_upload(bucket, key, upload_id, [{1, etag}])
    assert retry.status == 200
    assert get_object(bucket, key).resp_body == body
  end

  defp create_bucket(bucket) do
    conn = SigV4Request.signed_conn(:put, "/#{bucket}") |> call()
    assert conn.status == 200
    conn
  end

  defp put_object(bucket, key, body, headers \\ []) do
    conn =
      SigV4Request.signed_conn(:put, "/#{bucket}/#{key}", body: body, headers: headers)
      |> call()

    assert conn.status == 200
    conn
  end

  defp get_object(bucket, key, headers \\ []) do
    SigV4Request.signed_conn(:get, "/#{bucket}/#{key}", headers: headers)
    |> call()
  end

  defp head_object(bucket, key) do
    SigV4Request.signed_conn(:head, "/#{bucket}/#{key}")
    |> call()
  end

  defp initiate_upload(bucket, key) do
    init =
      SigV4Request.signed_conn(:post, "/#{bucket}/#{key}", query: %{"uploads" => ""})
      |> call()

    assert init.status == 200
    upload_id(init.resp_body)
  end

  defp stage_single_part(bucket, key, body) do
    upload_id = initiate_upload(bucket, key)
    etag = upload_part(bucket, key, upload_id, 1, body)
    {upload_id, etag}
  end

  defp upload_part(bucket, key, upload_id, part_number, body) do
    conn =
      SigV4Request.signed_conn(:put, "/#{bucket}/#{key}",
        query: %{"partNumber" => Integer.to_string(part_number), "uploadId" => upload_id},
        body: body
      )
      |> call()

    assert conn.status == 200
    [etag] = get_resp_header(conn, "etag")
    etag
  end

  defp list_parts(bucket, key, upload_id) do
    SigV4Request.signed_conn(:get, "/#{bucket}/#{key}", query: %{"uploadId" => upload_id})
    |> call()
  end

  defp complete_upload(bucket, key, upload_id, parts, headers \\ []) do
    SigV4Request.signed_conn(:post, "/#{bucket}/#{key}",
      query: %{"uploadId" => upload_id},
      body: complete_xml(parts),
      headers: headers
    )
    |> call()
  end

  defp complete_xml(parts) do
    parts =
      Enum.map(parts, fn {part_number, etag} ->
        "<Part><PartNumber>#{part_number}</PartNumber><ETag>#{etag}</ETag></Part>"
      end)

    IO.iodata_to_binary(["<CompleteMultipartUpload>", parts, "</CompleteMultipartUpload>"])
  end

  defp upload_id(xml) do
    [_, rest] = String.split(xml, "<UploadId>")
    [id, _] = String.split(rest, "</UploadId>")
    id
  end

  defp assert_s3_error(conn, status, code) do
    assert conn.status == status
    assert conn.resp_body =~ "<Code>#{code}</Code>"
  end

  defp assert_xml_etag(xml, etag) do
    escaped = String.replace(etag, "\"", "&quot;")
    assert xml =~ "<ETag>#{etag}</ETag>" or xml =~ "<ETag>#{escaped}</ETag>"
  end

  defp restore_env(_key, @unset), do: Application.delete_env(:maxio, :multipart_min_part_size)
  defp restore_env(key, value), do: Application.put_env(:maxio, key, value)
end
