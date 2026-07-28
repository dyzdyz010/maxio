defmodule Maxio.S3.AuthzTest do
  use Maxio.DataCase, async: false

  import Plug.Conn
  alias Maxio.Test.SigV4Request
  alias Maxio.S3.Endpoint

  @data_dir Path.join(System.tmp_dir!(), "maxio_authz_test")
  @public_get ~s({"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":"*","Action":"s3:GetObject","Resource":"arn:aws:s3:::pubb/*"}]})

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

  defp create_acl_bucket(bucket) do
    SigV4Request.signed_conn(:put, "/#{bucket}",
      headers: [{"x-amz-object-ownership", "ObjectWriter"}]
    )
    |> call()
  end

  test "root（owner）始终放行（owner 短路）" do
    SigV4Request.signed_conn(:put, "/rootb") |> call()
    put = SigV4Request.signed_conn(:put, "/rootb/k.txt", body: "x") |> call()
    assert put.status == 200
    get = SigV4Request.signed_conn(:get, "/rootb/k.txt") |> call()
    assert get.status == 200
  end

  test "匿名请求无 policy → 403 AccessDenied（默认拒绝，绝不静默放行）" do
    SigV4Request.signed_conn(:put, "/privb") |> call()
    SigV4Request.signed_conn(:put, "/privb/secret.txt", body: "top") |> call()

    anon = SigV4Request.anon_conn(:get, "/privb/secret.txt") |> call()
    assert anon.status == 403
    assert anon.resp_body =~ "AccessDenied"
  end

  test "匿名请求 + public bucket policy → 放行 GetObject" do
    SigV4Request.signed_conn(:put, "/pubb") |> call()
    SigV4Request.signed_conn(:put, "/pubb/open.txt", body: "hello world") |> call()

    # owner（root）装 public-read policy
    SigV4Request.signed_conn(:put, "/pubb",
      query: %{"policy" => ""},
      body: @public_get,
      headers: [{"content-type", "application/json"}]
    )
    |> call()

    anon = SigV4Request.anon_conn(:get, "/pubb/open.txt") |> call()
    assert anon.status == 200
    assert anon.resp_body == "hello world"
  end

  test "匿名 public GetObject/HeadObject 不能使用 response header override" do
    SigV4Request.signed_conn(:put, "/pubb") |> call()
    SigV4Request.signed_conn(:put, "/pubb/open.txt", body: "hello world") |> call()

    SigV4Request.signed_conn(:put, "/pubb",
      query: %{"policy" => ""},
      body: @public_get,
      headers: [{"content-type", "application/json"}]
    )
    |> call()

    get =
      SigV4Request.anon_conn(:get, "/pubb/open.txt",
        query: %{"response-content-type" => "text/plain"}
      )
      |> call()

    assert get.status == 403
    assert get.resp_body =~ "AccessDenied"

    head =
      SigV4Request.anon_conn(:head, "/pubb/open.txt",
        query: %{"response-content-type" => "text/plain"}
      )
      |> call()

    assert head.status == 403
    assert head.resp_body == ""
  end

  test "匿名请求 + public-read ACL 对象 → 放行 GetObject" do
    create_acl_bucket("aclb")

    SigV4Request.signed_conn(:put, "/aclb/p.txt",
      body: "acl-open",
      headers: [{"x-amz-acl", "public-read"}]
    )
    |> call()

    anon = SigV4Request.anon_conn(:get, "/aclb/p.txt") |> call()
    assert anon.status == 200
    assert anon.resp_body == "acl-open"
  end

  test "匿名 + public-read 只放行 Get，不放行 Delete → 403" do
    create_acl_bucket("rob")

    SigV4Request.signed_conn(:put, "/rob/x.txt",
      body: "ro",
      headers: [{"x-amz-acl", "public-read"}]
    )
    |> call()

    del = SigV4Request.anon_conn(:delete, "/rob/x.txt") |> call()
    assert del.status == 403
    assert del.resp_body =~ "AccessDenied"
  end

  test "显式 Deny policy 压倒 → 即便有 Allow，匿名仍被拒（owner 仍短路）" do
    SigV4Request.signed_conn(:put, "/denyb") |> call()
    SigV4Request.signed_conn(:put, "/denyb/d.txt", body: "deny") |> call()

    deny =
      ~s({"Statement":[{"Effect":"Allow","Principal":"*","Action":"s3:GetObject","Resource":"arn:aws:s3:::denyb/*"},{"Effect":"Deny","Principal":"*","Action":"s3:GetObject","Resource":"arn:aws:s3:::denyb/*"}]})

    SigV4Request.signed_conn(:put, "/denyb",
      query: %{"policy" => ""},
      body: deny,
      headers: [{"content-type", "application/json"}]
    )
    |> call()

    anon = SigV4Request.anon_conn(:get, "/denyb/d.txt") |> call()
    assert anon.status == 403
  end

  test "坏凭据仍硬失败（不退化为匿名）：篡改签名 → 403 SignatureDoesNotMatch" do
    SigV4Request.signed_conn(:put, "/badb") |> call()

    conn = SigV4Request.signed_conn(:get, "/badb", query: %{"location" => ""})
    [auth] = get_req_header(conn, "authorization")
    tampered = String.replace(auth, ~r/Signature=.*/, "Signature=deadbeef")

    bad =
      conn
      |> delete_req_header("authorization")
      |> put_req_header("authorization", tampered)
      |> call()

    assert bad.status == 403
    assert bad.resp_body =~ "SignatureDoesNotMatch"
  end

  test "完全无凭据访问 service 级 ListBuckets → 403（账户级默认拒绝匿名）" do
    anon = SigV4Request.anon_conn(:get, "/") |> call()
    assert anon.status == 403
  end
end
