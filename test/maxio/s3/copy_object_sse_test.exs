defmodule Maxio.S3.CopyObjectSseTest do
  use Maxio.DataCase, async: false

  import Plug.Conn
  alias Maxio.Objects
  alias Maxio.S3.Endpoint
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

  test "CopyObject rejects unsupported source SSE-C headers instead of ignoring them" do
    bucket = "cpsse4"

    SigV4Request.signed_conn(:put, "/#{bucket}") |> call()
    SigV4Request.signed_conn(:put, "/#{bucket}/src.txt", body: "x") |> call()

    copy =
      SigV4Request.signed_conn(:put, "/#{bucket}/dst.txt",
        headers: [
          {"x-amz-copy-source", "/#{bucket}/src.txt"},
          {"x-amz-copy-source-server-side-encryption-customer-algorithm", "AES256"}
        ]
      )
      |> call()

    assert copy.status == 501
    assert copy.resp_body =~ "NotImplemented"
  end

  test "CopyObject rejects source SSE-C key headers even without the algorithm header" do
    bucket = "cpsse5"

    SigV4Request.signed_conn(:put, "/#{bucket}") |> call()
    SigV4Request.signed_conn(:put, "/#{bucket}/src.txt", body: "x") |> call()

    copy =
      SigV4Request.signed_conn(:put, "/#{bucket}/dst.txt",
        headers: [
          {"x-amz-copy-source", "/#{bucket}/src.txt"},
          {"x-amz-copy-source-server-side-encryption-customer-key", "not-used"},
          {"x-amz-copy-source-server-side-encryption-customer-key-md5", "not-used"}
        ]
      )
      |> call()

    assert copy.status == 501
    assert copy.resp_body =~ "NotImplemented"
  end
end
