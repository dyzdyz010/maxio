defmodule Maxio.S3.CopyObjectSseTest do
  use Maxio.DataCase, async: false

  import Plug.Conn
  alias Maxio.Objects
  alias Maxio.Objects.Object
  alias Maxio.Repo
  alias Maxio.S3.{Endpoint, SSE}
  alias Maxio.Test.SigV4Request

  @data_dir Path.join(System.tmp_dir!(), "maxio_copy_object_sse")

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

  defp part0(bucket, key), do: Path.join([@data_dir, bucket, key, "part.0"])
  defp sidecar(bucket, key), do: Path.join([@data_dir, bucket, key, "meta.json"])

  defp sse_c_headers(customer_key) do
    [
      {"x-amz-server-side-encryption-customer-algorithm", "AES256"},
      {"x-amz-server-side-encryption-customer-key", Base.encode64(customer_key)},
      {"x-amz-server-side-encryption-customer-key-md5",
       :crypto.hash(:md5, customer_key) |> Base.encode64()}
    ]
  end

  defp copy_source_sse_c_headers(customer_key) do
    [
      {"x-amz-copy-source-server-side-encryption-customer-algorithm", "AES256"},
      {"x-amz-copy-source-server-side-encryption-customer-key", Base.encode64(customer_key)},
      {"x-amz-copy-source-server-side-encryption-customer-key-md5",
       :crypto.hash(:md5, customer_key) |> Base.encode64()}
    ]
  end

  defp put_bucket_encryption(bucket) do
    body =
      ~s(<ServerSideEncryptionConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Rule><ApplyServerSideEncryptionByDefault><SSEAlgorithm>AES256</SSEAlgorithm></ApplyServerSideEncryptionByDefault></Rule></ServerSideEncryptionConfiguration>)

    SigV4Request.signed_conn(:put, "/#{bucket}", query: %{"encryption" => ""}, body: body)
    |> call()
  end

  test "CopyObject decrypts SSE-S3 source and stores an unencrypted destination unless requested" do
    bucket = "cpsse1"
    plain = "copy me out of SSE-S3"

    SigV4Request.signed_conn(:put, "/#{bucket}") |> call()

    put =
      SigV4Request.signed_conn(:put, "/#{bucket}/src.txt",
        body: plain,
        headers: [{"x-amz-server-side-encryption", "AES256"}]
      )
      |> call()

    assert put.status == 200
    source_ciphertext = File.read!(part0(bucket, "src.txt"))
    refute source_ciphertext =~ plain

    copy =
      SigV4Request.signed_conn(:put, "/#{bucket}/dst.txt",
        headers: [{"x-amz-copy-source", "/#{bucket}/src.txt"}]
      )
      |> call()

    assert copy.status == 200
    assert get_resp_header(copy, "x-amz-server-side-encryption") == []

    get = SigV4Request.signed_conn(:get, "/#{bucket}/dst.txt") |> call()
    assert get.status == 200
    assert get.resp_body == plain
    assert get_resp_header(get, "x-amz-server-side-encryption") == []
    assert File.read!(part0(bucket, "dst.txt")) == plain

    {:ok, dst} = Objects.get_metadata(bucket, "dst.txt")
    assert dst.sse_algorithm == nil
    assert dst.sse_envelope == nil
  end

  test "CopyObject decrypts SSE-S3 source and re-encrypts destination when AES256 is requested" do
    bucket = "cpsse2"
    plain = "copy me and keep me encrypted"

    SigV4Request.signed_conn(:put, "/#{bucket}") |> call()

    put =
      SigV4Request.signed_conn(:put, "/#{bucket}/src.txt",
        body: plain,
        headers: [{"x-amz-server-side-encryption", "AES256"}]
      )
      |> call()

    assert put.status == 200
    source_ciphertext = File.read!(part0(bucket, "src.txt"))

    copy =
      SigV4Request.signed_conn(:put, "/#{bucket}/dst.txt",
        headers: [
          {"x-amz-copy-source", "/#{bucket}/src.txt"},
          {"x-amz-server-side-encryption", "AES256"}
        ]
      )
      |> call()

    assert copy.status == 200
    assert get_resp_header(copy, "x-amz-server-side-encryption") == ["AES256"]

    get = SigV4Request.signed_conn(:get, "/#{bucket}/dst.txt") |> call()
    assert get.status == 200
    assert get.resp_body == plain
    assert get_resp_header(get, "x-amz-server-side-encryption") == ["AES256"]

    range =
      SigV4Request.signed_conn(:get, "/#{bucket}/dst.txt", headers: [{"range", "bytes=5-12"}])
      |> call()

    assert range.status == 206
    assert range.resp_body == binary_part(plain, 5, 8)
    assert get_resp_header(range, "content-range") == ["bytes 5-12/#{byte_size(plain)}"]
    assert get_resp_header(range, "content-length") == ["8"]
    assert get_resp_header(range, "x-amz-server-side-encryption") == ["AES256"]

    target_ciphertext = File.read!(part0(bucket, "dst.txt"))
    refute target_ciphertext =~ plain
    refute target_ciphertext == source_ciphertext

    {:ok, dst} = Objects.get_metadata(bucket, "dst.txt")
    assert dst.sse_algorithm == "AES256"
    assert is_map(dst.sse_envelope)
    assert dst.size == byte_size(plain)

    meta =
      bucket
      |> sidecar("dst.txt")
      |> File.read!()
      |> Maxio.Sidecar.decode!()

    [entry] = meta["versions"]
    assert entry["size"] == byte_size(plain)
    assert meta["size"] > byte_size(plain)
  end

  test "CopyObject decrypts SSE-KMS source and can re-encrypt destination with SSE-KMS" do
    bucket = "cpkms1"
    plain = "copy me through SSE-KMS"
    src_key_id = "arn:aws:kms:us-east-1:000000000000:key/source"
    dst_key_id = "arn:aws:kms:us-east-1:000000000000:key/dest"

    SigV4Request.signed_conn(:put, "/#{bucket}") |> call()

    put =
      SigV4Request.signed_conn(:put, "/#{bucket}/src.txt",
        body: plain,
        headers: [
          {"x-amz-server-side-encryption", "aws:kms"},
          {"x-amz-server-side-encryption-aws-kms-key-id", src_key_id}
        ]
      )
      |> call()

    assert put.status == 200
    source_ciphertext = File.read!(part0(bucket, "src.txt"))
    refute source_ciphertext =~ plain

    clear_copy =
      SigV4Request.signed_conn(:put, "/#{bucket}/clear.txt",
        headers: [{"x-amz-copy-source", "/#{bucket}/src.txt"}]
      )
      |> call()

    assert clear_copy.status == 200
    assert get_resp_header(clear_copy, "x-amz-server-side-encryption") == []
    assert File.read!(part0(bucket, "clear.txt")) == plain

    encrypted_copy =
      SigV4Request.signed_conn(:put, "/#{bucket}/dst.txt",
        headers: [
          {"x-amz-copy-source", "/#{bucket}/src.txt"},
          {"x-amz-server-side-encryption", "aws:kms"},
          {"x-amz-server-side-encryption-aws-kms-key-id", dst_key_id}
        ]
      )
      |> call()

    assert encrypted_copy.status == 200
    assert get_resp_header(encrypted_copy, "x-amz-server-side-encryption") == ["aws:kms"]

    assert get_resp_header(encrypted_copy, "x-amz-server-side-encryption-aws-kms-key-id") == [
             dst_key_id
           ]

    get = SigV4Request.signed_conn(:get, "/#{bucket}/dst.txt") |> call()
    assert get.status == 200
    assert get.resp_body == plain
    assert get_resp_header(get, "x-amz-server-side-encryption") == ["aws:kms"]

    target_ciphertext = File.read!(part0(bucket, "dst.txt"))
    refute target_ciphertext =~ plain
    refute target_ciphertext == source_ciphertext

    {:ok, dst} = Objects.get_metadata(bucket, "dst.txt")
    assert dst.sse_algorithm == "aws:kms"
    assert dst.sse_envelope["mode"] == "SSE-KMS"
    assert dst.sse_envelope["kms_key_id"] == dst_key_id
  end

  test "CopyObject decrypts DSSE-KMS source and can re-encrypt destination with DSSE-KMS" do
    bucket = "cpdsse1"
    plain = "copy me through DSSE-KMS"
    src_key_id = "arn:aws:kms:us-east-1:000000000000:key/dsse-source"
    dst_key_id = "arn:aws:kms:us-east-1:000000000000:key/dsse-dest"

    SigV4Request.signed_conn(:put, "/#{bucket}") |> call()

    put =
      SigV4Request.signed_conn(:put, "/#{bucket}/src.txt",
        body: plain,
        headers: [
          {"x-amz-server-side-encryption", "aws:kms:dsse"},
          {"x-amz-server-side-encryption-aws-kms-key-id", src_key_id}
        ]
      )
      |> call()

    assert put.status == 200
    assert [source_checksum] = get_resp_header(put, "x-amz-checksum-crc64nvme")
    source_ciphertext = File.read!(part0(bucket, "src.txt"))
    refute source_ciphertext =~ plain

    clear_copy =
      SigV4Request.signed_conn(:put, "/#{bucket}/clear.txt",
        headers: [{"x-amz-copy-source", "/#{bucket}/src.txt"}]
      )
      |> call()

    assert clear_copy.status == 200
    assert get_resp_header(clear_copy, "x-amz-server-side-encryption") == []
    assert File.read!(part0(bucket, "clear.txt")) == plain

    encrypted_copy =
      SigV4Request.signed_conn(:put, "/#{bucket}/dst.txt",
        headers: [
          {"x-amz-copy-source", "/#{bucket}/src.txt"},
          {"x-amz-server-side-encryption", "aws:kms:dsse"},
          {"x-amz-server-side-encryption-aws-kms-key-id", dst_key_id}
        ]
      )
      |> call()

    assert encrypted_copy.status == 200
    assert get_resp_header(encrypted_copy, "x-amz-server-side-encryption") == ["aws:kms:dsse"]

    assert encrypted_copy.resp_body =~
             "<ChecksumCRC64NVME>#{source_checksum}</ChecksumCRC64NVME>"

    assert get_resp_header(encrypted_copy, "x-amz-server-side-encryption-aws-kms-key-id") == [
             dst_key_id
           ]

    get = SigV4Request.signed_conn(:get, "/#{bucket}/dst.txt") |> call()
    assert get.status == 200
    assert get.resp_body == plain
    assert get_resp_header(get, "x-amz-server-side-encryption") == ["aws:kms:dsse"]

    target_ciphertext = File.read!(part0(bucket, "dst.txt"))
    refute target_ciphertext =~ plain
    refute target_ciphertext == source_ciphertext

    {:ok, dst} = Objects.get_metadata(bucket, "dst.txt")
    assert dst.sse_algorithm == "aws:kms:dsse"
    assert dst.sse_envelope["mode"] == "DSSE-KMS"
    assert dst.sse_envelope["kms_key_id"] == dst_key_id
    assert is_map(dst.sse_envelope["dsse_inner"])
    assert is_map(dst.sse_envelope["dsse_outer"])
    assert is_map(dst.checksum["__maxio_dsse_encrypted_checksum"])
    refute Map.has_key?(dst.checksum, "ChecksumCRC64NVME")

    assert SSE.visible_checksum_metadata(dst) == %{
             "ChecksumCRC64NVME" => source_checksum,
             "ChecksumType" => "FULL_OBJECT"
           }

    attrs =
      SigV4Request.signed_conn(:get, "/#{bucket}/dst.txt",
        query: %{"attributes" => ""},
        headers: [{"x-amz-object-attributes", "Checksum"}]
      )
      |> call()

    assert attrs.status == 200
    assert attrs.resp_body =~ "<ChecksumCRC64NVME>#{source_checksum}</ChecksumCRC64NVME>"
    assert attrs.resp_body =~ "<ChecksumType>FULL_OBJECT</ChecksumType>"
  end

  test "CopyObject default CRC64NVME checksum is computed before destination SSE-S3 encryption" do
    bucket = "cpssechecksum"
    plain = "checksum should use plaintext bytes before encryption"
    checksum = crc64nvme_b64(plain)

    SigV4Request.signed_conn(:put, "/#{bucket}") |> call()

    put =
      SigV4Request.signed_conn(:put, "/#{bucket}/src.txt", body: plain)
      |> call()

    assert put.status == 200
    clear_object_checksum!(bucket, "src.txt")

    copy =
      SigV4Request.signed_conn(:put, "/#{bucket}/dst.txt",
        headers: [
          {"x-amz-copy-source", "/#{bucket}/src.txt"},
          {"x-amz-server-side-encryption", "AES256"}
        ]
      )
      |> call()

    assert copy.status == 200
    assert get_resp_header(copy, "x-amz-server-side-encryption") == ["AES256"]
    assert copy.resp_body =~ "<ChecksumCRC64NVME>#{checksum}</ChecksumCRC64NVME>"
    refute File.read!(part0(bucket, "dst.txt")) =~ plain

    get = SigV4Request.signed_conn(:get, "/#{bucket}/dst.txt") |> call()
    assert get.status == 200
    assert get.resp_body == plain

    assert %Object{checksum: pg_checksum} =
             Repo.get_by(Object, bucket_name: bucket, key: "dst.txt", is_latest: true)

    assert pg_checksum == %{
             "ChecksumCRC64NVME" => checksum,
             "ChecksumType" => "FULL_OBJECT"
           }
  end

  test "CopyObject explicit checksum algorithm is computed over plaintext before SSE-S3 encryption" do
    bucket = "cpssechecksumexplicit"
    plain = "explicit checksum should use decrypted plaintext bytes"
    checksum = :crypto.hash(:sha256, plain) |> Base.encode64()
    inherited = crc64nvme_b64(plain)

    SigV4Request.signed_conn(:put, "/#{bucket}") |> call()

    put =
      SigV4Request.signed_conn(:put, "/#{bucket}/src.txt",
        body: plain,
        headers: [{"x-amz-server-side-encryption", "AES256"}]
      )
      |> call()

    assert put.status == 200
    refute File.read!(part0(bucket, "src.txt")) =~ plain

    copy =
      SigV4Request.signed_conn(:put, "/#{bucket}/dst.txt",
        headers: [
          {"x-amz-copy-source", "/#{bucket}/src.txt"},
          {"x-amz-checksum-algorithm", "SHA256"},
          {"x-amz-server-side-encryption", "AES256"}
        ]
      )
      |> call()

    assert copy.status == 200
    assert get_resp_header(copy, "x-amz-server-side-encryption") == ["AES256"]
    assert copy.resp_body =~ "<ChecksumSHA256>#{checksum}</ChecksumSHA256>"
    refute copy.resp_body =~ "<ChecksumCRC64NVME>#{inherited}</ChecksumCRC64NVME>"
    refute File.read!(part0(bucket, "dst.txt")) =~ plain

    get = SigV4Request.signed_conn(:get, "/#{bucket}/dst.txt") |> call()
    assert get.status == 200
    assert get.resp_body == plain

    assert %Object{checksum: pg_checksum} =
             Repo.get_by(Object, bucket_name: bucket, key: "dst.txt", is_latest: true)

    assert pg_checksum == %{
             "ChecksumSHA256" => checksum,
             "ChecksumType" => "FULL_OBJECT"
           }
  end

  test "CopyObject honors destination bucket default SSE-S3 encryption" do
    SigV4Request.signed_conn(:put, "/cpssesrc") |> call()
    SigV4Request.signed_conn(:put, "/cpssedst") |> call()
    assert put_bucket_encryption("cpssedst").status == 200
    plain = "destination bucket default encryption"

    SigV4Request.signed_conn(:put, "/cpssesrc/src.txt", body: plain) |> call()

    copy =
      SigV4Request.signed_conn(:put, "/cpssedst/dst.txt",
        headers: [{"x-amz-copy-source", "/cpssesrc/src.txt"}]
      )
      |> call()

    assert copy.status == 200
    assert get_resp_header(copy, "x-amz-server-side-encryption") == ["AES256"]

    get = SigV4Request.signed_conn(:get, "/cpssedst/dst.txt") |> call()
    assert get.status == 200
    assert get.resp_body == plain
    assert get_resp_header(get, "x-amz-server-side-encryption") == ["AES256"]
    refute File.read!(part0("cpssedst", "dst.txt")) =~ plain
  end

  test "CopyObject self-copy can explicitly re-encrypt SSE-S3 object with a fresh envelope" do
    bucket = "cpsse3"
    plain = "rotate the SSE-S3 envelope"

    SigV4Request.signed_conn(:put, "/#{bucket}") |> call()

    put =
      SigV4Request.signed_conn(:put, "/#{bucket}/self.txt",
        body: plain,
        headers: [{"x-amz-server-side-encryption", "AES256"}]
      )
      |> call()

    assert put.status == 200
    before_ciphertext = File.read!(part0(bucket, "self.txt"))

    copy =
      SigV4Request.signed_conn(:put, "/#{bucket}/self.txt",
        headers: [
          {"x-amz-copy-source", "/#{bucket}/self.txt"},
          {"x-amz-server-side-encryption", "AES256"}
        ]
      )
      |> call()

    assert copy.status == 200
    assert get_resp_header(copy, "x-amz-server-side-encryption") == ["AES256"]

    after_ciphertext = File.read!(part0(bucket, "self.txt"))
    refute after_ciphertext == before_ciphertext
    refute after_ciphertext =~ plain

    get = SigV4Request.signed_conn(:get, "/#{bucket}/self.txt") |> call()
    assert get.status == 200
    assert get.resp_body == plain
    assert get_resp_header(get, "x-amz-server-side-encryption") == ["AES256"]

    {:ok, obj} = Objects.get_metadata(bucket, "self.txt")
    assert obj.sse_algorithm == "AES256"
    assert is_map(obj.sse_envelope)
  end

  test "CopyObject encrypts destination with target SSE-C headers" do
    bucket = "cpssec1"
    plain = "copy plaintext into a customer encrypted object"
    customer_key = :crypto.strong_rand_bytes(32)
    key_md5_b64 = :crypto.hash(:md5, customer_key) |> Base.encode64()
    headers = sse_c_headers(customer_key)

    SigV4Request.signed_conn(:put, "/#{bucket}") |> call()
    SigV4Request.signed_conn(:put, "/#{bucket}/src.txt", body: plain) |> call()

    copy =
      SigV4Request.signed_conn(:put, "/#{bucket}/dst.txt",
        headers: [{"x-amz-copy-source", "/#{bucket}/src.txt"} | headers]
      )
      |> call()

    assert copy.status == 200
    assert get_resp_header(copy, "x-amz-server-side-encryption-customer-algorithm") == ["AES256"]
    assert get_resp_header(copy, "x-amz-server-side-encryption-customer-key-md5") == [key_md5_b64]

    missing_get = SigV4Request.signed_conn(:get, "/#{bucket}/dst.txt") |> call()
    assert missing_get.status == 400

    get =
      SigV4Request.signed_conn(:get, "/#{bucket}/dst.txt", headers: headers)
      |> call()

    assert get.status == 200
    assert get.resp_body == plain
    assert get_resp_header(get, "x-amz-server-side-encryption-customer-key-md5") == [key_md5_b64]
    refute File.read!(part0(bucket, "dst.txt")) =~ plain

    {:ok, dst} = Objects.get_metadata(bucket, "dst.txt")
    assert dst.sse_algorithm == "SSE-C"
    assert is_map(dst.sse_envelope)
    assert dst.size == byte_size(plain)
    refute inspect(dst.sse_envelope) =~ Base.encode64(customer_key)
  end

  test "CopyObject requires matching copy-source SSE-C key and can decrypt to plaintext" do
    bucket = "cpssec2"
    plain = "copy customer encrypted source into plaintext destination"
    source_key = :crypto.strong_rand_bytes(32)
    source_headers = sse_c_headers(source_key)

    SigV4Request.signed_conn(:put, "/#{bucket}") |> call()

    put =
      SigV4Request.signed_conn(:put, "/#{bucket}/src.txt",
        body: plain,
        headers: source_headers
      )
      |> call()

    assert put.status == 200
    refute File.read!(part0(bucket, "src.txt")) =~ plain

    missing_source_key =
      SigV4Request.signed_conn(:put, "/#{bucket}/missing-key.txt",
        headers: [{"x-amz-copy-source", "/#{bucket}/src.txt"}]
      )
      |> call()

    assert missing_source_key.status == 400
    assert missing_source_key.resp_body =~ "<Code>InvalidArgument</Code>"
    assert {:error, :not_found} = Objects.get_metadata(bucket, "missing-key.txt")

    wrong_source_key =
      SigV4Request.signed_conn(:put, "/#{bucket}/wrong-key.txt",
        headers: [
          {"x-amz-copy-source", "/#{bucket}/src.txt"}
          | copy_source_sse_c_headers(:crypto.strong_rand_bytes(32))
        ]
      )
      |> call()

    assert wrong_source_key.status == 400
    assert wrong_source_key.resp_body =~ "<Code>InvalidArgument</Code>"
    assert {:error, :not_found} = Objects.get_metadata(bucket, "wrong-key.txt")

    copy =
      SigV4Request.signed_conn(:put, "/#{bucket}/dst.txt",
        headers: [
          {"x-amz-copy-source", "/#{bucket}/src.txt"}
          | copy_source_sse_c_headers(source_key)
        ]
      )
      |> call()

    assert copy.status == 200
    assert get_resp_header(copy, "x-amz-server-side-encryption") == []
    assert get_resp_header(copy, "x-amz-server-side-encryption-customer-algorithm") == []

    get = SigV4Request.signed_conn(:get, "/#{bucket}/dst.txt") |> call()
    assert get.status == 200
    assert get.resp_body == plain
    assert File.read!(part0(bucket, "dst.txt")) == plain

    {:ok, dst} = Objects.get_metadata(bucket, "dst.txt")
    assert dst.sse_algorithm == nil
    assert dst.sse_envelope == nil
  end

  test "CopyObject decrypts SSE-C source and re-encrypts SSE-C destination" do
    bucket = "cpssec3"
    plain = "rotate copy from one customer key to another"
    source_key = :crypto.strong_rand_bytes(32)
    target_key = :crypto.strong_rand_bytes(32)
    target_headers = sse_c_headers(target_key)
    target_key_md5_b64 = :crypto.hash(:md5, target_key) |> Base.encode64()

    SigV4Request.signed_conn(:put, "/#{bucket}") |> call()

    put =
      SigV4Request.signed_conn(:put, "/#{bucket}/src.txt",
        body: plain,
        headers: sse_c_headers(source_key)
      )
      |> call()

    assert put.status == 200
    source_ciphertext = File.read!(part0(bucket, "src.txt"))

    copy =
      SigV4Request.signed_conn(:put, "/#{bucket}/dst.txt",
        headers:
          [
            {"x-amz-copy-source", "/#{bucket}/src.txt"}
            | copy_source_sse_c_headers(source_key)
          ] ++ target_headers
      )
      |> call()

    assert copy.status == 200

    assert get_resp_header(copy, "x-amz-server-side-encryption-customer-key-md5") == [
             target_key_md5_b64
           ]

    wrong_key_get =
      SigV4Request.signed_conn(:get, "/#{bucket}/dst.txt", headers: sse_c_headers(source_key))
      |> call()

    assert wrong_key_get.status == 400

    get =
      SigV4Request.signed_conn(:get, "/#{bucket}/dst.txt", headers: target_headers)
      |> call()

    assert get.status == 200
    assert get.resp_body == plain

    assert get_resp_header(get, "x-amz-server-side-encryption-customer-key-md5") == [
             target_key_md5_b64
           ]

    target_ciphertext = File.read!(part0(bucket, "dst.txt"))
    refute target_ciphertext =~ plain
    refute target_ciphertext == source_ciphertext

    {:ok, dst} = Objects.get_metadata(bucket, "dst.txt")
    assert dst.sse_algorithm == "SSE-C"
    assert is_map(dst.sse_envelope)
    assert dst.size == byte_size(plain)
    refute inspect(dst.sse_envelope) =~ Base.encode64(source_key)
    refute inspect(dst.sse_envelope) =~ Base.encode64(target_key)
  end

  test "CopyObject rejects copy-source SSE-C headers for plaintext source objects" do
    bucket = "cpssec4"
    customer_key = :crypto.strong_rand_bytes(32)

    SigV4Request.signed_conn(:put, "/#{bucket}") |> call()
    SigV4Request.signed_conn(:put, "/#{bucket}/src.txt", body: "x") |> call()

    copy =
      SigV4Request.signed_conn(:put, "/#{bucket}/dst.txt",
        headers: [
          {"x-amz-copy-source", "/#{bucket}/src.txt"}
          | copy_source_sse_c_headers(customer_key)
        ]
      )
      |> call()

    assert copy.status == 400
    assert copy.resp_body =~ "<Code>InvalidRequest</Code>"
    assert {:error, :not_found} = Objects.get_metadata(bucket, "dst.txt")
  end

  defp clear_object_checksum!(bucket, key) do
    {:ok, object} = Objects.get_metadata(bucket, key)

    {:ok, _object} =
      Objects.put_version_with_id(bucket, key, object.version_id, %{
        size: object.size,
        etag: object.etag,
        content_type: object.content_type,
        storage_class: object.storage_class || "STANDARD",
        metadata: object.metadata || %{},
        tags: object.tags || %{},
        checksum: %{}
      })

    meta_path = sidecar(bucket, key)

    meta =
      meta_path
      |> File.read!()
      |> Maxio.Sidecar.decode!()

    versions =
      Enum.map(meta["versions"], fn version ->
        if version["version_id"] == object.version_id do
          Map.put(version, "checksum", %{})
        else
          version
        end
      end)

    File.write!(meta_path, Jason.encode!(Map.put(meta, "versions", versions)))
  end

  defp crc64nvme_b64(iodata) do
    iodata
    |> IO.iodata_to_binary()
    |> crc64nvme_raw()
    |> Base.encode64()
  end

  defp crc64nvme_raw(iodata) do
    data = IO.iodata_to_binary(iodata)

    table =
      0..255
      |> Enum.map(fn byte ->
        Enum.reduce(1..8, byte, fn _bit, crc ->
          if Bitwise.band(crc, 1) == 1 do
            Bitwise.bxor(Bitwise.bsr(crc, 1), 0x9A6C9329AC4BC9B5)
          else
            Bitwise.bsr(crc, 1)
          end
        end)
      end)
      |> List.to_tuple()

    crc =
      for <<byte <- data>>, reduce: Bitwise.bxor(0, 0xFFFFFFFFFFFFFFFF) do
        crc ->
          table_index = Bitwise.band(Bitwise.bxor(crc, byte), 0xFF)
          table_value = elem(table, table_index)
          Bitwise.bxor(Bitwise.bsr(crc, 8), table_value)
      end

    <<Bitwise.band(Bitwise.bxor(crc, 0xFFFFFFFFFFFFFFFF), 0xFFFFFFFFFFFFFFFF)::64>>
  end
end
