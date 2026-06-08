defmodule Maxio.S3.SseE2ETest do
  use Maxio.DataCase, async: false
  import Plug.Conn
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

    # 磁盘上是密文（不含明文片段）。SSE 对象落 null 版本路径 <data_dir>/sseb/secret.txt。
    on_disk = File.read!(Path.join([@data_dir, "sseb", "secret.txt"]))
    refute on_disk =~ "encrypt me"
  end

  test "桶默认加密 AES256 → 无头 PUT 也加密" do
    SigV4Request.signed_conn(:put, "/sseb2") |> call()

    enc =
      ~s(<ServerSideEncryptionConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Rule><ApplyServerSideEncryptionByDefault><SSEAlgorithm>AES256</SSEAlgorithm></ApplyServerSideEncryptionByDefault></Rule></ServerSideEncryptionConfiguration>)

    SigV4Request.signed_conn(:put, "/sseb2", query: %{"encryption" => ""}, body: enc) |> call()

    put = SigV4Request.signed_conn(:put, "/sseb2/o.txt", body: "default-enc") |> call()
    assert get_resp_header(put, "x-amz-server-side-encryption") == ["AES256"]
    get = SigV4Request.signed_conn(:get, "/sseb2/o.txt") |> call()
    assert get.resp_body == "default-enc"
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

  test "GetBucketEncryption 无配置 → 404" do
    SigV4Request.signed_conn(:put, "/sseb4") |> call()
    res = SigV4Request.signed_conn(:get, "/sseb4", query: %{"encryption" => ""}) |> call()
    assert res.status == 404
    assert res.resp_body =~ "ServerSideEncryptionConfigurationNotFoundError"
  end
end
