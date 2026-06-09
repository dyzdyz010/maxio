defmodule Maxio.S3.CopyObjectVersionTest do
  @moduledoc """
  CopyObject 版本感知源读回归（FX-H1）：

    * `x-amz-copy-source` 默认标识源「当前版本」字节（版本化源落在 ULID version_id 路径，
      不再硬编码读 "null" → 否则静默产生空/错目标）。
    * `x-amz-copy-source` 的 `?versionId=` 被解析并读该特定历史版本字节。
  """
  use Maxio.DataCase, async: false

  import Plug.Conn
  alias Maxio.Test.SigV4Request
  alias Maxio.S3.Endpoint

  @data_dir Path.join(System.tmp_dir!(), "maxio_copy_object_version_test")

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

  test "复制版本化源的当前版本 → 目标字节等于源最新版本（不再是 0 字节）" do
    SigV4Request.signed_conn(:put, "/cpv1") |> call()
    assert enable_versioning("cpv1").status == 200
    SigV4Request.signed_conn(:put, "/cpv1/src.txt", body: "hello-current") |> call()

    cp =
      SigV4Request.signed_conn(:put, "/cpv1/dst.txt",
        headers: [{"x-amz-copy-source", "/cpv1/src.txt"}]
      )
      |> call()

    assert cp.status == 200
    g = SigV4Request.signed_conn(:get, "/cpv1/dst.txt") |> call()
    assert g.status == 200
    assert g.resp_body == "hello-current"
  end

  test "复制源的指定 ?versionId → 目标字节等于该旧版本" do
    SigV4Request.signed_conn(:put, "/cpv2") |> call()
    assert enable_versioning("cpv2").status == 200
    p1 = SigV4Request.signed_conn(:put, "/cpv2/src.txt", body: "old") |> call()
    [vid1] = get_resp_header(p1, "x-amz-version-id")
    assert vid1 != "null"
    SigV4Request.signed_conn(:put, "/cpv2/src.txt", body: "new") |> call()

    cp =
      SigV4Request.signed_conn(:put, "/cpv2/dst.txt",
        headers: [{"x-amz-copy-source", "/cpv2/src.txt?versionId=#{vid1}"}]
      )
      |> call()

    assert cp.status == 200
    g = SigV4Request.signed_conn(:get, "/cpv2/dst.txt") |> call()
    assert g.status == 200
    assert g.resp_body == "old"
  end

  test "复制源的不存在 ?versionId → NoSuchKey（绝不静默返回空目标）" do
    SigV4Request.signed_conn(:put, "/cpv3") |> call()
    assert enable_versioning("cpv3").status == 200
    SigV4Request.signed_conn(:put, "/cpv3/src.txt", body: "data") |> call()

    cp =
      SigV4Request.signed_conn(:put, "/cpv3/dst.txt",
        headers: [{"x-amz-copy-source", "/cpv3/src.txt?versionId=01BOGUSVERSIONIDXXXXXXXXX"}]
      )
      |> call()

    assert cp.status == 404
    assert cp.resp_body =~ "NoSuchKey"

    g = SigV4Request.signed_conn(:get, "/cpv3/dst.txt") |> call()
    assert g.status == 404
  end

  test "复制未版本化源的当前对象 → 目标字节正确（null 版本路径仍工作）" do
    SigV4Request.signed_conn(:put, "/cpv4") |> call()
    SigV4Request.signed_conn(:put, "/cpv4/src.txt", body: "plain-bytes") |> call()

    cp =
      SigV4Request.signed_conn(:put, "/cpv4/dst.txt",
        headers: [{"x-amz-copy-source", "/cpv4/src.txt"}]
      )
      |> call()

    assert cp.status == 200
    g = SigV4Request.signed_conn(:get, "/cpv4/dst.txt") |> call()
    assert g.status == 200
    assert g.resp_body == "plain-bytes"
  end
end
