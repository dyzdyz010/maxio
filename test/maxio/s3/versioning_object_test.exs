defmodule Maxio.S3.VersioningObjectTest do
  use Maxio.DataCase, async: false

  import Plug.Conn
  alias Maxio.Test.SigV4Request
  alias Maxio.S3.Endpoint

  @data_dir Path.join(System.tmp_dir!(), "maxio_versioning_obj_test")

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

  test "未版本化桶：PUT 不回 x-amz-version-id；GET 取当前" do
    SigV4Request.signed_conn(:put, "/uvb") |> call()
    put = SigV4Request.signed_conn(:put, "/uvb/k.txt", body: "v1") |> call()
    assert put.status == 200
    assert get_resp_header(put, "x-amz-version-id") == []
    get = SigV4Request.signed_conn(:get, "/uvb/k.txt") |> call()
    assert get.resp_body == "v1"
  end

  test "Enabled：两次 PUT 产生两个版本，latest 是第二个；?versionId 取旧版本" do
    SigV4Request.signed_conn(:put, "/verb") |> call()
    assert enable_versioning("verb").status == 200

    p1 = SigV4Request.signed_conn(:put, "/verb/k.txt", body: "first") |> call()
    assert p1.status == 200
    [vid1] = get_resp_header(p1, "x-amz-version-id")
    assert vid1 != "null"

    p2 = SigV4Request.signed_conn(:put, "/verb/k.txt", body: "second") |> call()
    [vid2] = get_resp_header(p2, "x-amz-version-id")
    assert vid2 != vid1

    latest = SigV4Request.signed_conn(:get, "/verb/k.txt") |> call()
    assert latest.resp_body == "second"
    assert get_resp_header(latest, "x-amz-version-id") == [vid2]

    old = SigV4Request.signed_conn(:get, "/verb/k.txt", query: %{"versionId" => vid1}) |> call()
    assert old.resp_body == "first"
    assert get_resp_header(old, "x-amz-version-id") == [vid1]
  end

  test "Enabled：简单 DELETE 插入 delete marker；后续 GET → 404 + x-amz-delete-marker" do
    SigV4Request.signed_conn(:put, "/delb") |> call()
    enable_versioning("delb")
    SigV4Request.signed_conn(:put, "/delb/k.txt", body: "data") |> call()

    del = SigV4Request.signed_conn(:delete, "/delb/k.txt") |> call()
    assert del.status == 204
    assert [_dm_vid] = get_resp_header(del, "x-amz-version-id")
    assert get_resp_header(del, "x-amz-delete-marker") == ["true"]

    get = SigV4Request.signed_conn(:get, "/delb/k.txt") |> call()
    assert get.status == 404
    assert get_resp_header(get, "x-amz-delete-marker") == ["true"]
  end

  test "Enabled：DELETE ?versionId 永久删该版本；删 delete marker 让旧版本重现" do
    SigV4Request.signed_conn(:put, "/perv") |> call()
    enable_versioning("perv")
    p1 = SigV4Request.signed_conn(:put, "/perv/k.txt", body: "alive") |> call()
    [vid1] = get_resp_header(p1, "x-amz-version-id")

    del = SigV4Request.signed_conn(:delete, "/perv/k.txt") |> call()
    [dm_vid] = get_resp_header(del, "x-amz-version-id")

    # 删 delete marker → 旧版本重现为 latest
    deldm =
      SigV4Request.signed_conn(:delete, "/perv/k.txt", query: %{"versionId" => dm_vid}) |> call()

    assert deldm.status == 204

    get = SigV4Request.signed_conn(:get, "/perv/k.txt") |> call()
    assert get.status == 200
    assert get.resp_body == "alive"
    assert get_resp_header(get, "x-amz-version-id") == [vid1]
  end

  test "Enabled：GET ?versionId 指向 delete marker → 405" do
    SigV4Request.signed_conn(:put, "/mark") |> call()
    enable_versioning("mark")
    SigV4Request.signed_conn(:put, "/mark/k.txt", body: "x") |> call()
    del = SigV4Request.signed_conn(:delete, "/mark/k.txt") |> call()
    [dm_vid] = get_resp_header(del, "x-amz-version-id")

    get = SigV4Request.signed_conn(:get, "/mark/k.txt", query: %{"versionId" => dm_vid}) |> call()
    assert get.status == 405
    assert get_resp_header(get, "x-amz-delete-marker") == ["true"]
  end
end
