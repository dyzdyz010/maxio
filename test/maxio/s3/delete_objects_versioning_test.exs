defmodule Maxio.S3.DeleteObjectsVersioningTest do
  use Maxio.DataCase, async: false

  import Plug.Conn
  alias Maxio.Test.SigV4Request
  alias Maxio.S3.Endpoint

  @data_dir Path.join(System.tmp_dir!(), "maxio_delobjs_ver_test")

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

  defp enable_versioning(bucket) do
    body = ~s(<VersioningConfiguration><Status>Enabled</Status></VersioningConfiguration>)

    SigV4Request.signed_conn(:put, "/#{bucket}", query: %{"versioning" => ""}, body: body)
    |> call()
  end

  defp delete_objects(bucket, body) do
    SigV4Request.signed_conn(:post, "/#{bucket}", query: %{"delete" => ""}, body: body) |> call()
  end

  test "Enabled 桶 + 无 VersionId 的批删 → 插 delete marker，历史版本不丢" do
    SigV4Request.signed_conn(:put, "/dob1") |> call()
    enable_versioning("dob1")
    p1 = SigV4Request.signed_conn(:put, "/dob1/k.txt", body: "v1") |> call()
    [vid1] = get_resp_header(p1, "x-amz-version-id")

    body = ~s(<Delete><Object><Key>k.txt</Key></Object></Delete>)
    res = delete_objects("dob1", body)
    assert res.status == 200
    assert res.resp_body =~ "<DeleteMarker>true</DeleteMarker>"
    assert res.resp_body =~ "<DeleteMarkerVersionId>"

    # 简单 GET → 404 + delete marker（current 是 marker）
    g = SigV4Request.signed_conn(:get, "/dob1/k.txt") |> call()
    assert g.status == 404
    assert get_resp_header(g, "x-amz-delete-marker") == ["true"]

    # 旧版本字节仍可经 ?versionId 取回（未被硬删——这正是 critical 修复点）
    old = SigV4Request.signed_conn(:get, "/dob1/k.txt", query: %{"versionId" => vid1}) |> call()
    assert old.status == 200
    assert old.resp_body == "v1"
  end

  test "Enabled 桶 + 指定 VersionId 的批删 → 只永久删该版本，其余版本存活" do
    SigV4Request.signed_conn(:put, "/dob2") |> call()
    enable_versioning("dob2")
    p1 = SigV4Request.signed_conn(:put, "/dob2/k.txt", body: "first") |> call()
    [vid1] = get_resp_header(p1, "x-amz-version-id")
    p2 = SigV4Request.signed_conn(:put, "/dob2/k.txt", body: "second") |> call()
    [vid2] = get_resp_header(p2, "x-amz-version-id")

    body = ~s(<Delete><Object><Key>k.txt</Key><VersionId>#{vid1}</VersionId></Object></Delete>)
    res = delete_objects("dob2", body)
    assert res.status == 200
    assert res.resp_body =~ "<VersionId>#{vid1}</VersionId>"

    # vid1 已删
    g1 = SigV4Request.signed_conn(:get, "/dob2/k.txt", query: %{"versionId" => vid1}) |> call()
    assert g1.status == 404
    # vid2 存活
    g2 = SigV4Request.signed_conn(:get, "/dob2/k.txt", query: %{"versionId" => vid2}) |> call()
    assert g2.status == 200
    assert g2.resp_body == "second"
  end

  test "未版本化桶批删 → 硬删（现有语义保留），quiet=false 回 <Deleted><Key>" do
    SigV4Request.signed_conn(:put, "/dob3") |> call()
    SigV4Request.signed_conn(:put, "/dob3/k.txt", body: "x") |> call()

    body = ~s(<Delete><Quiet>false</Quiet><Object><Key>k.txt</Key></Object></Delete>)
    res = delete_objects("dob3", body)
    assert res.status == 200
    assert res.resp_body =~ "<Deleted><Key>k.txt</Key></Deleted>"
    refute res.resp_body =~ "<DeleteMarker>"

    g = SigV4Request.signed_conn(:get, "/dob3/k.txt") |> call()
    assert g.status == 404
  end

  test "malformed DeleteObjects XML deletes nothing" do
    SigV4Request.signed_conn(:put, "/dobstrict") |> call()
    SigV4Request.signed_conn(:put, "/dobstrict/a.txt", body: "a") |> call()
    SigV4Request.signed_conn(:put, "/dobstrict/b.txt", body: "b") |> call()

    body =
      ~s(<Delete><Object><Key>a.txt</Key></Object><Object><Key>b.txt</Key><Unknown>true</Unknown></Object></Delete>)

    res = delete_objects("dobstrict", body)

    assert res.status == 400
    assert res.resp_body =~ "<Code>MalformedXML</Code>"

    assert (SigV4Request.signed_conn(:get, "/dobstrict/a.txt") |> call()).resp_body == "a"
    assert (SigV4Request.signed_conn(:get, "/dobstrict/b.txt") |> call()).resp_body == "b"
  end

  test "conditional DeleteObjects fields fail closed without deleting object" do
    SigV4Request.signed_conn(:put, "/dobconditional") |> call()
    SigV4Request.signed_conn(:put, "/dobconditional/k.txt", body: "x") |> call()

    unsupported_fields = [
      {"ETag", ~s("does-not-match")},
      {"LastModifiedTime", "2024-01-01T00:00:00Z"},
      {"Size", "1"}
    ]

    for {field, value} <- unsupported_fields do
      body = "<Delete><Object><Key>k.txt</Key><#{field}>#{value}</#{field}></Object></Delete>"
      res = delete_objects("dobconditional", body)

      assert res.status == 501
      assert res.resp_body =~ "<Code>NotImplemented</Code>"

      get = SigV4Request.signed_conn(:get, "/dobconditional/k.txt") |> call()
      assert get.status == 200
      assert get.resp_body == "x"
    end

    get = SigV4Request.signed_conn(:get, "/dobconditional/k.txt") |> call()
    assert get.status == 200
    assert get.resp_body == "x"
  end
end
