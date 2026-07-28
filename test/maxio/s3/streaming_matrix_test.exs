defmodule Maxio.S3.StreamingMatrixTest do
  @moduledoc """
  Compact compatibility matrix for SigV4 aws-chunked data-plane uploads.

  This suite pins the production-critical contract that verified decoded bytes,
  not transfer frames, reach object storage, that checksum trailers are honored,
  and failed chunk signatures/checksums do not commit objects or multipart parts.
  """

  use Maxio.DataCase, async: false

  import Plug.Conn

  alias Maxio.S3.Endpoint
  alias Maxio.Test.SigV4Request

  @data_dir Path.join(System.tmp_dir!(), "maxio_streaming_matrix")
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

  test "aws-chunked PutObject matrix stores decoded bytes and exposes object metadata" do
    bucket = "streamput"
    key = "large.bin"
    body = large_body()

    create_bucket(bucket)

    put =
      SigV4Request.signed_chunked_conn(:put, "/#{bucket}/#{key}", body, chunk_size: 65_536)
      |> call()

    assert put.status == 200
    assert get_resp_header(put, "etag") == [md5_etag(body)]

    head = head_object(bucket, key)
    assert head.status == 200
    assert get_resp_header(head, "content-length") == [Integer.to_string(byte_size(body))]
    assert get_resp_header(head, "content-encoding") == []

    get = get_object(bucket, key)
    assert get.status == 200
    assert byte_size(get.resp_body) == byte_size(body)
    assert sha256(get.resp_body) == sha256(body)
  end

  test "aws-chunked PutObject repeated soak stores decoded bytes for varied chunking" do
    bucket = "streamsoak"
    create_bucket(bucket)

    cases = [
      {"tiny.txt", streaming_body("tiny", 1), 1},
      {"small.txt", streaming_body("small", 3), 3},
      {"medium.bin", streaming_body("medium", 67), 97},
      {"wide.bin", streaming_body("wide", 2_401), 8_191},
      {"window-crossing.bin", streaming_body("window", 38_000), 65_536},
      {"large-repeat.bin", streaming_body("large", 72_000), 131_072}
    ]

    for {key, body, chunk_size} <- cases do
      put =
        SigV4Request.signed_chunked_conn(:put, "/#{bucket}/#{key}", body, chunk_size: chunk_size)
        |> call()

      assert put.status == 200
      assert get_resp_header(put, "etag") == [md5_etag(body)]

      head = head_object(bucket, key)
      assert head.status == 200
      assert get_resp_header(head, "content-length") == [Integer.to_string(byte_size(body))]
      assert get_resp_header(head, "content-encoding") == []

      get = get_object(bucket, key)
      assert get.status == 200
      assert byte_size(get.resp_body) == byte_size(body)
      assert sha256(get.resp_body) == sha256(body)
    end
  end

  test "aws-chunked PutObject signature failure does not create or replace objects" do
    bucket = "streamputbad"
    key = "object.txt"
    old_body = "old stable bytes"
    new_body = "new bytes that must not commit"

    create_bucket(bucket)

    missing_bad =
      SigV4Request.signed_chunked_conn(:put, "/#{bucket}/missing.txt", "missing bad bytes",
        chunk_size: byte_size("missing bad bytes"),
        tamper: &String.replace(&1, "missing bad", "MISSING bad", global: false)
      )
      |> call()

    assert_s3_error(missing_bad, 403, "SignatureDoesNotMatch")
    assert_s3_error(get_object(bucket, "missing.txt"), 404, "NoSuchKey")

    put_object(bucket, key, old_body)
    [old_etag] = get_resp_header(head_object(bucket, key), "etag")

    bad =
      SigV4Request.signed_chunked_conn(:put, "/#{bucket}/#{key}", new_body,
        chunk_size: byte_size(new_body),
        tamper: &String.replace(&1, "new bytes", "bad bytes", global: false)
      )
      |> call()

    assert_s3_error(bad, 403, "SignatureDoesNotMatch")

    get = get_object(bucket, key)
    assert get.status == 200
    assert get.resp_body == old_body
    assert get_resp_header(get, "etag") == [old_etag]
  end

  test "aws-chunked decoded length mismatch fails closed without creating an object" do
    bucket = "streamlen"
    key = "short.txt"

    create_bucket(bucket)

    bad =
      SigV4Request.signed_chunked_conn(:put, "/#{bucket}/#{key}", "actual bytes",
        decoded_length_override: 999
      )
      |> call()

    assert_s3_error(bad, 400, "IncompleteBody")
    assert_s3_error(get_object(bucket, key), 404, "NoSuchKey")
  end

  test "aws-chunked PutObject checksum trailers cover unsigned signed and bad digest paths" do
    bucket = "streamtrail"
    create_bucket(bucket)

    variants = [
      {"unsigned.txt", "unsigned trailer body-" <> String.duplicate("u", 257), []},
      {"signed.txt", "signed trailer body-" <> String.duplicate("s", 383),
       [streaming_payload_hash: "STREAMING-AWS4-HMAC-SHA256-PAYLOAD-TRAILER"]}
    ]

    for {key, body, extra_opts} <- variants do
      checksum = hash_b64(:sha256, body)

      put =
        SigV4Request.signed_chunked_conn(
          :put,
          "/#{bucket}/#{key}",
          body,
          Keyword.merge(
            [
              chunk_size: 37,
              trailer_headers: [{"x-amz-checksum-sha256", checksum}]
            ],
            extra_opts
          )
        )
        |> call()

      assert put.status == 200
      assert get_resp_header(put, "x-amz-checksum-sha256") == [checksum]

      head = head_object(bucket, key)
      assert head.status == 200
      assert get_resp_header(head, "content-length") == [Integer.to_string(byte_size(body))]
      assert get_resp_header(head, "content-encoding") == []

      get = get_object(bucket, key)
      assert get.status == 200
      assert get.resp_body == body
    end

    bad =
      SigV4Request.signed_chunked_conn(:put, "/#{bucket}/bad.txt", "real trailer bytes",
        chunk_size: 5,
        trailer_headers: [{"x-amz-checksum-sha256", hash_b64(:sha256, "different bytes")}]
      )
      |> call()

    assert_s3_error(bad, 400, "BadDigest")
    assert_s3_error(get_object(bucket, "bad.txt"), 404, "NoSuchKey")
  end

  test "aws-chunked UploadPart matrix completes multipart object from decoded parts" do
    bucket = "streammpu"
    key = "object.bin"

    create_bucket(bucket)
    upload_id = initiate_upload(bucket, key)

    part1 = "streaming part one"
    part2 = String.duplicate("part-two-", 32)

    etag1 = upload_chunked_part(bucket, key, upload_id, 1, part1, chunk_size: 5)
    etag2 = upload_chunked_part(bucket, key, upload_id, 2, part2, chunk_size: 17)

    parts = list_parts(bucket, key, upload_id)
    assert parts.status == 200
    assert parts.resp_body =~ "<PartNumber>1</PartNumber>"
    assert parts.resp_body =~ "<PartNumber>2</PartNumber>"

    complete = complete_upload(bucket, key, upload_id, [{1, etag1}, {2, etag2}])
    assert complete.status == 200

    get = get_object(bucket, key)
    assert get.status == 200
    assert get.resp_body == part1 <> part2
  end

  test "aws-chunked UploadPart signature failure leaves upload retryable and no failed part listed" do
    bucket = "streammpubad"
    key = "object.bin"

    create_bucket(bucket)
    upload_id = initiate_upload(bucket, key)

    etag1 = upload_chunked_part(bucket, key, upload_id, 1, "good-one", chunk_size: 4)

    bad =
      SigV4Request.signed_chunked_conn(:put, "/#{bucket}/#{key}", "bad-two",
        query: %{"partNumber" => "2", "uploadId" => upload_id},
        chunk_size: byte_size("bad-two"),
        tamper: &String.replace(&1, "bad-two", "BAD-two", global: false)
      )
      |> call()

    assert_s3_error(bad, 403, "SignatureDoesNotMatch")

    parts_after_failure = list_parts(bucket, key, upload_id)
    assert parts_after_failure.status == 200
    assert parts_after_failure.resp_body =~ "<PartNumber>1</PartNumber>"
    refute parts_after_failure.resp_body =~ "<PartNumber>2</PartNumber>"

    etag2 = upload_chunked_part(bucket, key, upload_id, 2, "good-two", chunk_size: 4)
    complete = complete_upload(bucket, key, upload_id, [{1, etag1}, {2, etag2}])
    assert complete.status == 200

    get = get_object(bucket, key)
    assert get.status == 200
    assert get.resp_body == "good-onegood-two"
  end

  test "aws-chunked UploadPart checksum trailers complete object and bad digest is retryable" do
    bucket = "streammptrail"
    key = "object.bin"

    create_bucket(bucket)
    upload_id = initiate_upload(bucket, key, [{"x-amz-checksum-algorithm", "SHA256"}])

    part1 = "unsigned trailer part-" <> String.duplicate("one-", 19)
    checksum1 = hash_b64(:sha256, part1)

    part1_conn =
      upload_chunked_part_conn(bucket, key, upload_id, 1, part1,
        chunk_size: 11,
        trailer_headers: [{"x-amz-checksum-sha256", checksum1}]
      )

    assert part1_conn.status == 200
    assert get_resp_header(part1_conn, "x-amz-checksum-sha256") == [checksum1]
    [etag1] = get_resp_header(part1_conn, "etag")

    bad =
      SigV4Request.signed_chunked_conn(:put, "/#{bucket}/#{key}", "bad trailer part",
        query: %{"partNumber" => "2", "uploadId" => upload_id},
        chunk_size: 7,
        trailer_headers: [{"x-amz-checksum-sha256", hash_b64(:sha256, "different part")}]
      )
      |> call()

    assert_s3_error(bad, 400, "BadDigest")

    parts_after_failure = list_parts(bucket, key, upload_id)
    assert parts_after_failure.status == 200
    assert parts_after_failure.resp_body =~ "<PartNumber>1</PartNumber>"
    refute parts_after_failure.resp_body =~ "<PartNumber>2</PartNumber>"

    part2 = "signed trailer part-" <> String.duplicate("two-", 23)
    checksum2 = hash_b64(:sha256, part2)

    part2_conn =
      upload_chunked_part_conn(bucket, key, upload_id, 2, part2,
        chunk_size: 13,
        trailer_headers: [{"x-amz-checksum-sha256", checksum2}],
        streaming_payload_hash: "STREAMING-AWS4-HMAC-SHA256-PAYLOAD-TRAILER"
      )

    assert part2_conn.status == 200
    assert get_resp_header(part2_conn, "x-amz-checksum-sha256") == [checksum2]
    [etag2] = get_resp_header(part2_conn, "etag")

    complete = complete_upload(bucket, key, upload_id, [{1, etag1}, {2, etag2}])
    assert complete.status == 200

    get = get_object(bucket, key)
    assert get.status == 200
    assert get.resp_body == part1 <> part2
  end

  defp create_bucket(bucket) do
    conn = SigV4Request.signed_conn(:put, "/#{bucket}") |> call()
    assert conn.status == 200
    conn
  end

  defp put_object(bucket, key, body) do
    conn = SigV4Request.signed_conn(:put, "/#{bucket}/#{key}", body: body) |> call()
    assert conn.status == 200
    conn
  end

  defp get_object(bucket, key) do
    SigV4Request.signed_conn(:get, "/#{bucket}/#{key}")
    |> call()
  end

  defp head_object(bucket, key) do
    SigV4Request.signed_conn(:head, "/#{bucket}/#{key}")
    |> call()
  end

  defp initiate_upload(bucket, key, headers \\ []) do
    init =
      SigV4Request.signed_conn(:post, "/#{bucket}/#{key}",
        query: %{"uploads" => ""},
        headers: headers
      )
      |> call()

    assert init.status == 200
    upload_id(init.resp_body)
  end

  defp upload_chunked_part(bucket, key, upload_id, part_number, body, opts) do
    conn = upload_chunked_part_conn(bucket, key, upload_id, part_number, body, opts)

    assert conn.status == 200
    [etag] = get_resp_header(conn, "etag")
    etag
  end

  defp upload_chunked_part_conn(bucket, key, upload_id, part_number, body, opts) do
    chunked_opts =
      [
        query: %{"partNumber" => Integer.to_string(part_number), "uploadId" => upload_id},
        chunk_size: Keyword.fetch!(opts, :chunk_size)
      ] ++ Keyword.take(opts, [:trailer_headers, :streaming_payload_hash])

    SigV4Request.signed_chunked_conn(:put, "/#{bucket}/#{key}", body, chunked_opts)
    |> call()
  end

  defp list_parts(bucket, key, upload_id) do
    SigV4Request.signed_conn(:get, "/#{bucket}/#{key}", query: %{"uploadId" => upload_id})
    |> call()
  end

  defp complete_upload(bucket, key, upload_id, parts) do
    SigV4Request.signed_conn(:post, "/#{bucket}/#{key}",
      query: %{"uploadId" => upload_id},
      body: complete_xml(parts)
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

  defp large_body do
    String.duplicate("0123456789abcdef", 70_000) <> "tail"
  end

  defp streaming_body(label, repeat) do
    Enum.map_join(1..repeat, "|", fn index ->
      "#{label}:#{index}:abcdefghijklmnopqrstuvwxyz0123456789"
    end)
  end

  defp md5_etag(body),
    do: "\"" <> (:crypto.hash(:md5, body) |> Base.encode16(case: :lower)) <> "\""

  defp sha256(body), do: :crypto.hash(:sha256, body)
  defp hash_b64(algorithm, body), do: :crypto.hash(algorithm, body) |> Base.encode64()

  defp restore_env(_key, @unset), do: Application.delete_env(:maxio, :multipart_min_part_size)
  defp restore_env(key, value), do: Application.put_env(:maxio, key, value)
end
