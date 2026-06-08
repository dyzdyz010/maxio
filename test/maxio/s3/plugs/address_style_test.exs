defmodule Maxio.S3.Plugs.AddressStyleTest do
  use ExUnit.Case, async: true
  import Plug.Test

  alias Maxio.S3.Plugs.AddressStyle

  # 新版 Plug（1.19+）不允许 put_req_header("host", ...)，且不把 host 放进 req_headers。
  # host 的权威来源是 conn.host（由适配器从 authority 解析），故经完整 URL 构造 conn，
  # 让 Plug.Test 把 host 填进 conn.host —— 与生产 Bandit 适配器行为一致。
  defp run(method, path, host) do
    conn(method, "http://" <> host <> path)
    |> AddressStyle.call(AddressStyle.init([]))
  end

  test "path-style 根路径 → service 级" do
    conn = run(:get, "/", "localhost:9000")
    assert conn.assigns.s3_level == :service
    assert conn.assigns.s3_bucket == nil
    assert conn.assigns.s3_key == nil
  end

  test "path-style /<bucket> → bucket 级" do
    conn = run(:put, "/mybucket", "localhost:9000")
    assert conn.assigns.s3_level == :bucket
    assert conn.assigns.s3_bucket == "mybucket"
    assert conn.assigns.s3_key == nil
  end

  test "path-style /<bucket>/<key...> → object 级（key 保留层级）" do
    conn = run(:get, "/mybucket/a/b/c.txt", "localhost:9000")
    assert conn.assigns.s3_level == :object
    assert conn.assigns.s3_bucket == "mybucket"
    assert conn.assigns.s3_key == "a/b/c.txt"
  end

  test "virtual-host <bucket>.<domain> → bucket 从子域，key 从 path" do
    conn = run(:get, "/a/b.txt", "mybucket.localhost")
    assert conn.assigns.s3_level == :object
    assert conn.assigns.s3_bucket == "mybucket"
    assert conn.assigns.s3_key == "a/b.txt"
  end

  test "virtual-host 根路径 → bucket 级" do
    conn = run(:head, "/", "mybucket.localhost")
    assert conn.assigns.s3_level == :bucket
    assert conn.assigns.s3_bucket == "mybucket"
    assert conn.assigns.s3_key == nil
  end

  test "Host 含端口不影响 domain 匹配" do
    conn = run(:get, "/", "mybucket.localhost:9000")
    assert conn.assigns.s3_bucket == "mybucket"
  end
end
