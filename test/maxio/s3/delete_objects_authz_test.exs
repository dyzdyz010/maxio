defmodule Maxio.S3.DeleteObjectsAuthzTest do
  use Maxio.DataCase, async: false
  alias Maxio.Test.SigV4Request
  alias Maxio.S3.Endpoint

  @data_dir Path.join(System.tmp_dir!(), "maxio_delobjs_authz")

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

  test "对象级 s3:DeleteObject 策略授权匿名批删（桶 ARN 策略不再是唯一可行写法）" do
    SigV4Request.signed_conn(:put, "/doa1") |> call()
    SigV4Request.signed_conn(:put, "/doa1/k.txt", body: "x") |> call()

    policy =
      ~s({"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":"*","Action":["s3:DeleteObject"],"Resource":["arn:aws:s3:::doa1/*"]}]})

    SigV4Request.signed_conn(:put, "/doa1", query: %{"policy" => ""}, body: policy) |> call()

    body = ~s(<Delete><Object><Key>k.txt</Key></Object></Delete>)
    res = SigV4Request.anon_conn(:post, "/doa1", query: %{"delete" => ""}, body: body) |> call()

    assert res.status == 200
    assert res.resp_body =~ "<Deleted><Key>k.txt</Key></Deleted>"
    refute res.resp_body =~ "AccessDenied"

    # key 已被删除
    g = SigV4Request.signed_conn(:get, "/doa1/k.txt") |> call()
    assert g.status == 404
  end

  test "无授权的匿名批删 key → per-key <Error>AccessDenied</Error>，HTTP 200 且不被删" do
    SigV4Request.signed_conn(:put, "/doa2") |> call()
    SigV4Request.signed_conn(:put, "/doa2/k.txt", body: "x") |> call()

    body = ~s(<Delete><Object><Key>k.txt</Key></Object></Delete>)
    res = SigV4Request.anon_conn(:post, "/doa2", query: %{"delete" => ""}, body: body) |> call()

    assert res.status == 200
    assert res.resp_body =~ "AccessDenied"
    refute res.resp_body =~ "<Deleted><Key>k.txt</Key></Deleted>"

    # key 仍在（未授权的删除绝不静默执行）
    g = SigV4Request.signed_conn(:get, "/doa2/k.txt") |> call()
    assert g.status == 200
  end

  test "混合批删：有权 key 删、无权 key 回 per-key AccessDenied 且存活" do
    SigV4Request.signed_conn(:put, "/doa3") |> call()
    SigV4Request.signed_conn(:put, "/doa3/allow.txt", body: "a") |> call()
    SigV4Request.signed_conn(:put, "/doa3/deny.txt", body: "d") |> call()

    # 仅对 allow.txt 这个具体对象 ARN 授予匿名 s3:DeleteObject。
    policy =
      ~s({"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":"*","Action":["s3:DeleteObject"],"Resource":["arn:aws:s3:::doa3/allow.txt"]}]})

    SigV4Request.signed_conn(:put, "/doa3", query: %{"policy" => ""}, body: policy) |> call()

    body =
      ~s(<Delete><Object><Key>allow.txt</Key></Object><Object><Key>deny.txt</Key></Object></Delete>)

    res = SigV4Request.anon_conn(:post, "/doa3", query: %{"delete" => ""}, body: body) |> call()

    assert res.status == 200
    assert res.resp_body =~ "<Deleted><Key>allow.txt</Key></Deleted>"
    assert res.resp_body =~ "<Key>deny.txt</Key>"
    assert res.resp_body =~ "AccessDenied"

    # allow.txt 被删，deny.txt 存活
    g_allow = SigV4Request.signed_conn(:get, "/doa3/allow.txt") |> call()
    assert g_allow.status == 404
    g_deny = SigV4Request.signed_conn(:get, "/doa3/deny.txt") |> call()
    assert g_deny.status == 200
  end

  test "owner（root signed）批删无需显式 policy（owner 短路放行）" do
    SigV4Request.signed_conn(:put, "/doa4") |> call()
    SigV4Request.signed_conn(:put, "/doa4/k.txt", body: "x") |> call()

    body = ~s(<Delete><Object><Key>k.txt</Key></Object></Delete>)
    res = SigV4Request.signed_conn(:post, "/doa4", query: %{"delete" => ""}, body: body) |> call()

    assert res.status == 200
    assert res.resp_body =~ "<Deleted><Key>k.txt</Key></Deleted>"
    refute res.resp_body =~ "AccessDenied"

    g = SigV4Request.signed_conn(:get, "/doa4/k.txt") |> call()
    assert g.status == 404
  end
end
