defmodule Maxio.S3.ReservedNamespaceAddressingTest do
  @moduledoc """
  保留路径面（health / admin / prometheus）的**寻址约束**：`/minio/...` 只有在请求确实
  指向**服务器根命名空间**（path-style，桶名不来自 Host）时才被认领。

  为什么这是数据完整性问题而不是路由口味问题：virtual-host 寻址下 `Host: <bucket>.<domain>`
  + `GET /minio/health/live` 指的是**桶 `<bucket>` 里 key 为 `minio/health/live` 的对象**。
  若保留面只看 `conn.request_path` 就认领，任意桶的这批 key 都会被劫持：探针返回
  **200 + 空 body**，备份/同步工具会把它当成一个合法的空对象——比报错更危险（铁律 3）。
  """
  use Maxio.DataCase, async: false

  alias Maxio.S3.Endpoint
  alias Maxio.Test.SigV4Request

  @bucket "revvhost"
  @vhost @bucket <> ".localhost"
  @data_dir Path.join(System.tmp_dir!(), "maxio_reserved_addressing")

  # 三个保留面各取一条真实认领路径；对象 key 即去掉前导 "/" 的同一字符串。
  @claimed_keys [
    {"minio/health/live", "PAYLOAD-HEALTH"},
    {"minio/admin/v3/info", "PAYLOAD-ADMIN"},
    {"minio/v2/metrics/cluster", "PAYLOAD-METRICS"}
  ]

  setup do
    File.rm_rf(@data_dir)
    File.mkdir_p!(@data_dir)
    prev = Application.get_env(:maxio, :s3)
    Application.put_env(:maxio, :s3, Keyword.put(prev, :data_dir, @data_dir))

    on_exit(fn ->
      Application.put_env(:maxio, :s3, prev)
      File.rm_rf(@data_dir)
    end)

    assert call(signed(:put, "/" <> @bucket)).status == 200

    for {key, payload} <- @claimed_keys do
      assert call(signed(:put, "/#{@bucket}/#{key}", body: payload)).status == 200
    end

    :ok
  end

  test "path-style reads of a normal bucket's minio/... keys return the object bytes" do
    for {key, payload} <- @claimed_keys do
      conn = call(signed(:get, "/#{@bucket}/#{key}"))

      assert conn.status == 200
      assert conn.resp_body == payload
    end
  end

  test "virtual-host reads of the same keys must not be hijacked by the reserved surfaces" do
    for {key, payload} <- @claimed_keys do
      conn = call(signed(:get, "/" <> key, host: @vhost))

      assert conn.status == 200,
             "vhost GET /#{key} on bucket #{@bucket} returned #{conn.status}: #{conn.resp_body}"

      assert conn.resp_body == payload,
             "vhost GET /#{key} on bucket #{@bucket} returned #{byte_size(conn.resp_body)} bytes " <>
               "instead of the stored object"
    end
  end

  test "virtual-host requests for absent minio/... keys get an S3 error, never a probe 200" do
    conn = call(signed(:get, "/minio/health/ready", host: @vhost))

    assert conn.status == 404
    assert conn.resp_body =~ "<Code>NoSuchKey</Code>"
  end

  test "anonymous virtual-host probe paths are not answered by the health surface either" do
    conn = call(SigV4Request.anon_conn(:get, "/minio/health/live", host: @vhost))

    # 匿名 + 非 public 桶 → S3 AccessDenied；绝不是探针的 200 空 body。
    assert conn.status == 403
    assert conn.resp_body =~ "<Code>"
  end

  test "跳过保留面时必须留下可检索的归因日志（I-2：与 MinIO 的已知偏离）" do
    # MinIO 把 health/admin/metrics 注册在顶层 mux、不看 Host；maxio 要求 path-style。
    # 运维在 vhost 域名上打探针 / mc admin / metrics 时只会看到 NoSuchBucket 或对象错误——
    # 若不打日志，这就是一次"没有诊断的失败"（铁律 3）。
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        call(signed(:get, "/minio/admin/v3/info", host: @vhost))
      end)

    assert log =~ "reserved_surface_skipped_non_path_addressing"
    assert log =~ "reserved admin surface not claimed"
    assert log =~ "virtual_host"
    assert log =~ "path-style endpoint"
  end

  test "path-style 请求绝不打这条跳过日志（避免把正常流量淹掉）" do
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert call(SigV4Request.anon_conn(:get, "/minio/health/live")).status == 200
      end)

    refute log =~ "reserved_surface_skipped_non_path_addressing"
  end

  test "path-style reserved surfaces keep working (server root namespace)" do
    live = call(SigV4Request.anon_conn(:get, "/minio/health/live"))
    assert live.status == 200
    assert live.resp_body == ""

    admin = call(signed(:get, "/minio/admin/v3/info"))
    assert admin.status == 501
    assert Jason.decode!(admin.resp_body)["Code"] == "NotImplemented"
  end

  defp signed(method, path, opts \\ []), do: SigV4Request.signed_conn(method, path, opts)
  defp call(conn), do: Endpoint.call(conn, Endpoint.init([]))
end
