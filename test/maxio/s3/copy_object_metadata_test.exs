defmodule Maxio.S3.CopyObjectMetadataTest do
  @moduledoc """
  FX-M4：CopyObject 默认（metadata-directive=COPY）保留源用户 metadata（x-amz-meta-*）与 tags；
  REPLACE 用请求头（不继承源）。tags 受 x-amz-tagging-directive 独立控制（与 AWS/MinIO 正交）。
  端到端经 Endpoint 自签管线取证（无 aws-cli 环境的活体证据）。
  """
  use Maxio.DataCase, async: false
  alias Maxio.Test.SigV4Request
  alias Maxio.S3.Endpoint

  @data_dir Path.join(System.tmp_dir!(), "maxio_copy_meta")

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

  test "COPY（默认）保留源 tags（GetObjectTagging 返回源 tag）" do
    SigV4Request.signed_conn(:put, "/cm1") |> call()

    SigV4Request.signed_conn(:put, "/cm1/src.txt",
      body: "x",
      headers: [{"x-amz-tagging", "team=core&env=prod"}]
    )
    |> call()

    SigV4Request.signed_conn(:put, "/cm1/dst.txt",
      headers: [{"x-amz-copy-source", "/cm1/src.txt"}]
    )
    |> call()

    tg = SigV4Request.signed_conn(:get, "/cm1/dst.txt", query: %{"tagging" => ""}) |> call()
    assert tg.status == 200
    assert tg.resp_body =~ "team"
    assert tg.resp_body =~ "core"
  end

  test "COPY 保留源 x-amz-meta-*（直接查目标元数据断言）" do
    SigV4Request.signed_conn(:put, "/cm2") |> call()

    SigV4Request.signed_conn(:put, "/cm2/src.txt",
      body: "x",
      headers: [{"x-amz-meta-author", "alice"}]
    )
    |> call()

    # PutObject 当前不解析 x-amz-meta-*（不在本偏差范围），故源 metadata 直接落库以隔离 CopyObject 行为。
    {:ok, src} = Maxio.Objects.get_metadata("cm2", "src.txt")

    {:ok, _} =
      Maxio.Objects.put_version_with_id("cm2", "src.txt", src.version_id, %{
        size: src.size,
        etag: src.etag,
        content_type: src.content_type,
        storage_class: "STANDARD",
        metadata: %{"author" => "alice"}
      })

    SigV4Request.signed_conn(:put, "/cm2/dst.txt",
      headers: [{"x-amz-copy-source", "/cm2/src.txt"}]
    )
    |> call()

    {:ok, dst} = Maxio.Objects.get_metadata("cm2", "dst.txt")
    assert dst.metadata == %{"author" => "alice"}
  end

  test "REPLACE（tagging-directive=REPLACE）：用请求头新 tags，不继承源 tags" do
    SigV4Request.signed_conn(:put, "/cm3") |> call()

    SigV4Request.signed_conn(:put, "/cm3/src.txt",
      body: "x",
      headers: [{"x-amz-tagging", "old=1"}]
    )
    |> call()

    SigV4Request.signed_conn(:put, "/cm3/dst.txt",
      headers: [
        {"x-amz-copy-source", "/cm3/src.txt"},
        {"x-amz-tagging-directive", "REPLACE"},
        {"x-amz-tagging", "new=2"}
      ]
    )
    |> call()

    tg = SigV4Request.signed_conn(:get, "/cm3/dst.txt", query: %{"tagging" => ""}) |> call()
    assert tg.status == 200
    assert tg.resp_body =~ "new"
    refute tg.resp_body =~ "old"
  end

  test "REPLACE（metadata-directive=REPLACE）：用请求头 x-amz-meta-*，不继承源 metadata" do
    SigV4Request.signed_conn(:put, "/cm4") |> call()

    SigV4Request.signed_conn(:put, "/cm4/src.txt", body: "x") |> call()

    {:ok, src} = Maxio.Objects.get_metadata("cm4", "src.txt")

    {:ok, _} =
      Maxio.Objects.put_version_with_id("cm4", "src.txt", src.version_id, %{
        size: src.size,
        etag: src.etag,
        content_type: src.content_type,
        storage_class: "STANDARD",
        metadata: %{"author" => "alice"}
      })

    SigV4Request.signed_conn(:put, "/cm4/dst.txt",
      headers: [
        {"x-amz-copy-source", "/cm4/src.txt"},
        {"x-amz-metadata-directive", "REPLACE"},
        {"x-amz-meta-owner", "bob"}
      ]
    )
    |> call()

    {:ok, dst} = Maxio.Objects.get_metadata("cm4", "dst.txt")
    assert dst.metadata == %{"owner" => "bob"}
    refute Map.has_key?(dst.metadata, "author")
  end

  test "REPLACE（tagging-directive=REPLACE）无 x-amz-tagging 头 → 清空 tags（不继承源）" do
    SigV4Request.signed_conn(:put, "/cm5") |> call()

    SigV4Request.signed_conn(:put, "/cm5/src.txt",
      body: "x",
      headers: [{"x-amz-tagging", "keep=me"}]
    )
    |> call()

    SigV4Request.signed_conn(:put, "/cm5/dst.txt",
      headers: [
        {"x-amz-copy-source", "/cm5/src.txt"},
        {"x-amz-tagging-directive", "REPLACE"}
      ]
    )
    |> call()

    {:ok, dst} = Maxio.Objects.get_metadata("cm5", "dst.txt")
    assert dst.tags == %{}
  end
end
