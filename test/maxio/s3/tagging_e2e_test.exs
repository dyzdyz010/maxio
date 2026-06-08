defmodule Maxio.S3.TaggingE2ETest do
  use Maxio.DataCase, async: false
  import Plug.Conn
  alias Maxio.Test.SigV4Request
  alias Maxio.S3.Endpoint

  @data_dir Path.join(System.tmp_dir!(), "maxio_tagging_e2e")

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

  @tagging ~s(<Tagging xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><TagSet><Tag><Key>env</Key><Value>prod</Value></Tag><Tag><Key>team</Key><Value>core</Value></Tag></TagSet></Tagging>)

  test "PutObjectTagging 200 → GetObjectTagging 200 回放 → DeleteObjectTagging 204" do
    SigV4Request.signed_conn(:put, "/tagb") |> call()
    SigV4Request.signed_conn(:put, "/tagb/k.txt", body: "x") |> call()

    put = SigV4Request.signed_conn(:put, "/tagb/k.txt", query: %{"tagging" => ""}, body: @tagging) |> call()
    assert put.status == 200

    get = SigV4Request.signed_conn(:get, "/tagb/k.txt", query: %{"tagging" => ""}) |> call()
    assert get.status == 200
    assert get.resp_body =~ "<Key>env</Key>"
    assert get.resp_body =~ "<Value>prod</Value>"

    # GET object 带 x-amz-tagging-count: 2
    obj = SigV4Request.signed_conn(:get, "/tagb/k.txt") |> call()
    assert get_resp_header(obj, "x-amz-tagging-count") == ["2"]

    del = SigV4Request.signed_conn(:delete, "/tagb/k.txt", query: %{"tagging" => ""}) |> call()
    assert del.status == 204

    get2 = SigV4Request.signed_conn(:get, "/tagb/k.txt", query: %{"tagging" => ""}) |> call()
    refute get2.resp_body =~ "<Key>"
  end

  test "PutObject 带 x-amz-tagging 头 → GET 回 x-amz-tagging-count" do
    SigV4Request.signed_conn(:put, "/tagb2") |> call()
    SigV4Request.signed_conn(:put, "/tagb2/k.txt", body: "x", headers: [{"x-amz-tagging", "a=1&b=2"}]) |> call()
    obj = SigV4Request.signed_conn(:get, "/tagb2/k.txt") |> call()
    assert get_resp_header(obj, "x-amz-tagging-count") == ["2"]
  end

  test "PutBucketTagging 204 → GetBucketTagging 200" do
    SigV4Request.signed_conn(:put, "/tagb3") |> call()
    put = SigV4Request.signed_conn(:put, "/tagb3", query: %{"tagging" => ""}, body: @tagging) |> call()
    assert put.status == 204
    get = SigV4Request.signed_conn(:get, "/tagb3", query: %{"tagging" => ""}) |> call()
    assert get.resp_body =~ "<Key>env</Key>"
  end

  test "超 10 tag → InvalidTag 400" do
    SigV4Request.signed_conn(:put, "/tagb4") |> call()
    SigV4Request.signed_conn(:put, "/tagb4/k.txt", body: "x") |> call()
    tags = for i <- 1..11, do: "<Tag><Key>k#{i}</Key><Value>v</Value></Tag>"
    body = "<Tagging><TagSet>#{Enum.join(tags)}</TagSet></Tagging>"
    bad = SigV4Request.signed_conn(:put, "/tagb4/k.txt", query: %{"tagging" => ""}, body: body) |> call()
    assert bad.status == 400
    assert bad.resp_body =~ "InvalidTag"
  end
end
