defmodule Maxio.Admin.InfoEndpointTest do
  @moduledoc """
  `GET /minio/admin/v3/info` 的端到端管线回归（设计 §13 T2）：走真实的
  `Maxio.S3.Endpoint` plug 链（AddressStyle → SigV4 → Admin.Plug），签名用**空 region**
  的 credential scope 复现 madmin 的确切行为。

  授权是 identity-policy only：bucket policy 与 ACL 绝不能授予集群级 admin 动作
  （与 `Maxio.S3.PrometheusAuthz` 的立场逐字一致）。
  """
  use Maxio.DataCase, async: false

  alias Maxio.Admin.ServerInfo
  alias Maxio.Auth.CredentialStore
  alias Maxio.Config.Store
  alias Maxio.Policy.Store, as: PolicyStore
  alias Maxio.S3.Endpoint
  alias Maxio.Test.SigV4Request

  @path "/minio/admin/v3/info"
  @alice_ak "AKIAADMININFO00001"
  @alice_secret "admin-info-secret-0001"
  @alice_arn "arn:aws:iam:::user/#{@alice_ak}"

  setup do
    Store.reset_local!()
    ServerInfo.invalidate_cache()

    on_exit(fn ->
      Store.reset_local!()
      ServerInfo.invalidate_cache()
    end)

    :ok
  end

  test "root 用 madmin 风格的空 region scope 拿到 200 明文 JSON ServerInfo" do
    conn = signed(:get, @path, region: "", query: %{"metrics" => "false"})

    assert conn.status == 200
    assert content_type(conn) =~ "application/json"

    info = Jason.decode!(conn.resp_body)

    assert info["mode"] == "online"
    assert is_list(info["domain"])
    assert is_binary(info["deploymentID"])
    assert [server] = info["servers"]
    assert server["state"] == "online"
    assert server["version"] == to_string(Application.spec(:maxio, :vsn))
    assert server["runtime_version"] =~ "Elixir"
    assert info["backend"]["backendType"] == "FS"

    # 响应体绝不是 S3 XML——madmin 只解 JSON，拿到 XML 会退化成 "bucket does not exist"。
    refute conn.resp_body =~ "<Error>"
  end

  test "endpoint 反映请求真实到达的 host 与监听端口" do
    conn = signed(:get, @path)
    server = conn.resp_body |> Jason.decode!() |> Map.fetch!("servers") |> hd()
    port = Application.get_env(:maxio, Maxio.S3.Endpoint, [])[:port]

    assert server["endpoint"] == "localhost:#{port}"
    assert server["scheme"] == "http"
  end

  test "匿名请求是 403 JSON，不是 501，也不是 XML" do
    conn =
      :get
      |> SigV4Request.anon_conn(@path)
      |> Endpoint.call(Endpoint.init([]))

    assert conn.status == 403
    assert content_type(conn) =~ "application/json"
    body = Jason.decode!(conn.resp_body)
    assert body["Code"] == "AccessDenied"
    assert body["Resource"] == @path
  end

  test "无 policy 的 IAM 用户被 403 JSON 拒绝；加上 admin:ServerInfo 后放行" do
    put_alice_key()

    denied = signed(:get, @path, access_key: @alice_ak, secret: @alice_secret)
    assert denied.status == 403
    assert Jason.decode!(denied.resp_body)["Code"] == "AccessDenied"

    # MinIO 官方最小 admin policy 的形态：Action 全是 admin:*，**无 Resource**。
    # 依赖 Maxio.Policy.Statement.maybe_default_admin_resource/1 的既有口子。
    assert :ok =
             PolicyStore.put_principal_policy(
               @alice_arn,
               "admin-info",
               ~s({"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"admin:ServerInfo"}]})
             )

    allowed = signed(:get, @path, access_key: @alice_ak, secret: @alice_secret)
    assert allowed.status == 200
    assert Jason.decode!(allowed.resp_body)["backend"]["backendType"] == "FS"
  end

  test "显式 Deny 压过 Allow" do
    put_alice_key()

    assert :ok =
             PolicyStore.put_principal_policy(
               @alice_arn,
               "admin-info",
               ~s({"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"admin:ServerInfo"},{"Effect":"Deny","Action":"admin:ServerInfo"}]})
             )

    assert signed(:get, @path, access_key: @alice_ak, secret: @alice_secret).status == 403
  end

  test "错误签名仍被 SigV4 挡在 admin 面之前（XML SignatureDoesNotMatch）" do
    conn = signed(:get, @path, secret: "not-the-root-secret")

    assert conn.status == 403
    assert conn.resp_body =~ "<Code>SignatureDoesNotMatch</Code>"
  end

  test "no-cache query 绕过 usage 缓存" do
    {:ok, _} = Maxio.Buckets.create("admin-info-nocache-a", "arn:aws:iam:::root")
    first = signed(:get, @path) |> decode()
    assert first["buckets"]["count"] == 1

    {:ok, _} = Maxio.Buckets.create("admin-info-nocache-b", "arn:aws:iam:::root")
    assert signed(:get, @path) |> decode() |> get_in(["buckets", "count"]) == 1

    bypassed = signed(:get, @path, query: %{"no-cache" => "true"}) |> decode()
    assert bypassed["buckets"]["count"] == 2
  end

  test "非 GET 方法落回 501 JSON，绝不 404" do
    conn = signed(:put, @path)

    assert conn.status == 501
    assert Jason.decode!(conn.resp_body)["Code"] == "NotImplemented"
  end

  test "vhost 寻址下 /minio/admin/v3/info 不被认领（保留面只在 path-style 生效）" do
    conn = signed(:get, @path, host: "somebucket.localhost")

    refute conn.status == 200
    assert conn.resp_body =~ "<Code>"
  end

  defp signed(method, path, opts \\ []) do
    method
    |> SigV4Request.signed_conn(path, opts)
    |> Endpoint.call(Endpoint.init([]))
  end

  defp decode(conn), do: Jason.decode!(conn.resp_body)

  defp content_type(conn) do
    conn |> Plug.Conn.get_resp_header("content-type") |> List.first() || ""
  end

  defp put_alice_key do
    :ok =
      CredentialStore.put_access_key(%{
        access_key: @alice_ak,
        secret_key: @alice_secret,
        principal: %{type: :iam_user, access_key: @alice_ak, arn: @alice_arn}
      })
  end
end
