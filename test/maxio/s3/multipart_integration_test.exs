defmodule Maxio.S3.MultipartIntegrationTest do
  use Maxio.DataCase, async: false

  import Plug.Conn
  alias Maxio.Test.SigV4Request
  alias Maxio.S3.Endpoint

  @data_dir Path.join(System.tmp_dir!(), "maxio_mp_int_test")

  setup do
    File.rm_rf(@data_dir)
    File.mkdir_p!(@data_dir)
    prev = Application.get_env(:maxio, :s3)
    Application.put_env(:maxio, :s3, Keyword.put(prev, :data_dir, @data_dir))
    Application.put_env(:maxio, :multipart_min_part_size, 1)

    on_exit(fn ->
      Application.put_env(:maxio, :s3, prev)
      Application.delete_env(:maxio, :multipart_min_part_size)
      File.rm_rf(@data_dir)
    end)

    :ok
  end

  defp call(conn), do: Endpoint.call(conn, Endpoint.init([]))

  # 从 InitiateMultipartUploadResult 抠 UploadId（简单字符串切，无需 XML 解析依赖）
  defp upload_id(xml) do
    [_, rest] = String.split(xml, "<UploadId>")
    [id, _] = String.split(rest, "</UploadId>")
    id
  end

  test "Create→UploadPart x2→Complete→GET 取回完整对象 + multipart ETag(-2)" do
    SigV4Request.signed_conn(:put, "/mpbk") |> call()

    init =
      SigV4Request.signed_conn(:post, "/mpbk/big.bin", query: %{"uploads" => ""})
      |> call()

    assert init.status == 200
    uid = upload_id(init.resp_body)

    p1body = "PART-ONE-DATA"
    p2body = "PART-TWO!"

    up1 =
      SigV4Request.signed_conn(:put, "/mpbk/big.bin",
        query: %{"partNumber" => "1", "uploadId" => uid},
        body: p1body
      )
      |> call()

    assert up1.status == 200
    [etag1] = get_resp_header(up1, "etag")

    up2 =
      SigV4Request.signed_conn(:put, "/mpbk/big.bin",
        query: %{"partNumber" => "2", "uploadId" => uid},
        body: p2body
      )
      |> call()

    assert up2.status == 200
    [etag2] = get_resp_header(up2, "etag")

    complete_xml =
      "<CompleteMultipartUpload>" <>
        "<Part><PartNumber>1</PartNumber><ETag>#{etag1}</ETag></Part>" <>
        "<Part><PartNumber>2</PartNumber><ETag>#{etag2}</ETag></Part>" <>
        "</CompleteMultipartUpload>"

    complete =
      SigV4Request.signed_conn(:post, "/mpbk/big.bin",
        query: %{"uploadId" => uid},
        body: complete_xml
      )
      |> call()

    assert complete.status == 200
    assert complete.resp_body =~ "<ETag>"
    assert complete.resp_body =~ "-2&quot;</ETag>" or complete.resp_body =~ ~s(-2"</ETag>)

    get = SigV4Request.signed_conn(:get, "/mpbk/big.bin") |> call()
    assert get.status == 200
    assert get.resp_body == p1body <> p2body
  end

  test "Complete 引用不存在的 part → 400 InvalidPart" do
    SigV4Request.signed_conn(:put, "/mpbk2") |> call()
    init = SigV4Request.signed_conn(:post, "/mpbk2/o", query: %{"uploads" => ""}) |> call()
    uid = upload_id(init.resp_body)

    SigV4Request.signed_conn(:put, "/mpbk2/o",
      query: %{"partNumber" => "1", "uploadId" => uid},
      body: "x"
    )
    |> call()

    xml =
      "<CompleteMultipartUpload><Part><PartNumber>1</PartNumber><ETag>\"deadbeef\"</ETag></Part></CompleteMultipartUpload>"

    complete =
      SigV4Request.signed_conn(:post, "/mpbk2/o", query: %{"uploadId" => uid}, body: xml) |> call()

    assert complete.status == 400
    assert complete.resp_body =~ "<Code>InvalidPart</Code>"
  end

  test "AbortMultipartUpload → 204；之后 ListParts → 404 NoSuchUpload" do
    SigV4Request.signed_conn(:put, "/mpbk3") |> call()
    init = SigV4Request.signed_conn(:post, "/mpbk3/o", query: %{"uploads" => ""}) |> call()
    uid = upload_id(init.resp_body)

    abort = SigV4Request.signed_conn(:delete, "/mpbk3/o", query: %{"uploadId" => uid}) |> call()
    assert abort.status == 204

    lp = SigV4Request.signed_conn(:get, "/mpbk3/o", query: %{"uploadId" => uid}) |> call()
    assert lp.status == 404
    assert lp.resp_body =~ "<Code>NoSuchUpload</Code>"
  end

  test "ListParts 列出已上传分块" do
    SigV4Request.signed_conn(:put, "/mpbk4") |> call()
    init = SigV4Request.signed_conn(:post, "/mpbk4/o", query: %{"uploads" => ""}) |> call()
    uid = upload_id(init.resp_body)

    SigV4Request.signed_conn(:put, "/mpbk4/o",
      query: %{"partNumber" => "1", "uploadId" => uid},
      body: "aa"
    )
    |> call()

    SigV4Request.signed_conn(:put, "/mpbk4/o",
      query: %{"partNumber" => "2", "uploadId" => uid},
      body: "bb"
    )
    |> call()

    lp = SigV4Request.signed_conn(:get, "/mpbk4/o", query: %{"uploadId" => uid}) |> call()
    assert lp.status == 200
    assert lp.resp_body =~ "<PartNumber>1</PartNumber>"
    assert lp.resp_body =~ "<PartNumber>2</PartNumber>"
  end

  test "ListMultipartUploads 列出进行中上传" do
    SigV4Request.signed_conn(:put, "/mpbk5") |> call()
    SigV4Request.signed_conn(:post, "/mpbk5/aaa", query: %{"uploads" => ""}) |> call()
    SigV4Request.signed_conn(:post, "/mpbk5/bbb", query: %{"uploads" => ""}) |> call()

    lmu = SigV4Request.signed_conn(:get, "/mpbk5", query: %{"uploads" => ""}) |> call()
    assert lmu.status == 200
    assert lmu.resp_body =~ "<Key>aaa</Key>"
    assert lmu.resp_body =~ "<Key>bbb</Key>"
  end
end
