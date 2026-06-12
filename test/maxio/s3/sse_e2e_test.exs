defmodule Maxio.S3.SseE2ETest do
  use Maxio.DataCase, async: false
  import Plug.Conn
  alias Maxio.{Multipart, Objects, Sidecar}
  alias Maxio.Test.SigV4Request
  alias Maxio.S3.Endpoint

  @data_dir Path.join(System.tmp_dir!(), "maxio_sse_e2e")

  setup do
    File.rm_rf(@data_dir)
    File.mkdir_p!(@data_dir)
    prev = Application.get_env(:maxio, :s3)
    Application.put_env(:maxio, :s3, Keyword.put(prev, :data_dir, @data_dir))

    on_exit(fn ->
      Application.put_env(:maxio, :s3, prev)
      File.rm_rf(@data_dir)
    end)

    :ok
  end

  defp call(conn), do: Endpoint.call(conn, Endpoint.init([]))

  defp put_bucket_encryption(bucket) do
    body =
      ~s(<ServerSideEncryptionConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Rule><ApplyServerSideEncryptionByDefault><SSEAlgorithm>AES256</SSEAlgorithm></ApplyServerSideEncryptionByDefault></Rule></ServerSideEncryptionConfiguration>)

    SigV4Request.signed_conn(:put, "/#{bucket}", query: %{"encryption" => ""}, body: body)
    |> call()
  end

  test "PutObject AES256 → 回显 SSE 头；GET 透明解密还原；磁盘字节是密文" do
    SigV4Request.signed_conn(:put, "/sseb") |> call()
    plain = "encrypt me with AES-256-GCM SSE-S3"

    put =
      SigV4Request.signed_conn(:put, "/sseb/secret.txt",
        body: plain,
        headers: [{"x-amz-server-side-encryption", "AES256"}]
      )
      |> call()

    assert put.status == 200
    assert get_resp_header(put, "x-amz-server-side-encryption") == ["AES256"]

    get = SigV4Request.signed_conn(:get, "/sseb/secret.txt") |> call()
    assert get.status == 200
    assert get.resp_body == plain
    assert get_resp_header(get, "x-amz-server-side-encryption") == ["AES256"]

    {:ok, obj} = Objects.get_metadata("sseb", "secret.txt")
    assert obj.size == byte_size(plain)

    sidecar =
      [@data_dir, "sseb", "secret.txt", "meta.json"]
      |> Path.join()
      |> File.read!()
      |> Sidecar.decode!()

    [entry] = sidecar["versions"]
    assert entry["size"] == byte_size(plain)
    assert sidecar["size"] > byte_size(plain)

    head = SigV4Request.signed_conn(:head, "/sseb/secret.txt") |> call()
    assert head.status == 200
    assert get_resp_header(head, "content-length") == [Integer.to_string(byte_size(plain))]

    list = SigV4Request.signed_conn(:get, "/sseb", query: %{"list-type" => "2"}) |> call()
    assert list.status == 200
    assert list.resp_body =~ "<Size>#{byte_size(plain)}</Size>"

    range =
      SigV4Request.signed_conn(:get, "/sseb/secret.txt", headers: [{"range", "bytes=8-13"}])
      |> call()

    assert range.status == 206
    assert range.resp_body == binary_part(plain, 8, 6)
    assert get_resp_header(range, "content-range") == ["bytes 8-13/#{byte_size(plain)}"]
    assert get_resp_header(range, "content-length") == ["6"]
    assert get_resp_header(range, "x-amz-server-side-encryption") == ["AES256"]

    # 磁盘上是密文（不含明文片段）。B6-1 obj-dir 布局：null 版本字节落
    # <data_dir>/sseb/secret.txt/part.0（sidecar 在同目录 meta.json）。
    on_disk = File.read!(Path.join([@data_dir, "sseb", "secret.txt", "part.0"]))
    refute on_disk =~ "encrypt me"
  end

  test "桶默认加密 AES256 → 无头 PUT 也加密" do
    SigV4Request.signed_conn(:put, "/sseb2") |> call()
    assert put_bucket_encryption("sseb2").status == 200

    put = SigV4Request.signed_conn(:put, "/sseb2/o.txt", body: "default-enc") |> call()
    assert get_resp_header(put, "x-amz-server-side-encryption") == ["AES256"]
    get = SigV4Request.signed_conn(:get, "/sseb2/o.txt") |> call()
    assert get.resp_body == "default-enc"
  end

  test "SSE-S3 Range applies to plaintext across encrypted frame boundaries" do
    bucket = "sseboundary"
    key = "large.bin"
    plain = :binary.copy("0123456789abcdef", 5_000)
    first = 65_530
    length = 40
    last = first + length - 1

    SigV4Request.signed_conn(:put, "/#{bucket}") |> call()

    put =
      SigV4Request.signed_conn(:put, "/#{bucket}/#{key}",
        body: plain,
        headers: [{"x-amz-server-side-encryption", "AES256"}]
      )
      |> call()

    assert put.status == 200

    range =
      SigV4Request.signed_conn(:get, "/#{bucket}/#{key}",
        headers: [{"range", "bytes=#{first}-#{last}"}]
      )
      |> call()

    assert range.status == 206
    assert range.resp_body == binary_part(plain, first, length)

    assert get_resp_header(range, "content-range") == [
             "bytes #{first}-#{last}/#{byte_size(plain)}"
           ]

    assert get_resp_header(range, "content-length") == [Integer.to_string(length)]
  end

  test "SSE-S3 open-ended and suffix Ranges apply to plaintext offsets" do
    bucket = "ssepartialranges"
    key = "large.bin"
    plain = :binary.copy("0123456789abcdef", 5_000)
    first = 65_530
    suffix_len = 17

    SigV4Request.signed_conn(:put, "/#{bucket}") |> call()

    put =
      SigV4Request.signed_conn(:put, "/#{bucket}/#{key}",
        body: plain,
        headers: [{"x-amz-server-side-encryption", "AES256"}]
      )
      |> call()

    assert put.status == 200

    open_ended =
      SigV4Request.signed_conn(:get, "/#{bucket}/#{key}", headers: [{"range", "bytes=#{first}-"}])
      |> call()

    assert open_ended.status == 206
    assert open_ended.resp_body == binary_part(plain, first, byte_size(plain) - first)

    assert get_resp_header(open_ended, "content-range") == [
             "bytes #{first}-#{byte_size(plain) - 1}/#{byte_size(plain)}"
           ]

    suffix =
      SigV4Request.signed_conn(:get, "/#{bucket}/#{key}",
        headers: [{"range", "bytes=-#{suffix_len}"}]
      )
      |> call()

    suffix_first = byte_size(plain) - suffix_len

    assert suffix.status == 206
    assert suffix.resp_body == binary_part(plain, suffix_first, suffix_len)

    assert get_resp_header(suffix, "content-range") == [
             "bytes #{suffix_first}-#{byte_size(plain) - 1}/#{byte_size(plain)}"
           ]
  end

  test "SSE-S3 early Range only reads the ciphertext frames that cover the plaintext range" do
    bucket = "sseearlyrange"
    key = "large.bin"
    plain = :binary.copy("abcdef0123456789", 5_000)

    SigV4Request.signed_conn(:put, "/#{bucket}") |> call()

    put =
      SigV4Request.signed_conn(:put, "/#{bucket}/#{key}",
        body: plain,
        headers: [{"x-amz-server-side-encryption", "AES256"}]
      )
      |> call()

    assert put.status == 200

    # Corrupt the second encrypted frame. A Range wholly inside the first plaintext frame must
    # still succeed; otherwise the handler is decrypting unrelated later frames for an early range.
    path = Path.join([@data_dir, bucket, key, "part.0"])
    ciphertext = File.read!(path)
    corrupt_at = Maxio.Crypto.SSE.frame_header_size() + Maxio.Crypto.SSE.plaintext_block_size()
    <<prefix::binary-size(^corrupt_at), byte, suffix::binary>> = ciphertext
    File.write!(path, prefix <> <<Bitwise.bxor(byte, 0xFF)>> <> suffix)

    range =
      SigV4Request.signed_conn(:get, "/#{bucket}/#{key}", headers: [{"range", "bytes=0-15"}])
      |> call()

    assert range.status == 206
    assert range.resp_body == binary_part(plain, 0, 16)
    assert get_resp_header(range, "content-range") == ["bytes 0-15/#{byte_size(plain)}"]
  end

  test "SSE-S3 requested frame corruption returns structured S3 error before success headers" do
    bucket = "ssebadframe"
    key = "large.bin"
    plain = :binary.copy("abcdef0123456789", 5_000)

    SigV4Request.signed_conn(:put, "/#{bucket}") |> call()

    put =
      SigV4Request.signed_conn(:put, "/#{bucket}/#{key}",
        body: plain,
        headers: [{"x-amz-server-side-encryption", "AES256"}]
      )
      |> call()

    assert put.status == 200

    path = Path.join([@data_dir, bucket, key, "part.0"])
    ciphertext = File.read!(path)
    corrupt_at = Maxio.Crypto.SSE.frame_header_size()
    <<prefix::binary-size(^corrupt_at), byte, suffix::binary>> = ciphertext
    File.write!(path, prefix <> <<Bitwise.bxor(byte, 0xFF)>> <> suffix)

    range =
      SigV4Request.signed_conn(:get, "/#{bucket}/#{key}", headers: [{"range", "bytes=0-15"}])
      |> call()

    assert range.status == 500
    assert range.resp_body =~ "<Code>InternalError</Code>"
    assert get_resp_header(range, "content-range") == []
    assert get_resp_header(range, "x-amz-server-side-encryption") == []
  end

  test "SSE-S3 missing requested ciphertext frame returns structured error before success headers" do
    bucket = "ssemissingframe"
    key = "large.bin"
    plain = :binary.copy("abcdef0123456789", 5_000)

    SigV4Request.signed_conn(:put, "/#{bucket}") |> call()

    put =
      SigV4Request.signed_conn(:put, "/#{bucket}/#{key}",
        body: plain,
        headers: [{"x-amz-server-side-encryption", "AES256"}]
      )
      |> call()

    assert put.status == 200

    path = Path.join([@data_dir, bucket, key, "part.0"])
    ciphertext = File.read!(path)

    first_frame_size =
      Maxio.Crypto.SSE.frame_header_size() + Maxio.Crypto.SSE.plaintext_block_size()

    <<first_frame::binary-size(^first_frame_size), _tail::binary>> = ciphertext
    File.write!(path, first_frame)

    range =
      SigV4Request.signed_conn(:get, "/#{bucket}/#{key}",
        headers: [{"range", "bytes=65536-65551"}]
      )
      |> call()

    assert range.status == 500
    assert range.resp_body =~ "<Code>InternalError</Code>"
    assert get_resp_header(range, "content-range") == []
    assert get_resp_header(range, "x-amz-server-side-encryption") == []
  end

  test "aws:kms → 501 NotImplemented（绝不静默当 AES256）" do
    SigV4Request.signed_conn(:put, "/sseb3") |> call()

    res =
      SigV4Request.signed_conn(:put, "/sseb3/o.txt",
        body: "x",
        headers: [{"x-amz-server-side-encryption", "aws:kms"}]
      )
      |> call()

    assert res.status == 501
  end

  test "PutObject rejects target SSE-C key headers even without the algorithm header" do
    SigV4Request.signed_conn(:put, "/ssecustomerput") |> call()

    res =
      SigV4Request.signed_conn(:put, "/ssecustomerput/o.txt",
        body: "x",
        headers: [
          {"x-amz-server-side-encryption-customer-key", "not-used"},
          {"x-amz-server-side-encryption-customer-key-md5", "not-used"}
        ]
      )
      |> call()

    assert res.status == 501
    assert res.resp_body =~ "<Code>NotImplemented</Code>"
    assert {:error, :not_found} = Objects.get_metadata("ssecustomerput", "o.txt")
  end

  test "CopyObject rejects target SSE-C key headers even without the algorithm header" do
    SigV4Request.signed_conn(:put, "/ssecustomercopy") |> call()
    SigV4Request.signed_conn(:put, "/ssecustomercopy/src.txt", body: "x") |> call()

    res =
      SigV4Request.signed_conn(:put, "/ssecustomercopy/dst.txt",
        headers: [
          {"x-amz-copy-source", "/ssecustomercopy/src.txt"},
          {"x-amz-server-side-encryption-customer-key", "not-used"},
          {"x-amz-server-side-encryption-customer-key-md5", "not-used"}
        ]
      )
      |> call()

    assert res.status == 501
    assert res.resp_body =~ "<Code>NotImplemented</Code>"
    assert {:error, :not_found} = Objects.get_metadata("ssecustomercopy", "dst.txt")
  end

  test "CreateMultipartUpload rejects target SSE-C key headers before creating a session" do
    SigV4Request.signed_conn(:put, "/ssecustomermpu") |> call()

    res =
      SigV4Request.signed_conn(:post, "/ssecustomermpu/o.txt",
        query: %{"uploads" => ""},
        headers: [
          {"x-amz-server-side-encryption-customer-key", "not-used"},
          {"x-amz-server-side-encryption-customer-key-md5", "not-used"}
        ]
      )
      |> call()

    assert res.status == 501
    assert res.resp_body =~ "<Code>NotImplemented</Code>"
    assert Multipart.list_uploads("ssecustomermpu").uploads == []
  end

  test "CreateMultipartUpload AES256 encrypts completed object and stores SSE metadata" do
    bucket = "ssempuenc"
    key = "multi.txt"
    plain = "multipart bytes through SSE-S3"

    SigV4Request.signed_conn(:put, "/#{bucket}") |> call()

    init =
      SigV4Request.signed_conn(:post, "/#{bucket}/#{key}",
        query: %{"uploads" => ""},
        headers: [{"x-amz-server-side-encryption", "AES256"}]
      )
      |> call()

    assert init.status == 200
    assert get_resp_header(init, "x-amz-server-side-encryption") == ["AES256"]
    upload_id = upload_id(init.resp_body)
    {:ok, upload} = Multipart.get_upload(bucket, key, upload_id)
    assert upload.sse_algorithm == "AES256"

    upload_part =
      SigV4Request.signed_conn(:put, "/#{bucket}/#{key}",
        query: %{"partNumber" => "1", "uploadId" => upload_id},
        body: plain
      )
      |> call()

    assert upload_part.status == 200
    [part_etag] = get_resp_header(upload_part, "etag")

    complete_body =
      "<CompleteMultipartUpload><Part><PartNumber>1</PartNumber>" <>
        "<ETag>#{part_etag}</ETag></Part></CompleteMultipartUpload>"

    complete =
      SigV4Request.signed_conn(:post, "/#{bucket}/#{key}",
        query: %{"uploadId" => upload_id},
        body: complete_body
      )
      |> call()

    assert complete.status == 200
    assert get_resp_header(complete, "x-amz-server-side-encryption") == ["AES256"]

    get = SigV4Request.signed_conn(:get, "/#{bucket}/#{key}") |> call()
    assert get.status == 200
    assert get.resp_body == plain
    assert get_resp_header(get, "x-amz-server-side-encryption") == ["AES256"]

    range =
      SigV4Request.signed_conn(:get, "/#{bucket}/#{key}", headers: [{"range", "bytes=10-15"}])
      |> call()

    assert range.status == 206
    assert range.resp_body == binary_part(plain, 10, 6)
    assert get_resp_header(range, "content-range") == ["bytes 10-15/#{byte_size(plain)}"]
    assert get_resp_header(range, "content-length") == ["6"]

    {:ok, obj} = Objects.get_metadata(bucket, key)
    assert obj.sse_algorithm == "AES256"
    assert is_map(obj.sse_envelope)

    on_disk = File.read!(Path.join([@data_dir, bucket, key, "part.0"]))
    refute on_disk =~ plain

    head = SigV4Request.signed_conn(:head, "/#{bucket}/#{key}") |> call()
    assert head.status == 200
    assert get_resp_header(head, "content-length") == [Integer.to_string(byte_size(plain))]

    list = SigV4Request.signed_conn(:get, "/#{bucket}", query: %{"list-type" => "2"}) |> call()
    assert list.status == 200
    assert list.resp_body =~ "<Size>#{byte_size(plain)}</Size>"

    sidecar =
      [@data_dir, bucket, key, "meta.json"]
      |> Path.join()
      |> File.read!()
      |> Sidecar.decode!()

    [entry] = sidecar["versions"]
    assert entry["size"] == byte_size(plain)
    assert sidecar["size"] > byte_size(plain)
  end

  test "bucket default AES256 applies to CreateMultipartUpload sessions" do
    bucket = "ssempudefault"
    key = "default.txt"

    SigV4Request.signed_conn(:put, "/#{bucket}") |> call()
    assert put_bucket_encryption(bucket).status == 200

    init =
      SigV4Request.signed_conn(:post, "/#{bucket}/#{key}", query: %{"uploads" => ""})
      |> call()

    assert init.status == 200
    assert get_resp_header(init, "x-amz-server-side-encryption") == ["AES256"]

    upload_id = upload_id(init.resp_body)
    {:ok, upload} = Multipart.get_upload(bucket, key, upload_id)
    assert upload.sse_algorithm == "AES256"
  end

  test "GetBucketEncryption 无配置 → 404" do
    SigV4Request.signed_conn(:put, "/sseb4") |> call()
    res = SigV4Request.signed_conn(:get, "/sseb4", query: %{"encryption" => ""}) |> call()
    assert res.status == 404
    assert res.resp_body =~ "ServerSideEncryptionConfigurationNotFoundError"
  end

  defp upload_id(xml) do
    [_, upload_id] = Regex.run(~r/<UploadId>([^<]+)<\/UploadId>/, xml)
    upload_id
  end
end
