defmodule Maxio.S3.StreamingStressMatrixTest do
  @moduledoc """
  Opt-in stress matrix for production-style SigV4 aws-chunked evidence.

  The default profile is intentionally local-safe. Operators can increase object
  size/repetitions via `Maxio.Compat.StreamingStressConfig` environment variables
  and keep the same parameters visible in `mix maxio.compat.matrix` artifacts.
  """

  use Maxio.DataCase, async: false

  import Plug.Conn

  alias Maxio.Compat.StreamingStressConfig
  alias Maxio.S3.Endpoint
  alias Maxio.Test.SigV4Request

  @moduletag timeout: :infinity

  @data_dir Path.join(System.tmp_dir!(), "maxio_streaming_stress_matrix")
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

    {:ok, stress: StreamingStressConfig.load!()}
  end

  defp call(conn), do: Endpoint.call(conn, Endpoint.init([]))

  test "repeated large aws-chunked PutObject stress preserves decoded object bytes", %{
    stress: stress
  } do
    bucket = "stressput"
    create_bucket(bucket)

    for index <- 1..stress.repetitions do
      key = "objects/#{index}.bin"
      body = stress_body("put", index, stress.object_bytes)
      chunk_size = chunk_size_for(stress.chunk_sizes, index)

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

  test "multipart aws-chunked trailer stress keeps failed retries out of committed state", %{
    stress: stress
  } do
    bucket = "stressmptrail"
    key = "object.bin"
    part_bytes = max(div(stress.object_bytes, 2), 1)

    create_bucket(bucket)
    upload_id = initiate_upload(bucket, key, [{"x-amz-checksum-algorithm", "SHA256"}])

    part1 = stress_body("part-one", 1, part_bytes)
    checksum1 = hash_b64(:sha256, part1)

    part1_conn =
      upload_chunked_part_conn(bucket, key, upload_id, 1, part1,
        chunk_size: chunk_size_for(stress.chunk_sizes, 1),
        trailer_headers: [{"x-amz-checksum-sha256", checksum1}]
      )

    assert part1_conn.status == 200
    assert get_resp_header(part1_conn, "x-amz-checksum-sha256") == [checksum1]
    [etag1] = get_resp_header(part1_conn, "etag")

    for attempt <- 1..stress.failure_attempts do
      bad_body = stress_body("bad-part", attempt, min(part_bytes, 1024 * 1024))

      bad =
        SigV4Request.signed_chunked_conn(:put, "/#{bucket}/#{key}", bad_body,
          query: %{"partNumber" => "2", "uploadId" => upload_id},
          chunk_size: chunk_size_for(stress.chunk_sizes, attempt + 1),
          trailer_headers: [
            {"x-amz-checksum-sha256", hash_b64(:sha256, "wrong checksum #{attempt}")}
          ]
        )
        |> call()

      assert_s3_error(bad, 400, "BadDigest")

      parts_after_failure = list_parts(bucket, key, upload_id)
      assert parts_after_failure.status == 200
      assert parts_after_failure.resp_body =~ "<PartNumber>1</PartNumber>"
      refute parts_after_failure.resp_body =~ "<PartNumber>2</PartNumber>"
    end

    part2 = stress_body("part-two", 2, part_bytes)
    checksum2 = hash_b64(:sha256, part2)

    part2_conn =
      upload_chunked_part_conn(bucket, key, upload_id, 2, part2,
        chunk_size: chunk_size_for(stress.chunk_sizes, stress.repetitions + 1),
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
    assert byte_size(get.resp_body) == byte_size(part1) + byte_size(part2)
    assert sha256(get.resp_body) == sha256(part1 <> part2)
  end

  test "concurrent aws-chunked PutObject and MPU stress preserves committed bytes", %{
    stress: stress
  } do
    put_bucket = "stressconcput"
    mpu_bucket = "stressconcmpu"
    create_bucket(put_bucket)
    create_bucket(mpu_bucket)

    put_bytes = scaled_bytes(stress.object_bytes, stress.concurrency * 2)

    put_results =
      1..stress.concurrency
      |> Task.async_stream(&concurrent_put_object(put_bucket, &1, stress, put_bytes),
        max_concurrency: stress.concurrency,
        timeout: :infinity,
        ordered: false
      )
      |> collect_task_results()

    assert length(put_results) == stress.concurrency
    assert Enum.all?(put_results, &(&1.put_status == 200))
    assert Enum.all?(put_results, &(&1.head_status == 200))
    assert Enum.all?(put_results, &(&1.get_status == 200))
    assert Enum.all?(put_results, &(&1.expected_sha256 == &1.actual_sha256))

    mpu_bytes = scaled_bytes(stress.object_bytes, stress.multipart_uploads * 4)

    mpu_results =
      1..stress.multipart_uploads
      |> Task.async_stream(&concurrent_multipart_upload(mpu_bucket, &1, stress, mpu_bytes),
        max_concurrency: stress.concurrency,
        timeout: :infinity,
        ordered: false
      )
      |> collect_task_results()

    assert length(mpu_results) == stress.multipart_uploads
    assert Enum.all?(mpu_results, &(&1.complete_status == 200))
    assert Enum.all?(mpu_results, &(&1.get_status == 200))
    assert Enum.all?(mpu_results, &(&1.expected_sha256 == &1.actual_sha256))
  end

  defp create_bucket(bucket) do
    conn = SigV4Request.signed_conn(:put, "/#{bucket}") |> call()
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

  defp initiate_upload(bucket, key, headers) do
    init =
      SigV4Request.signed_conn(:post, "/#{bucket}/#{key}",
        query: %{"uploads" => ""},
        headers: headers
      )
      |> call()

    assert init.status == 200
    upload_id(init.resp_body)
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

  defp concurrent_put_object(bucket, index, stress, body_bytes) do
    key = "concurrent/put-#{index}.bin"
    body = stress_body("concurrent-put", index, body_bytes)

    put =
      SigV4Request.signed_chunked_conn(:put, "/#{bucket}/#{key}", body,
        chunk_size: chunk_size_for(stress.chunk_sizes, index)
      )
      |> call()

    head = head_object(bucket, key)
    get = get_object(bucket, key)

    %{
      key: key,
      put_status: put.status,
      head_status: head.status,
      get_status: get.status,
      expected_sha256: sha256(body),
      actual_sha256: sha256(get.resp_body || "")
    }
  end

  defp concurrent_multipart_upload(bucket, index, stress, part_bytes) do
    key = "concurrent/mpu-#{index}.bin"
    upload_id = initiate_upload(bucket, key, [{"x-amz-checksum-algorithm", "SHA256"}])

    part1 = stress_body("concurrent-part-one", index, part_bytes)
    checksum1 = hash_b64(:sha256, part1)

    part1_conn =
      upload_chunked_part_conn(bucket, key, upload_id, 1, part1,
        chunk_size: chunk_size_for(stress.chunk_sizes, index),
        trailer_headers: [{"x-amz-checksum-sha256", checksum1}]
      )

    assert part1_conn.status == 200
    [etag1] = get_resp_header(part1_conn, "etag")

    bad =
      SigV4Request.signed_chunked_conn(:put, "/#{bucket}/#{key}", "bad concurrent part #{index}",
        query: %{"partNumber" => "2", "uploadId" => upload_id},
        chunk_size: chunk_size_for(stress.chunk_sizes, index + 1),
        trailer_headers: [{"x-amz-checksum-sha256", hash_b64(:sha256, "wrong #{index}")}]
      )
      |> call()

    assert_s3_error(bad, 400, "BadDigest")

    parts_after_failure = list_parts(bucket, key, upload_id)
    assert parts_after_failure.status == 200
    assert parts_after_failure.resp_body =~ "<PartNumber>1</PartNumber>"
    refute parts_after_failure.resp_body =~ "<PartNumber>2</PartNumber>"

    part2 = stress_body("concurrent-part-two", index, part_bytes)
    checksum2 = hash_b64(:sha256, part2)

    part2_conn =
      upload_chunked_part_conn(bucket, key, upload_id, 2, part2,
        chunk_size: chunk_size_for(stress.chunk_sizes, index + 2),
        trailer_headers: [{"x-amz-checksum-sha256", checksum2}],
        streaming_payload_hash: "STREAMING-AWS4-HMAC-SHA256-PAYLOAD-TRAILER"
      )

    assert part2_conn.status == 200
    [etag2] = get_resp_header(part2_conn, "etag")

    complete = complete_upload(bucket, key, upload_id, [{1, etag1}, {2, etag2}])
    get = get_object(bucket, key)

    %{
      key: key,
      complete_status: complete.status,
      get_status: get.status,
      expected_sha256: sha256(part1 <> part2),
      actual_sha256: sha256(get.resp_body || "")
    }
  end

  defp collect_task_results(stream) do
    Enum.map(stream, fn
      {:ok, result} -> result
      {:exit, reason} -> flunk("streaming stress task exited: #{inspect(reason)}")
    end)
  end

  defp chunk_size_for(chunk_sizes, index) do
    Enum.at(chunk_sizes, rem(index - 1, length(chunk_sizes)))
  end

  defp scaled_bytes(object_bytes, divisor), do: max(div(object_bytes, max(divisor, 1)), 1)

  defp stress_body(label, index, target_bytes) do
    seed = "#{label}:#{index}:0123456789abcdefghijklmnopqrstuvwxyz:"
    repeats = div(target_bytes, byte_size(seed)) + 1
    seed |> String.duplicate(repeats) |> binary_part(0, target_bytes)
  end

  defp md5_etag(body),
    do: "\"" <> (:crypto.hash(:md5, body) |> Base.encode16(case: :lower)) <> "\""

  defp sha256(body), do: :crypto.hash(:sha256, body)
  defp hash_b64(algorithm, body), do: :crypto.hash(algorithm, body) |> Base.encode64()

  defp restore_env(_key, @unset), do: Application.delete_env(:maxio, :multipart_min_part_size)
  defp restore_env(key, value), do: Application.put_env(:maxio, key, value)
end
