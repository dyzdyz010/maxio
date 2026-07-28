defmodule Maxio.S3.DeleteObjectsAuthzTest do
  use Maxio.DataCase, async: false
  alias Maxio.Auth.CredentialStore
  alias Maxio.IAM
  alias Maxio.Policy.Store
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

  defp unique_access_key(prefix) do
    suffix =
      [System.unique_integer([:positive]), System.monotonic_time()]
      |> :erlang.phash2()
      |> Integer.to_string(36)
      |> String.upcase()

    "AKIA" <> prefix <> suffix
  end

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

  test "owner（root signed）批删逐 key 遵守显式 Deny" do
    SigV4Request.signed_conn(:put, "/doa5") |> call()
    SigV4Request.signed_conn(:put, "/doa5/k.txt", body: "x") |> call()

    policy =
      ~s({"Version":"2012-10-17","Statement":[{"Effect":"Deny","Principal":"*","Action":"s3:DeleteObject","Resource":"arn:aws:s3:::doa5/k.txt"}]})

    SigV4Request.signed_conn(:put, "/doa5", query: %{"policy" => ""}, body: policy) |> call()

    body = ~s(<Delete><Object><Key>k.txt</Key></Object></Delete>)
    res = SigV4Request.signed_conn(:post, "/doa5", query: %{"delete" => ""}, body: body) |> call()

    assert res.status == 200
    assert res.resp_body =~ "<Key>k.txt</Key>"
    assert res.resp_body =~ "AccessDenied"
    refute res.resp_body =~ "<Deleted><Key>k.txt</Key></Deleted>"

    g = SigV4Request.signed_conn(:get, "/doa5/k.txt") |> call()
    assert g.status == 200
    assert g.resp_body == "x"
  end

  test "DeleteObjects per-key auth enforces permissions boundary explicit deny" do
    bucket = "doa-boundary"
    key = "k.txt"

    SigV4Request.signed_conn(:put, "/#{bucket}") |> call()
    SigV4Request.signed_conn(:put, "/#{bucket}/#{key}", body: "x") |> call()

    user_name = "delete-boundary-#{System.unique_integer([:positive])}"
    access_key = unique_access_key("DELOBJ")
    secret = "delete-boundary-secret-123456"

    assert {:ok, user} = IAM.create_user(name: user_name)

    assert :ok =
             CredentialStore.put_access_key(%{
               access_key: access_key,
               secret_key: secret,
               principal: %{type: :iam_user, access_key: access_key, arn: user.user_arn}
             })

    identity_policy =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:DeleteObject","Resource":"arn:aws:s3:::#{bucket}/#{key}"}})

    boundary_policy =
      ~s({"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"s3:*","Resource":["arn:aws:s3:::#{bucket}","arn:aws:s3:::#{bucket}/*"]},{"Effect":"Deny","Action":"s3:DeleteObject","Resource":"arn:aws:s3:::#{bucket}/#{key}"}]})

    assert :ok = Store.put_principal_policy(user.user_arn, "allow-delete-object", identity_policy)

    assert {:ok, boundary} =
             IAM.create_managed_policy(
               name: "delete-boundary-#{System.unique_integer([:positive])}",
               path: "/authz/",
               policy: boundary_policy
             )

    assert {:ok, _user} =
             IAM.put_user_permissions_boundary_strict(user.user_name, boundary.policy_arn)

    body = ~s(<Delete><Object><Key>#{key}</Key></Object></Delete>)

    res =
      SigV4Request.signed_conn(:post, "/#{bucket}",
        query: %{"delete" => ""},
        access_key: access_key,
        secret: secret,
        body: body
      )
      |> call()

    assert res.status == 200
    assert res.resp_body =~ "<Key>#{key}</Key>"
    assert res.resp_body =~ "AccessDenied"
    refute res.resp_body =~ "<Deleted><Key>#{key}</Key></Deleted>"

    still_there = SigV4Request.signed_conn(:get, "/#{bucket}/#{key}") |> call()
    assert still_there.status == 200
    assert still_there.resp_body == "x"
  end
end
