defmodule Maxio.S3.SseE2ETest do
  use Maxio.DataCase, async: false
  import Plug.Conn
  alias Maxio.{BucketConfigs, Multipart, Objects, Sidecar}
  alias Maxio.Test.SigV4Request
  alias Maxio.S3.{Endpoint, SSE}

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

  defp checksum_b64(algorithm, body), do: :crypto.hash(algorithm, body) |> Base.encode64()

  defp aes256_bucket_encryption_xml do
    ~s(<ServerSideEncryptionConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Rule><ApplyServerSideEncryptionByDefault><SSEAlgorithm>AES256</SSEAlgorithm></ApplyServerSideEncryptionByDefault></Rule></ServerSideEncryptionConfiguration>)
  end

  defp kms_bucket_encryption_xml(key_id) do
    ~s(<ServerSideEncryptionConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Rule><ApplyServerSideEncryptionByDefault><SSEAlgorithm>aws:kms</SSEAlgorithm><KMSMasterKeyID>#{key_id}</KMSMasterKeyID></ApplyServerSideEncryptionByDefault><BucketKeyEnabled>true</BucketKeyEnabled></Rule></ServerSideEncryptionConfiguration>)
  end

  defp put_bucket_encryption(bucket) do
    body = aes256_bucket_encryption_xml()

    SigV4Request.signed_conn(:put, "/#{bucket}", query: %{"encryption" => ""}, body: body)
    |> call()
  end

  defp put_bucket_kms_encryption(bucket, key_id, bucket_key_enabled \\ true) do
    body =
      ~s(<ServerSideEncryptionConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Rule><ApplyServerSideEncryptionByDefault><SSEAlgorithm>aws:kms</SSEAlgorithm><KMSMasterKeyID>#{key_id}</KMSMasterKeyID></ApplyServerSideEncryptionByDefault><BucketKeyEnabled>#{bucket_key_enabled}</BucketKeyEnabled></Rule></ServerSideEncryptionConfiguration>)

    SigV4Request.signed_conn(:put, "/#{bucket}", query: %{"encryption" => ""}, body: body)
    |> call()
  end

  defp put_bucket_dsse_encryption(bucket, key_id, bucket_key_enabled \\ false) do
    body =
      ~s(<ServerSideEncryptionConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Rule><ApplyServerSideEncryptionByDefault><SSEAlgorithm>aws:kms:dsse</SSEAlgorithm><KMSMasterKeyID>#{key_id}</KMSMasterKeyID></ApplyServerSideEncryptionByDefault><BucketKeyEnabled>#{bucket_key_enabled}</BucketKeyEnabled></Rule></ServerSideEncryptionConfiguration>)

    SigV4Request.signed_conn(:put, "/#{bucket}", query: %{"encryption" => ""}, body: body)
    |> call()
  end

  defp sse_c_headers(customer_key) do
    [
      {"x-amz-server-side-encryption-customer-algorithm", "AES256"},
      {"x-amz-server-side-encryption-customer-key", Base.encode64(customer_key)},
      {"x-amz-server-side-encryption-customer-key-md5",
       :crypto.hash(:md5, customer_key) |> Base.encode64()}
    ]
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

  test "bucket default aws:kms applies to objects without explicit SSE headers" do
    bucket = "ssekmsdefault"
    key_id = "arn:aws:kms:us-east-1:000000000000:key/bucket-default"

    SigV4Request.signed_conn(:put, "/#{bucket}") |> call()
    assert put_bucket_kms_encryption(bucket, key_id).status == 200

    get_cfg = SigV4Request.signed_conn(:get, "/#{bucket}", query: %{"encryption" => ""}) |> call()
    assert get_cfg.status == 200
    assert get_cfg.resp_body =~ "<SSEAlgorithm>aws:kms</SSEAlgorithm>"
    assert get_cfg.resp_body =~ "<KMSMasterKeyID>#{key_id}</KMSMasterKeyID>"
    assert get_cfg.resp_body =~ "<BucketKeyEnabled>true</BucketKeyEnabled>"

    put = SigV4Request.signed_conn(:put, "/#{bucket}/default.txt", body: "default-kms") |> call()
    assert put.status == 200
    assert get_resp_header(put, "x-amz-server-side-encryption") == ["aws:kms"]
    assert get_resp_header(put, "x-amz-server-side-encryption-aws-kms-key-id") == [key_id]

    get = SigV4Request.signed_conn(:get, "/#{bucket}/default.txt") |> call()
    assert get.status == 200
    assert get.resp_body == "default-kms"
    assert get_resp_header(get, "x-amz-server-side-encryption") == ["aws:kms"]
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

  test "PutObject aws:kms encrypts bytes and reads transparently" do
    bucket = "ssekms1"
    key = "kms.txt"
    plain = String.duplicate("kms plaintext ", 8_000)
    key_id = "arn:aws:kms:us-east-1:000000000000:key/local-1"
    context_b64 = Base.encode64(~s({"bucket":"#{bucket}","key":"#{key}"}))

    SigV4Request.signed_conn(:put, "/#{bucket}") |> call()

    put =
      SigV4Request.signed_conn(:put, "/#{bucket}/#{key}",
        body: plain,
        headers: [
          {"x-amz-server-side-encryption", "aws:kms"},
          {"x-amz-server-side-encryption-aws-kms-key-id", key_id},
          {"x-amz-server-side-encryption-context", context_b64},
          {"x-amz-server-side-encryption-bucket-key-enabled", "true"}
        ]
      )
      |> call()

    assert put.status == 200
    assert get_resp_header(put, "x-amz-server-side-encryption") == ["aws:kms"]
    assert get_resp_header(put, "x-amz-server-side-encryption-aws-kms-key-id") == [key_id]
    assert get_resp_header(put, "x-amz-server-side-encryption-bucket-key-enabled") == ["true"]

    {:ok, obj} = Objects.get_metadata(bucket, key)
    assert obj.size == byte_size(plain)
    assert obj.sse_algorithm == "aws:kms"
    assert obj.sse_envelope["mode"] == "SSE-KMS"
    assert obj.sse_envelope["kms_key_id"] == key_id
    assert obj.sse_envelope["kms_encryption_context_b64"] == context_b64
    refute Map.has_key?(obj.sse_envelope, "plaintext_key")

    ciphertext = File.read!(Path.join([@data_dir, bucket, key, "part.0"]))
    refute ciphertext =~ "kms plaintext"

    get = SigV4Request.signed_conn(:get, "/#{bucket}/#{key}") |> call()
    assert get.status == 200
    assert get.resp_body == plain
    assert get_resp_header(get, "x-amz-server-side-encryption") == ["aws:kms"]
    assert get_resp_header(get, "x-amz-server-side-encryption-aws-kms-key-id") == [key_id]

    range =
      SigV4Request.signed_conn(:get, "/#{bucket}/#{key}", headers: [{"range", "bytes=5-17"}])
      |> call()

    assert range.status == 206
    assert range.resp_body == binary_part(plain, 5, 13)
    assert get_resp_header(range, "x-amz-server-side-encryption") == ["aws:kms"]

    head = SigV4Request.signed_conn(:head, "/#{bucket}/#{key}") |> call()
    assert head.status == 200
    assert get_resp_header(head, "content-length") == [Integer.to_string(byte_size(plain))]
    assert get_resp_header(head, "x-amz-server-side-encryption") == ["aws:kms"]
  end

  test "SSE-KMS reads reject encryption request headers" do
    bucket = "ssekmsreadheaders"
    key = "kms.txt"

    SigV4Request.signed_conn(:put, "/#{bucket}") |> call()

    put =
      SigV4Request.signed_conn(:put, "/#{bucket}/#{key}",
        body: "kms plaintext",
        headers: [{"x-amz-server-side-encryption", "aws:kms"}]
      )
      |> call()

    assert put.status == 200

    bad_get =
      SigV4Request.signed_conn(:get, "/#{bucket}/#{key}",
        headers: [{"x-amz-server-side-encryption", "aws:kms"}]
      )
      |> call()

    assert bad_get.status == 400
    assert bad_get.resp_body =~ "<Code>InvalidRequest</Code>"

    bad_head =
      SigV4Request.signed_conn(:head, "/#{bucket}/#{key}",
        headers: [{"x-amz-server-side-encryption-aws-kms-key-id", "alias/maxio/default"}]
      )
      |> call()

    assert bad_head.status == 400
  end

  test "PutObject aws:kms verifies concrete x-amz-content-sha256 before committing" do
    bucket = "ssekmsbadsha"
    key = "bad.txt"

    SigV4Request.signed_conn(:put, "/#{bucket}") |> call()

    bad =
      SigV4Request.signed_conn(:put, "/#{bucket}/#{key}",
        body: "real kms bytes",
        content_sha256_override: String.duplicate("0", 64),
        headers: [{"x-amz-server-side-encryption", "aws:kms"}]
      )
      |> call()

    assert bad.status == 400
    assert bad.resp_body =~ "<Code>XAmzContentSHA256Mismatch</Code>"
    assert {:error, :not_found} = Objects.get_metadata(bucket, key)
  end

  test "PutObject aws:kms:dsse encrypts with two KMS layers and reads transparently" do
    bucket = "ssedsse1"
    key = "dsse.txt"
    plain = String.duplicate("dsse plaintext ", 8_000)
    key_id = "arn:aws:kms:us-east-1:000000000000:key/dsse-local"
    context_b64 = Base.encode64(~s({"bucket":"#{bucket}","key":"#{key}"}))

    SigV4Request.signed_conn(:put, "/#{bucket}") |> call()

    put =
      SigV4Request.signed_conn(:put, "/#{bucket}/#{key}",
        body: plain,
        headers: [
          {"x-amz-server-side-encryption", "aws:kms:dsse"},
          {"x-amz-server-side-encryption-aws-kms-key-id", key_id},
          {"x-amz-server-side-encryption-context", context_b64}
        ]
      )
      |> call()

    assert put.status == 200
    assert get_resp_header(put, "x-amz-server-side-encryption") == ["aws:kms:dsse"]
    assert get_resp_header(put, "x-amz-server-side-encryption-aws-kms-key-id") == [key_id]
    assert get_resp_header(put, "x-amz-server-side-encryption-bucket-key-enabled") == []
    assert [checksum] = get_resp_header(put, "x-amz-checksum-crc64nvme")

    {:ok, obj} = Objects.get_metadata(bucket, key)
    assert obj.size == byte_size(plain)
    assert obj.sse_algorithm == "aws:kms:dsse"
    assert obj.sse_envelope["mode"] == "DSSE-KMS"
    assert obj.sse_envelope["kms_key_id"] == key_id
    assert obj.sse_envelope["kms_encryption_context_b64"] == context_b64
    assert is_map(obj.sse_envelope["dsse_inner"])
    assert is_map(obj.sse_envelope["dsse_outer"])
    refute inspect(obj.sse_envelope) =~ "plaintext_key"
    assert is_map(obj.checksum["__maxio_dsse_encrypted_checksum"])
    refute Map.has_key?(obj.checksum, "ChecksumCRC64NVME")

    assert SSE.visible_checksum_metadata(obj) == %{
             "ChecksumCRC64NVME" => checksum,
             "ChecksumType" => "FULL_OBJECT"
           }

    ciphertext = File.read!(Path.join([@data_dir, bucket, key, "part.0"]))
    refute ciphertext =~ "dsse plaintext"

    sidecar =
      [@data_dir, bucket, key, "meta.json"]
      |> Path.join()
      |> File.read!()
      |> Sidecar.decode!()

    assert [%{"checksum" => sidecar_checksum}] = sidecar["versions"]
    assert is_map(sidecar_checksum["__maxio_dsse_encrypted_checksum"])
    refute Map.has_key?(sidecar_checksum, "ChecksumCRC64NVME")

    get = SigV4Request.signed_conn(:get, "/#{bucket}/#{key}") |> call()
    assert get.status == 200
    assert get.resp_body == plain
    assert get_resp_header(get, "x-amz-server-side-encryption") == ["aws:kms:dsse"]
    assert get_resp_header(get, "x-amz-server-side-encryption-aws-kms-key-id") == [key_id]

    range =
      SigV4Request.signed_conn(:get, "/#{bucket}/#{key}", headers: [{"range", "bytes=5-17"}])
      |> call()

    assert range.status == 206
    assert range.resp_body == binary_part(plain, 5, 13)
    assert get_resp_header(range, "x-amz-server-side-encryption") == ["aws:kms:dsse"]

    head = SigV4Request.signed_conn(:head, "/#{bucket}/#{key}") |> call()
    assert head.status == 200
    assert get_resp_header(head, "content-length") == [Integer.to_string(byte_size(plain))]
    assert get_resp_header(head, "x-amz-server-side-encryption") == ["aws:kms:dsse"]

    attrs =
      SigV4Request.signed_conn(:get, "/#{bucket}/#{key}",
        query: %{"attributes" => ""},
        headers: [{"x-amz-object-attributes", "Checksum"}]
      )
      |> call()

    assert attrs.status == 200
    assert attrs.resp_body =~ "<ChecksumCRC64NVME>#{checksum}</ChecksumCRC64NVME>"
    assert attrs.resp_body =~ "<ChecksumType>FULL_OBJECT</ChecksumType>"
  end

  test "PutObject aws:kms:dsse rejects bucket keys before committing" do
    bucket = "ssedssebadbk"
    key = "bad.txt"

    SigV4Request.signed_conn(:put, "/#{bucket}") |> call()

    res =
      SigV4Request.signed_conn(:put, "/#{bucket}/#{key}",
        body: "x",
        headers: [
          {"x-amz-server-side-encryption", "aws:kms:dsse"},
          {"x-amz-server-side-encryption-bucket-key-enabled", "true"}
        ]
      )
      |> call()

    assert res.status == 400
    assert res.resp_body =~ "<Code>InvalidArgument</Code>"
    assert {:error, :not_found} = Objects.get_metadata(bucket, key)
  end

  test "bucket default aws:kms:dsse applies without BucketKeyEnabled" do
    bucket = "ssedssebucket"
    key_id = "arn:aws:kms:us-east-1:000000000000:key/dsse-bucket"

    SigV4Request.signed_conn(:put, "/#{bucket}") |> call()
    assert put_bucket_dsse_encryption(bucket, key_id).status == 200

    get_cfg = SigV4Request.signed_conn(:get, "/#{bucket}", query: %{"encryption" => ""}) |> call()
    assert get_cfg.status == 200
    assert get_cfg.resp_body =~ "<SSEAlgorithm>aws:kms:dsse</SSEAlgorithm>"
    assert get_cfg.resp_body =~ "<KMSMasterKeyID>#{key_id}</KMSMasterKeyID>"
    refute get_cfg.resp_body =~ "<BucketKeyEnabled>true</BucketKeyEnabled>"

    put = SigV4Request.signed_conn(:put, "/#{bucket}/default.txt", body: "default-dsse") |> call()
    assert put.status == 200
    assert get_resp_header(put, "x-amz-server-side-encryption") == ["aws:kms:dsse"]
    assert get_resp_header(put, "x-amz-server-side-encryption-aws-kms-key-id") == [key_id]

    get = SigV4Request.signed_conn(:get, "/#{bucket}/default.txt") |> call()
    assert get.status == 200
    assert get.resp_body == "default-dsse"
    assert get_resp_header(get, "x-amz-server-side-encryption") == ["aws:kms:dsse"]
  end

  test "PutBucketEncryption aws:kms:dsse rejects BucketKeyEnabled true" do
    bucket = "ssedssebucketbad"
    key_id = "arn:aws:kms:us-east-1:000000000000:key/dsse-bucket-bad"

    SigV4Request.signed_conn(:put, "/#{bucket}") |> call()

    res = put_bucket_dsse_encryption(bucket, key_id, true)

    assert res.status == 400
    assert res.resp_body =~ "<Code>InvalidArgument</Code>"
  end

  test "PutBucketEncryption validates checksum headers and aws-chunked trailers before storing config" do
    bucket = "sseencchecksum"
    key_id = "arn:aws:kms:us-east-1:000000000000:key/checksum-bucket"
    aes_xml = aes256_bucket_encryption_xml()
    kms_xml = kms_bucket_encryption_xml(key_id)

    assert (SigV4Request.signed_conn(:put, "/#{bucket}") |> call()).status == 200

    missing_integrity =
      SigV4Request.signed_conn(:put, "/#{bucket}",
        query: %{"encryption" => ""},
        body: aes_xml,
        auto_content_md5: false
      )
      |> call()

    assert missing_integrity.status == 400
    assert missing_integrity.resp_body =~ "<Code>MissingSecurityHeader</Code>"
    assert BucketConfigs.get(bucket, :encryption) == :none

    good_header =
      SigV4Request.signed_conn(:put, "/#{bucket}",
        query: %{"encryption" => ""},
        body: aes_xml,
        auto_content_md5: false,
        headers: [
          {"x-amz-sdk-checksum-algorithm", "SHA256"},
          {"x-amz-checksum-sha256", checksum_b64(:sha256, aes_xml)}
        ]
      )
      |> call()

    assert good_header.status == 200
    assert {:ok, %{"algorithm" => "AES256"}} = BucketConfigs.get(bucket, :encryption)

    malformed =
      SigV4Request.signed_conn(:put, "/#{bucket}",
        query: %{"encryption" => ""},
        body:
          ~s(<ServerSideEncryptionConfiguration><Rule><Unknown>AES256</Unknown></Rule></ServerSideEncryptionConfiguration>)
      )
      |> call()

    assert malformed.status == 400
    assert malformed.resp_body =~ "<Code>MalformedXML</Code>"
    assert {:ok, %{"algorithm" => "AES256"}} = BucketConfigs.get(bucket, :encryption)

    blocked_encryption =
      SigV4Request.signed_conn(:put, "/#{bucket}",
        query: %{"encryption" => ""},
        body:
          ~s(<ServerSideEncryptionConfiguration><Rule><BlockedEncryptionTypes><EncryptionType>SSE-C</EncryptionType></BlockedEncryptionTypes></Rule></ServerSideEncryptionConfiguration>)
      )
      |> call()

    assert blocked_encryption.status == 501
    assert blocked_encryption.resp_body =~ "<Code>NotImplemented</Code>"
    assert {:ok, %{"algorithm" => "AES256"}} = BucketConfigs.get(bucket, :encryption)

    multiple_rules =
      SigV4Request.signed_conn(:put, "/#{bucket}",
        query: %{"encryption" => ""},
        body:
          ~s(<ServerSideEncryptionConfiguration><Rule><ApplyServerSideEncryptionByDefault><SSEAlgorithm>AES256</SSEAlgorithm></ApplyServerSideEncryptionByDefault></Rule><Rule><ApplyServerSideEncryptionByDefault><SSEAlgorithm>aws:kms</SSEAlgorithm><KMSMasterKeyID>#{key_id}</KMSMasterKeyID></ApplyServerSideEncryptionByDefault></Rule></ServerSideEncryptionConfiguration>)
      )
      |> call()

    assert multiple_rules.status == 501
    assert multiple_rules.resp_body =~ "<Code>NotImplemented</Code>"
    assert {:ok, %{"algorithm" => "AES256"}} = BucketConfigs.get(bucket, :encryption)

    bad_md5 =
      SigV4Request.signed_conn(:put, "/#{bucket}",
        query: %{"encryption" => ""},
        body: kms_xml,
        headers: [{"content-md5", checksum_b64(:md5, "different")}]
      )
      |> call()

    assert bad_md5.status == 400
    assert bad_md5.resp_body =~ "<Code>BadDigest</Code>"
    assert {:ok, %{"algorithm" => "AES256"}} = BucketConfigs.get(bucket, :encryption)

    bad_header =
      SigV4Request.signed_conn(:put, "/#{bucket}",
        query: %{"encryption" => ""},
        body: kms_xml,
        headers: [
          {"x-amz-sdk-checksum-algorithm", "SHA256"},
          {"x-amz-checksum-sha256", checksum_b64(:sha256, "different")}
        ]
      )
      |> call()

    assert bad_header.status == 400
    assert bad_header.resp_body =~ "<Code>BadDigest</Code>"
    assert {:ok, %{"algorithm" => "AES256"}} = BucketConfigs.get(bucket, :encryption)

    plain_trailer =
      SigV4Request.signed_conn(:put, "/#{bucket}",
        query: %{"encryption" => ""},
        body: kms_xml,
        headers: [
          {"x-amz-sdk-checksum-algorithm", "SHA256"},
          {"x-amz-trailer", "x-amz-checksum-sha256"}
        ]
      )
      |> call()

    assert plain_trailer.status == 400
    assert plain_trailer.resp_body =~ "<Code>InvalidRequest</Code>"
    assert {:ok, %{"algorithm" => "AES256"}} = BucketConfigs.get(bucket, :encryption)

    bad_trailer =
      SigV4Request.signed_chunked_conn(:put, "/#{bucket}", kms_xml,
        query: %{"encryption" => ""},
        headers: [{"x-amz-sdk-checksum-algorithm", "SHA256"}],
        trailer_headers: [{"x-amz-checksum-sha256", checksum_b64(:sha256, "different")}]
      )
      |> call()

    assert bad_trailer.status == 400
    assert bad_trailer.resp_body =~ "<Code>BadDigest</Code>"
    assert {:ok, %{"algorithm" => "AES256"}} = BucketConfigs.get(bucket, :encryption)

    ok_trailer =
      SigV4Request.signed_chunked_conn(:put, "/#{bucket}", kms_xml,
        query: %{"encryption" => ""},
        headers: [{"x-amz-sdk-checksum-algorithm", "SHA256"}],
        trailer_headers: [{"x-amz-checksum-sha256", checksum_b64(:sha256, kms_xml)}]
      )
      |> call()

    assert ok_trailer.status == 200

    assert {:ok,
            %{
              "algorithm" => "aws:kms",
              "kms_key_id" => ^key_id,
              "bucket_key_enabled" => true
            }} = BucketConfigs.get(bucket, :encryption)

    bad_signed_trailer =
      SigV4Request.signed_chunked_conn(:put, "/#{bucket}", aes_xml,
        query: %{"encryption" => ""},
        headers: [{"x-amz-sdk-checksum-algorithm", "SHA256"}],
        trailer_headers: [{"x-amz-checksum-sha256", checksum_b64(:sha256, aes_xml)}],
        streaming_payload_hash: "STREAMING-AWS4-HMAC-SHA256-PAYLOAD-TRAILER",
        tamper: fn chunked ->
          Regex.replace(
            ~r/x-amz-trailer-signature:[0-9a-f]{64}/,
            chunked,
            "x-amz-trailer-signature:" <> String.duplicate("0", 64)
          )
        end
      )
      |> call()

    assert bad_signed_trailer.status == 403
    assert bad_signed_trailer.resp_body =~ "<Code>SignatureDoesNotMatch</Code>"

    assert {:ok,
            %{
              "algorithm" => "aws:kms",
              "kms_key_id" => ^key_id,
              "bucket_key_enabled" => true
            }} = BucketConfigs.get(bucket, :encryption)
  end

  test "BucketEncryption validates x-amz-expected-bucket-owner on put get and delete" do
    bucket = "sseencowner"
    key_id = "arn:aws:kms:us-east-1:000000000000:key/owner-check"
    aes_xml = aes256_bucket_encryption_xml()
    kms_xml = kms_bucket_encryption_xml(key_id)

    assert (SigV4Request.signed_conn(:put, "/#{bucket}") |> call()).status == 200

    put_ok =
      SigV4Request.signed_conn(:put, "/#{bucket}",
        query: %{"encryption" => ""},
        body: aes_xml,
        headers: [{"x-amz-expected-bucket-owner", "000000000000"}]
      )
      |> call()

    assert put_ok.status == 200

    put_wrong_owner =
      SigV4Request.signed_conn(:put, "/#{bucket}",
        query: %{"encryption" => ""},
        body: kms_xml,
        headers: [{"x-amz-expected-bucket-owner", "111111111111"}]
      )
      |> call()

    assert put_wrong_owner.status == 403
    assert put_wrong_owner.resp_body =~ "<Code>AccessDenied</Code>"
    assert {:ok, %{"algorithm" => "AES256"}} = BucketConfigs.get(bucket, :encryption)

    get_wrong_owner =
      SigV4Request.signed_conn(:get, "/#{bucket}",
        query: %{"encryption" => ""},
        headers: [{"x-amz-expected-bucket-owner", "111111111111"}]
      )
      |> call()

    assert get_wrong_owner.status == 403
    assert get_wrong_owner.resp_body =~ "<Code>AccessDenied</Code>"

    delete_wrong_owner =
      SigV4Request.signed_conn(:delete, "/#{bucket}",
        query: %{"encryption" => ""},
        headers: [{"x-amz-expected-bucket-owner", "111111111111"}]
      )
      |> call()

    assert delete_wrong_owner.status == 403
    assert delete_wrong_owner.resp_body =~ "<Code>AccessDenied</Code>"
    assert {:ok, %{"algorithm" => "AES256"}} = BucketConfigs.get(bucket, :encryption)

    get_ok =
      SigV4Request.signed_conn(:get, "/#{bucket}",
        query: %{"encryption" => ""},
        headers: [{"x-amz-expected-bucket-owner", "000000000000"}]
      )
      |> call()

    assert get_ok.status == 200
    assert get_ok.resp_body =~ "<SSEAlgorithm>AES256</SSEAlgorithm>"
  end

  test "PutObject SSE-C encrypts bytes and requires matching read key" do
    bucket = "ssecput"
    key = "secret.txt"
    plain = String.duplicate("sse-c secret bytes ", 4_000)
    customer_key = :crypto.strong_rand_bytes(32)
    headers = sse_c_headers(customer_key)
    key_md5_b64 = :crypto.hash(:md5, customer_key) |> Base.encode64()

    SigV4Request.signed_conn(:put, "/#{bucket}") |> call()

    put =
      SigV4Request.signed_conn(:put, "/#{bucket}/#{key}",
        body: plain,
        headers: headers
      )
      |> call()

    assert put.status == 200
    assert get_resp_header(put, "x-amz-server-side-encryption") == []
    [etag] = get_resp_header(put, "etag")

    assert get_resp_header(put, "x-amz-server-side-encryption-customer-algorithm") == [
             "AES256"
           ]

    assert get_resp_header(put, "x-amz-server-side-encryption-customer-key-md5") == [
             key_md5_b64
           ]

    {:ok, obj} = Objects.get_metadata(bucket, key)
    assert obj.size == byte_size(plain)
    assert obj.sse_algorithm == "SSE-C"
    assert is_map(obj.sse_envelope)
    refute inspect(obj.sse_envelope) =~ Base.encode64(customer_key)

    ciphertext = File.read!(Path.join([@data_dir, bucket, key, "part.0"]))
    refute ciphertext =~ plain

    missing_key = SigV4Request.signed_conn(:get, "/#{bucket}/#{key}") |> call()
    assert missing_key.status == 400
    assert missing_key.resp_body =~ "<Code>InvalidArgument</Code>"

    wrong_key =
      SigV4Request.signed_conn(:get, "/#{bucket}/#{key}",
        headers: sse_c_headers(:crypto.strong_rand_bytes(32))
      )
      |> call()

    assert wrong_key.status == 400
    assert wrong_key.resp_body =~ "<Code>InvalidArgument</Code>"

    get =
      SigV4Request.signed_conn(:get, "/#{bucket}/#{key}", headers: headers)
      |> call()

    assert get.status == 200
    assert get.resp_body == plain
    assert get_resp_header(get, "x-amz-server-side-encryption") == []

    assert get_resp_header(get, "x-amz-server-side-encryption-customer-algorithm") == [
             "AES256"
           ]

    assert get_resp_header(get, "x-amz-server-side-encryption-customer-key-md5") == [
             key_md5_b64
           ]

    range =
      SigV4Request.signed_conn(:get, "/#{bucket}/#{key}",
        headers: [{"range", "bytes=65530-65555"} | headers]
      )
      |> call()

    assert range.status == 206
    assert range.resp_body == binary_part(plain, 65_530, 26)
    assert get_resp_header(range, "content-range") == ["bytes 65530-65555/#{byte_size(plain)}"]
    assert get_resp_header(range, "content-length") == ["26"]

    head_missing = SigV4Request.signed_conn(:head, "/#{bucket}/#{key}") |> call()
    assert head_missing.status == 400

    head =
      SigV4Request.signed_conn(:head, "/#{bucket}/#{key}", headers: headers)
      |> call()

    assert head.status == 200
    assert get_resp_header(head, "content-length") == [Integer.to_string(byte_size(plain))]

    assert get_resp_header(head, "x-amz-server-side-encryption-customer-algorithm") == [
             "AES256"
           ]

    assert get_resp_header(head, "x-amz-server-side-encryption-customer-key-md5") == [
             key_md5_b64
           ]

    conditional_missing_key =
      SigV4Request.signed_conn(:get, "/#{bucket}/#{key}", headers: [{"if-none-match", etag}])
      |> call()

    assert conditional_missing_key.status == 400
    assert conditional_missing_key.resp_body =~ "<Code>InvalidArgument</Code>"

    conditional_get =
      SigV4Request.signed_conn(:get, "/#{bucket}/#{key}",
        headers: [{"if-none-match", etag} | headers]
      )
      |> call()

    assert conditional_get.status == 304

    conditional_head_missing_key =
      SigV4Request.signed_conn(:head, "/#{bucket}/#{key}", headers: [{"if-none-match", etag}])
      |> call()

    assert conditional_head_missing_key.status == 400

    conditional_head =
      SigV4Request.signed_conn(:head, "/#{bucket}/#{key}",
        headers: [{"if-none-match", etag} | headers]
      )
      |> call()

    assert conditional_head.status == 304
  end

  test "PutObject SSE-C rejects customer key MD5 mismatch before creating an object" do
    bucket = "ssecbadmd5"
    key = "o.txt"
    customer_key = :crypto.strong_rand_bytes(32)

    bad_headers = [
      {"x-amz-server-side-encryption-customer-algorithm", "AES256"},
      {"x-amz-server-side-encryption-customer-key", Base.encode64(customer_key)},
      {"x-amz-server-side-encryption-customer-key-md5",
       :crypto.hash(:md5, "not the customer key") |> Base.encode64()}
    ]

    SigV4Request.signed_conn(:put, "/#{bucket}") |> call()

    res =
      SigV4Request.signed_conn(:put, "/#{bucket}/#{key}",
        body: "x",
        headers: bad_headers
      )
      |> call()

    assert res.status == 400
    assert res.resp_body =~ "<Code>BadDigest</Code>"
    assert {:error, :not_found} = Objects.get_metadata(bucket, key)
  end

  test "PutObject rejects incomplete target SSE-C headers before creating an object" do
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

    assert res.status == 400
    assert res.resp_body =~ "<Code>InvalidArgument</Code>"
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

    assert res.status == 400
    assert res.resp_body =~ "<Code>InvalidArgument</Code>"
    assert {:error, :not_found} = Objects.get_metadata("ssecustomercopy", "dst.txt")
  end

  test "CreateMultipartUpload rejects incomplete target SSE-C headers before creating a session" do
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

    assert res.status == 400
    assert res.resp_body =~ "<Code>InvalidArgument</Code>"
    assert Multipart.list_uploads("ssecustomermpu").uploads == []
  end

  test "CreateMultipartUpload rejects blank target SSE-C headers before creating a session" do
    SigV4Request.signed_conn(:put, "/ssecustomerblankmpu") |> call()

    res =
      SigV4Request.signed_conn(:post, "/ssecustomerblankmpu/o.txt",
        query: %{"uploads" => ""},
        headers: [{"x-amz-server-side-encryption-customer-key", ""}]
      )
      |> call()

    assert res.status == 400
    assert res.resp_body =~ "<Code>InvalidArgument</Code>"
    assert Multipart.list_uploads("ssecustomerblankmpu").uploads == []
  end

  test "UploadPart rejects target SSE-C headers before writing a part" do
    bucket = "ssecustomerpart"
    key = "o.txt"
    SigV4Request.signed_conn(:put, "/#{bucket}") |> call()

    init =
      SigV4Request.signed_conn(:post, "/#{bucket}/#{key}", query: %{"uploads" => ""})
      |> call()

    assert init.status == 200
    upload_id = upload_id(init.resp_body)
    {:ok, upload} = Multipart.get_upload(bucket, key, upload_id)

    res =
      SigV4Request.signed_conn(:put, "/#{bucket}/#{key}",
        query: %{"partNumber" => "1", "uploadId" => upload_id},
        body: "part bytes",
        headers: sse_c_headers(:crypto.strong_rand_bytes(32))
      )
      |> call()

    assert res.status == 400
    assert res.resp_body =~ "<Code>InvalidRequest</Code>"
    assert Multipart.list_parts(upload).parts == []
  end

  test "CompleteMultipartUpload rejects target SSE-C headers before committing an object" do
    bucket = "ssecustomercomplete"
    key = "o.txt"
    SigV4Request.signed_conn(:put, "/#{bucket}") |> call()

    init =
      SigV4Request.signed_conn(:post, "/#{bucket}/#{key}", query: %{"uploads" => ""})
      |> call()

    assert init.status == 200
    upload_id = upload_id(init.resp_body)

    upload_part =
      SigV4Request.signed_conn(:put, "/#{bucket}/#{key}",
        query: %{"partNumber" => "1", "uploadId" => upload_id},
        body: "part bytes"
      )
      |> call()

    assert upload_part.status == 200
    [part_etag] = get_resp_header(upload_part, "etag")

    complete_body =
      "<CompleteMultipartUpload><Part><PartNumber>1</PartNumber>" <>
        "<ETag>#{part_etag}</ETag></Part></CompleteMultipartUpload>"

    res =
      SigV4Request.signed_conn(:post, "/#{bucket}/#{key}",
        query: %{"uploadId" => upload_id},
        body: complete_body,
        headers: sse_c_headers(:crypto.strong_rand_bytes(32))
      )
      |> call()

    assert res.status == 400
    assert res.resp_body =~ "<Code>InvalidRequest</Code>"
    assert {:ok, _upload} = Multipart.get_upload(bucket, key, upload_id)
    assert {:error, :not_found} = Objects.get_metadata(bucket, key)
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

  test "CreateMultipartUpload aws:kms encrypts completed object" do
    bucket = "ssempukms"
    key = "kms-multi.txt"
    key_id = "arn:aws:kms:us-east-1:000000000000:key/mpu"
    plain = "multipart bytes through SSE-KMS"

    SigV4Request.signed_conn(:put, "/#{bucket}") |> call()

    init =
      SigV4Request.signed_conn(:post, "/#{bucket}/#{key}",
        query: %{"uploads" => ""},
        headers: [
          {"x-amz-server-side-encryption", "aws:kms"},
          {"x-amz-server-side-encryption-aws-kms-key-id", key_id},
          {"x-amz-server-side-encryption-bucket-key-enabled", "true"}
        ]
      )
      |> call()

    assert init.status == 200
    assert get_resp_header(init, "x-amz-server-side-encryption") == ["aws:kms"]
    assert get_resp_header(init, "x-amz-server-side-encryption-aws-kms-key-id") == [key_id]
    upload_id = upload_id(init.resp_body)
    {:ok, upload} = Multipart.get_upload(bucket, key, upload_id)
    assert upload.sse_algorithm == "aws:kms"
    assert upload.sse_envelope["mode"] == "SSE-KMS"

    upload_part =
      SigV4Request.signed_conn(:put, "/#{bucket}/#{key}",
        query: %{"partNumber" => "1", "uploadId" => upload_id},
        body: plain
      )
      |> call()

    assert upload_part.status == 200
    [part_etag] = get_resp_header(upload_part, "etag")
    part_on_disk = File.read!(Path.join([@data_dir, ".uploads", bucket, upload_id, "1.part"]))
    refute part_on_disk == plain
    refute part_on_disk =~ plain

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
    assert get_resp_header(complete, "x-amz-server-side-encryption") == ["aws:kms"]
    assert get_resp_header(complete, "x-amz-server-side-encryption-aws-kms-key-id") == [key_id]

    get = SigV4Request.signed_conn(:get, "/#{bucket}/#{key}") |> call()
    assert get.status == 200
    assert get.resp_body == plain
    assert get_resp_header(get, "x-amz-server-side-encryption") == ["aws:kms"]

    {:ok, obj} = Objects.get_metadata(bucket, key)
    assert obj.sse_algorithm == "aws:kms"
    assert obj.sse_envelope["mode"] == "SSE-KMS"
    assert obj.sse_envelope["kms_key_id"] == key_id

    on_disk = File.read!(Path.join([@data_dir, bucket, key, "part.0"]))
    refute on_disk =~ plain
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
