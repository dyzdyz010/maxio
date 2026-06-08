defmodule Maxio.S3.ErasureE2ETest do
  @moduledoc """
  把存储后端 config-select 到 Maxio.Storage.ErasureCoded，跑一片 S3 e2e（经 Endpoint.call/2 自签 SigV4）：
  CreateBucket -> PutObject（流式）-> GetObject 全量 -> Range -> HeadObject -> DeleteObject。
  证明纠删码后端在真实 S3 请求管线下满足同一契约（铁律 2：核心管线一行不改）。

  调用形态逐字对齐既有 test/maxio/s3/integration_test.exs（Maxio.DataCase + 自定义 call/1 经
  Endpoint.call(conn, Endpoint.init([]))；ETag 带引号；Range -> 206 + content-range）；
  仅把 storage_backend 临时切到 ErasureCoded 并指向临时盘目录（铁律 5：字节后端可换，元数据上下文不变）。
  """
  use Maxio.DataCase, async: false

  import Plug.Conn
  alias Maxio.S3.Endpoint
  alias Maxio.Test.SigV4Request

  setup do
    base = Path.join(System.tmp_dir!(), "maxio_ec_e2e_#{System.unique_integer([:positive])}")
    drives = for i <- 0..5, do: Path.join(base, "d#{i}")
    Enum.each(drives, &File.mkdir_p!/1)

    prev_backend = Application.get_env(:maxio, :storage_backend)
    prev_ec = Application.get_env(:maxio, :erasure)

    Application.put_env(:maxio, :storage_backend, Maxio.Storage.ErasureCoded)

    Application.put_env(:maxio, :erasure,
      drives: drives,
      data_shards: 4,
      parity_shards: 2,
      block_size: 1024
    )

    on_exit(fn ->
      Application.put_env(:maxio, :storage_backend, prev_backend)

      if prev_ec,
        do: Application.put_env(:maxio, :erasure, prev_ec),
        else: Application.delete_env(:maxio, :erasure)

      File.rm_rf(base)
    end)

    :ok
  end

  defp call(conn), do: Endpoint.call(conn, Endpoint.init([]))

  test "纠删码后端下 PutObject/GetObject/Range/Head/Delete e2e" do
    bucket = "ecbucket"
    key = "obj.bin"
    body = :crypto.strong_rand_bytes(3000)

    # CreateBucket
    conn = SigV4Request.signed_conn(:put, "/#{bucket}") |> call()
    assert conn.status == 200

    # PutObject（single；复用 SigV4Request 默认上传方式，与 integration_test 一致）
    conn = SigV4Request.signed_conn(:put, "/#{bucket}/#{key}", body: body) |> call()
    assert conn.status == 200
    expected_etag = "\"" <> (:crypto.hash(:md5, body) |> Base.encode16(case: :lower)) <> "\""
    assert get_resp_header(conn, "etag") == [expected_etag]

    # GetObject 全量
    conn = SigV4Request.signed_conn(:get, "/#{bucket}/#{key}") |> call()
    assert conn.status == 200
    assert conn.resp_body == body

    # Range（含端点 0-based，跨多块：block_size=1024）
    conn =
      SigV4Request.signed_conn(:get, "/#{bucket}/#{key}", headers: [{"range", "bytes=1000-1999"}])
      |> call()

    assert conn.status == 206
    assert get_resp_header(conn, "content-range") == ["bytes 1000-1999/3000"]
    assert conn.resp_body == binary_part(body, 1000, 1000)

    # HeadObject
    conn = SigV4Request.signed_conn(:head, "/#{bucket}/#{key}") |> call()
    assert conn.status == 200
    assert conn.resp_body == ""
    assert get_resp_header(conn, "content-length") == ["3000"]

    # DeleteObject -> 再 Get 404
    conn = SigV4Request.signed_conn(:delete, "/#{bucket}/#{key}") |> call()
    assert conn.status == 204
    conn = SigV4Request.signed_conn(:get, "/#{bucket}/#{key}") |> call()
    assert conn.status == 404
    assert conn.resp_body =~ "<Code>NoSuchKey</Code>"
  end
end
