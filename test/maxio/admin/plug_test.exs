defmodule Maxio.Admin.PlugTest do
  @moduledoc """
  `/minio/admin/*` 骨架：挂在 SigV4 之后、Dispatch 之前，需要已认证 principal，
  本批不实现任何真实端点，统一 501 **JSON**（madmin 只解 JSON，收到 S3 XML 会退化成
  "The specified bucket does not exist."——那正是接入前的实测症状）。
  """
  use Maxio.DataCase, async: false

  alias Maxio.S3.Endpoint
  alias Maxio.Test.SigV4Request

  # /minio/admin/v3/info 已在 ServerInfo 批次实现（见 Maxio.Admin.InfoEndpointTest）；
  # 本文件断言的是**未实现端点**的骨架契约，故一律用仍未实现的路径取样。
  @unimplemented "/minio/admin/v3/storageinfo"

  test "authenticated admin request returns 501 JSON instead of S3 XML" do
    conn = signed(:get, @unimplemented, query: %{"metrics" => "false"})

    assert conn.status == 501
    assert content_type(conn) =~ "application/json"

    body = Jason.decode!(conn.resp_body)
    assert body["Code"] == "NotImplemented"
    assert is_binary(body["Message"]) and body["Message"] != ""
    assert body["Resource"] == @unimplemented
    assert Map.has_key?(body, "RequestId")
    assert Map.has_key?(body, "HostId")
    refute conn.resp_body =~ "<Error>"
  end

  test "madmin style empty region credential scope still reaches the admin surface" do
    # madmin 的 credential scope region 段恒为空（".../<date>//s3/aws4_request"）。
    conn = signed(:get, @unimplemented, region: "")

    assert conn.status == 501
    assert Jason.decode!(conn.resp_body)["Code"] == "NotImplemented"
  end

  test "anonymous admin request is denied with JSON AccessDenied" do
    conn =
      :get
      |> SigV4Request.anon_conn("/minio/admin/v3/info")
      |> Endpoint.call(Endpoint.init([]))

    assert conn.status == 403
    assert content_type(conn) =~ "application/json"

    body = Jason.decode!(conn.resp_body)
    assert body["Code"] == "AccessDenied"
    assert body["Resource"] == "/minio/admin/v3/info"
  end

  test "bad credentials are still rejected by SigV4 before the admin surface" do
    conn = signed(:get, "/minio/admin/v3/info", secret: "not-the-root-secret")

    assert conn.status == 403
    assert conn.resp_body =~ "<Code>SignatureDoesNotMatch</Code>"
  end

  test "unknown admin paths and versions also return 501 JSON, never 404 XML" do
    for path <- ["/minio/admin/v3/nope", "/minio/admin/v4/info", "/minio/admin/"] do
      conn = signed(:get, path)

      assert conn.status == 501
      assert Jason.decode!(conn.resp_body)["Code"] == "NotImplemented"
    end
  end

  test "Config KVS neighboring versions methods and deferred catalogs remain JSON 501" do
    # Catches prefix dispatch while adding the three exact Config KVS method/path triples.
    for {method, path, query} <- [
          {:post, "/minio/admin/v3/get-config-kv", %{}},
          {:get, "/minio/admin/v3/set-config-kv", %{}},
          {:put, "/minio/admin/v3/del-config-kv", %{}},
          {:get, "/minio/admin/v4/get-config-kv", %{}},
          {:get, "/minio/admin/v3/get-config-kv/extra", %{}},
          {:post, "/minio/admin/v3/help-config-kv", %{"subSys" => "", "key" => ""}},
          {:get, "/minio/admin/v4/help-config-kv", %{"subSys" => "", "key" => ""}},
          {:get, "/minio/admin/v3/help-config-kv/extra", %{"subSys" => "", "key" => ""}},
          {:get, "/minio/admin/v3/config", %{}},
          {:get, "/minio/admin/v3/list-config-history-kv", %{"count" => "10"}},
          {:delete, "/minio/admin/v3/clear-config-history-kv",
           %{"restoreId" => "fixture-restore-id"}},
          {:put, "/minio/admin/v3/restore-config-history-kv",
           %{"restoreId" => "fixture-restore-id"}}
        ] do
      conn = signed(method, path, query: query, region: "")

      assert conn.status == 501
      assert content_type(conn) =~ "application/json"
      assert Jason.decode!(conn.resp_body)["Code"] == "NotImplemented"
    end
  end

  test "anonymous Config KVS requests are denied before route query or body details" do
    # Catches route matching, missing-key classification, or mutation framing moving above auth.
    for {method, path} <- [
          {:get, "/minio/admin/v3/get-config-kv"},
          {:get, "/minio/admin/v3/help-config-kv"},
          {:put, "/minio/admin/v3/set-config-kv"},
          {:delete, "/minio/admin/v3/del-config-kv"}
        ] do
      conn =
        method
        |> SigV4Request.anon_conn(path)
        |> Endpoint.call(Endpoint.init([]))

      assert conn.status == 403
      assert Jason.decode!(conn.resp_body)["Code"] == "AccessDenied"
    end
  end

  test "authentication is decided by auth_type, not by the shape of the principal" do
    # SigV4 今天用原子 :anonymous 表示匿名。若哪天改成 map 形状的匿名 principal，
    # 形状推断（is_map/1）会让匿名请求静默走进 501——看起来像"功能未实现"，实则鉴权
    # 判定失灵。显式判定必须在这种改动下仍然把匿名挡在 403。
    conn =
      :get
      |> SigV4Request.anon_conn("/minio/admin/v3/info")
      |> Plug.Conn.assign(:principal, %{type: :anonymous, arn: nil})
      |> Plug.Conn.assign(:auth_type, :anonymous)
      |> Plug.Conn.assign(:s3_address_style, :path)
      |> Plug.Conn.assign(:maxio_surface, :admin)
      |> Maxio.Admin.Plug.call(Maxio.Admin.Plug.init([]))

    assert conn.status == 403
    assert Jason.decode!(conn.resp_body)["Code"] == "AccessDenied"
  end

  test "the admin plug mounted before SigV4 fails loudly instead of guessing" do
    # M-3：管线顺序错误是**部署期构造错误**，绝不能被通用 500 兜底吞成一条与偶发
    # InternalError 无法区分的日志。它必须穿过本 plug 自己的 try/rescue 原样上抛
    # （客户端仍是 500——HTTP 适配器兜底，细节不外泄；服务端拿到完整 crash report）。
    assert_raise Maxio.S3.PipelineOrderError, ~r/auth_type/, fn ->
      :get
      |> SigV4Request.anon_conn("/minio/admin/v3/info")
      |> Plug.Conn.assign(:s3_address_style, :path)
      |> Plug.Conn.assign(:maxio_surface, :admin)
      |> Maxio.Admin.Plug.call(Maxio.Admin.Plug.init([]))
    end
  end

  test "similar non-admin paths are not intercepted by the admin plug" do
    conn = signed(:get, "/minio/adminxyz")

    refute conn.status == 501
    assert conn.resp_body =~ "<Code>"
  end

  defp signed(method, path, opts \\ []) do
    method
    |> SigV4Request.signed_conn(path, opts)
    |> Endpoint.call(Endpoint.init([]))
  end

  defp content_type(conn) do
    conn |> Plug.Conn.get_resp_header("content-type") |> List.first() || ""
  end
end
