defmodule Maxio.S3.CorsE2ETest do
  use Maxio.DataCase, async: false
  import Plug.Conn
  alias Maxio.Test.SigV4Request
  alias Maxio.S3.Endpoint

  @data_dir Path.join(System.tmp_dir!(), "maxio_cors_e2e")
  @cors ~s(<CORSConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><CORSRule><AllowedOrigin>http://www.example.com</AllowedOrigin><AllowedMethod>PUT</AllowedMethod><AllowedMethod>GET</AllowedMethod><AllowedHeader>*</AllowedHeader><MaxAgeSeconds>3000</MaxAgeSeconds><ExposeHeader>ETag</ExposeHeader></CORSRule></CORSConfiguration>)

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

  test "PutBucketCors 200 → GetBucketCors 回放 → DeleteBucketCors 204 → Get 404" do
    SigV4Request.signed_conn(:put, "/corb") |> call()
    put = SigV4Request.signed_conn(:put, "/corb", query: %{"cors" => ""}, body: @cors) |> call()
    assert put.status == 200
    get = SigV4Request.signed_conn(:get, "/corb", query: %{"cors" => ""}) |> call()
    assert get.resp_body =~ "http://www.example.com"
    del = SigV4Request.signed_conn(:delete, "/corb", query: %{"cors" => ""}) |> call()
    assert del.status == 204
    g2 = SigV4Request.signed_conn(:get, "/corb", query: %{"cors" => ""}) |> call()
    assert g2.status == 404
    assert g2.resp_body =~ "NoSuchCORSConfiguration"
  end

  test "OPTIONS 预检（不签名）命中 → 200 + Access-Control-Allow-Origin" do
    SigV4Request.signed_conn(:put, "/cb2") |> call()
    SigV4Request.signed_conn(:put, "/cb2", query: %{"cors" => ""}, body: @cors) |> call()

    pre =
      SigV4Request.anon_conn(:options, "/cb2/obj.txt",
        headers: [{"origin", "http://www.example.com"}, {"access-control-request-method", "PUT"}]
      )
      |> call()

    assert pre.status == 200
    assert get_resp_header(pre, "access-control-allow-origin") == ["http://www.example.com"]
    assert get_resp_header(pre, "access-control-allow-methods") == ["PUT"]
    assert get_resp_header(pre, "access-control-max-age") == ["3000"]
  end

  test "OPTIONS 预检 origin 不允许 → 403 AccessForbidden" do
    SigV4Request.signed_conn(:put, "/cb3") |> call()
    SigV4Request.signed_conn(:put, "/cb3", query: %{"cors" => ""}, body: @cors) |> call()

    pre =
      SigV4Request.anon_conn(:options, "/cb3/obj.txt",
        headers: [{"origin", "http://evil.com"}, {"access-control-request-method", "PUT"}]
      )
      |> call()

    assert pre.status == 403
    assert pre.resp_body =~ "AccessForbidden"
  end

  test "OPTIONS 预检 未配置 CORS → 403 AccessForbidden" do
    SigV4Request.signed_conn(:put, "/cb5") |> call()

    pre =
      SigV4Request.anon_conn(:options, "/cb5/obj.txt",
        headers: [{"origin", "http://www.example.com"}, {"access-control-request-method", "PUT"}]
      )
      |> call()

    assert pre.status == 403
    assert pre.resp_body =~ "AccessForbidden"
  end

  test "实际 GET 带 Origin → 注入 Access-Control-Allow-Origin + Vary（流式不破）" do
    SigV4Request.signed_conn(:put, "/cb4") |> call()
    SigV4Request.signed_conn(:put, "/cb4", query: %{"cors" => ""}, body: @cors) |> call()
    SigV4Request.signed_conn(:put, "/cb4/o.txt", body: "hello") |> call()

    get =
      SigV4Request.signed_conn(:get, "/cb4/o.txt",
        headers: [{"origin", "http://www.example.com"}]
      )
      |> call()

    assert get.status == 200
    assert get.resp_body == "hello"
    assert get_resp_header(get, "access-control-allow-origin") == ["http://www.example.com"]
    assert "Origin" in get_resp_header(get, "vary")
  end

  test "预检命中 → 回 Access-Control-Allow-Credentials: true" do
    SigV4Request.signed_conn(:put, "/cbc1") |> call()
    SigV4Request.signed_conn(:put, "/cbc1", query: %{"cors" => ""}, body: @cors) |> call()

    pre =
      SigV4Request.anon_conn(:options, "/cbc1/obj.txt",
        headers: [{"origin", "http://www.example.com"}, {"access-control-request-method", "PUT"}]
      )
      |> call()

    assert pre.status == 200
    assert get_resp_header(pre, "access-control-allow-credentials") == ["true"]
  end

  test "实际跨源响应 → 回 Access-Control-Allow-Credentials: true" do
    SigV4Request.signed_conn(:put, "/cbc2") |> call()
    SigV4Request.signed_conn(:put, "/cbc2", query: %{"cors" => ""}, body: @cors) |> call()
    SigV4Request.signed_conn(:put, "/cbc2/o.txt", body: "x") |> call()

    res =
      SigV4Request.signed_conn(:get, "/cbc2/o.txt",
        headers: [{"origin", "http://www.example.com"}]
      )
      |> call()

    assert get_resp_header(res, "access-control-allow-credentials") == ["true"]
  end
end
