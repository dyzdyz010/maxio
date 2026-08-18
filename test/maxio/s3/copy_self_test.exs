defmodule Maxio.S3.CopySelfTest do
  use Maxio.DataCase, async: false

  import Plug.Conn
  alias Maxio.Test.SigV4Request
  alias Maxio.S3.Endpoint

  @data_dir Path.join(System.tmp_dir!(), "maxio_copyself_test")

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

  # 桶名须 3..63 字符（S3 规则 + Maxio.Buckets.validate_creatable_name/1）；用合法桶名 "cself"。
  test "CopyObject REPLACE 自拷贝 不丢字节（src==dest, metadata-directive=REPLACE）" do
    SigV4Request.signed_conn(:put, "/cself") |> call()
    body = "Welcome to Amazon S3. Self-copy must not truncate."

    put =
      SigV4Request.signed_conn(:put, "/cself/self.txt",
        body: body,
        headers: [{"content-type", "text/plain"}]
      )
      |> call()

    assert put.status == 200

    copy =
      SigV4Request.signed_conn(:put, "/cself/self.txt",
        headers: [
          {"x-amz-copy-source", "/cself/self.txt"},
          {"x-amz-metadata-directive", "REPLACE"},
          {"content-type", "application/octet-stream"}
        ]
      )
      |> call()

    assert copy.status == 200

    get = SigV4Request.signed_conn(:get, "/cself/self.txt") |> call()
    assert get.status == 200
    assert get.resp_body == body
    assert get_resp_header(get, "content-type") == ["application/octet-stream"]
  end
end
