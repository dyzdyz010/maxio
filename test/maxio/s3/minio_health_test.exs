defmodule Maxio.S3.MinioHealthTest do
  @moduledoc """
  `/minio/health/live` 与 `/minio/health/ready` 探针面。

  关键不变量：探针**匿名放行**且**早于 SigV4**——健康探针绝不能因鉴权子系统故障
  （过期凭据 / 畸形 Authorization 头）而误报服务已死（设计 D7）。
  """
  use Maxio.DataCase, async: false

  import Plug.Conn
  import Plug.Test

  alias Maxio.S3.Endpoint

  test "liveness probe answers 200 with an empty body without credentials" do
    conn = call(:get, "/minio/health/live")

    assert conn.status == 200
    assert conn.resp_body == ""
  end

  test "readiness probe answers 200 with an empty body without credentials" do
    conn = call(:get, "/minio/health/ready")

    assert conn.status == 200
    assert conn.resp_body == ""
  end

  test "health probes support HEAD" do
    for path <- ["/minio/health/live", "/minio/health/ready"] do
      conn = call(:head, path)

      assert conn.status == 200
      assert conn.resp_body == ""
    end
  end

  test "health probes never depend on the auth subsystem" do
    # 畸形 Authorization 头在 SigV4 里是硬失败（halt 403 XML）。探针挂在 SigV4 之前，
    # 因此即使凭据坏掉也必须照常 200——否则 k8s 会因鉴权问题重启一个健康的节点。
    conn =
      :get
      |> conn("/minio/health/live")
      |> Map.put(:host, "localhost")
      |> put_req_header("authorization", "AWS4-HMAC-SHA256 totally-broken")
      |> Endpoint.call(Endpoint.init([]))

    assert conn.status == 200
    assert conn.resp_body == ""
  end

  test "unsupported methods on health probes are rejected with 405" do
    conn = call(:post, "/minio/health/live")

    assert conn.status == 405
    assert get_resp_header(conn, "allow") == ["GET, HEAD"]
  end

  test "similar non-health paths are not intercepted by the health plug" do
    conn = call(:get, "/minio/health/livecheck")

    refute conn.status == 200
    assert conn.resp_body =~ "<Code>"
  end

  defp call(method, path) do
    method
    |> conn(path)
    |> Map.put(:host, "localhost")
    |> Endpoint.call(Endpoint.init([]))
  end
end
