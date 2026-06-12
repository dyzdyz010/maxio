defmodule Maxio.S3.MultipartIntegrationTest do
  use Maxio.DataCase, async: false

  import Plug.Conn
  alias Maxio.Test.SigV4Request
  alias Maxio.S3.Endpoint

  @data_dir Path.join(System.tmp_dir!(), "maxio_mp_int_test")
  @all_users "http://acs.amazonaws.com/groups/global/AllUsers"

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

  defp enable_versioning(bucket) do
    body = ~s(<VersioningConfiguration><Status>Enabled</Status></VersioningConfiguration>)

    SigV4Request.signed_conn(:put, "/#{bucket}", query: %{"versioning" => ""}, body: body)
    |> call()
  end

  defp suspend_versioning(bucket) do
    body = ~s(<VersioningConfiguration><Status>Suspended</Status></VersioningConfiguration>)

    SigV4Request.signed_conn(:put, "/#{bucket}", query: %{"versioning" => ""}, body: body)
    |> call()
  end

  defp complete_single_part(bucket, key, body, headers \\ []) do
    init =
      SigV4Request.signed_conn(:post, "/#{bucket}/#{key}",
        query: %{"uploads" => ""},
        headers: headers
      )
      |> call()

    assert init.status == 200
    uid = upload_id(init.resp_body)

    upload_part =
      SigV4Request.signed_conn(:put, "/#{bucket}/#{key}",
        query: %{"partNumber" => "1", "uploadId" => uid},
        body: body
      )
      |> call()

    assert upload_part.status == 200
    [etag] = get_resp_header(upload_part, "etag")

    complete_xml =
      "<CompleteMultipartUpload>" <>
        "<Part><PartNumber>1</PartNumber><ETag>#{etag}</ETag></Part>" <>
        "</CompleteMultipartUpload>"

    complete =
      SigV4Request.signed_conn(:post, "/#{bucket}/#{key}",
        query: %{"uploadId" => uid},
        body: complete_xml
      )
      |> call()

    assert complete.status == 200
    complete
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
    assert get_resp_header(complete, "x-amz-version-id") == []

    get = SigV4Request.signed_conn(:get, "/mpbk/big.bin") |> call()
    assert get.status == 200
    assert get.resp_body == p1body <> p2body

    assert {:ok, null_row} = Maxio.Objects.get_version("mpbk", "big.bin", "null")
    assert null_row.is_latest == true
  end

  test "CompleteMultipartUpload 在 Enabled 桶中创建独立对象版本并回 x-amz-version-id" do
    bucket = "mpverb"
    key = "big.bin"

    SigV4Request.signed_conn(:put, "/#{bucket}") |> call()
    assert enable_versioning(bucket).status == 200

    first = complete_single_part(bucket, key, "first multipart body")
    assert [vid1] = get_resp_header(first, "x-amz-version-id")
    assert vid1 != "null"

    second = complete_single_part(bucket, key, "second multipart body")
    assert [vid2] = get_resp_header(second, "x-amz-version-id")
    assert vid2 != "null"
    assert vid2 != vid1

    latest = SigV4Request.signed_conn(:get, "/#{bucket}/#{key}") |> call()
    assert latest.status == 200
    assert latest.resp_body == "second multipart body"
    assert get_resp_header(latest, "x-amz-version-id") == [vid2]

    old =
      SigV4Request.signed_conn(:get, "/#{bucket}/#{key}", query: %{"versionId" => vid1})
      |> call()

    assert old.status == 200
    assert old.resp_body == "first multipart body"
    assert get_resp_header(old, "x-amz-version-id") == [vid1]

    assert {:ok, old_row} = Maxio.Objects.get_version(bucket, key, vid1)
    assert old_row.is_latest == false
    assert {:ok, latest_row} = Maxio.Objects.get_version(bucket, key, vid2)
    assert latest_row.is_latest == true
  end

  test "CompleteMultipartUpload 在 Suspended 桶中继续写 null 版本且不回 version header" do
    bucket = "mpversusp"
    key = "big.bin"

    SigV4Request.signed_conn(:put, "/#{bucket}") |> call()
    assert suspend_versioning(bucket).status == 200

    first = complete_single_part(bucket, key, "first suspended body")
    assert get_resp_header(first, "x-amz-version-id") == []

    second = complete_single_part(bucket, key, "second suspended body")
    assert get_resp_header(second, "x-amz-version-id") == []

    latest = SigV4Request.signed_conn(:get, "/#{bucket}/#{key}") |> call()
    assert latest.status == 200
    assert latest.resp_body == "second suspended body"
    assert get_resp_header(latest, "x-amz-version-id") == []

    assert {:ok, null_row} = Maxio.Objects.get_version(bucket, key, "null")
    assert null_row.is_latest == true
    assert null_row.size == byte_size("second suspended body")
  end

  test "CompleteMultipartUpload AES256 在 Enabled 桶中写加密的非 null 版本" do
    bucket = "mpversse"
    key = "sse.bin"
    plain = "versioned multipart sse body"

    SigV4Request.signed_conn(:put, "/#{bucket}") |> call()
    assert enable_versioning(bucket).status == 200

    complete =
      complete_single_part(bucket, key, plain, [{"x-amz-server-side-encryption", "AES256"}])

    assert get_resp_header(complete, "x-amz-server-side-encryption") == ["AES256"]
    assert [vid] = get_resp_header(complete, "x-amz-version-id")
    assert vid != "null"

    get =
      SigV4Request.signed_conn(:get, "/#{bucket}/#{key}", query: %{"versionId" => vid})
      |> call()

    assert get.status == 200
    assert get.resp_body == plain
    assert get_resp_header(get, "x-amz-version-id") == [vid]
    assert get_resp_header(get, "x-amz-server-side-encryption") == ["AES256"]

    assert {:ok, obj} = Maxio.Objects.get_version(bucket, key, vid)
    assert obj.sse_algorithm == "AES256"
    assert is_map(obj.sse_envelope)
    assert obj.size == byte_size(plain)

    on_disk = File.read!(Path.join([@data_dir, ".versions", bucket, key, vid, "part.0"]))
    refute on_disk =~ plain
    refute File.exists?(Path.join([@data_dir, bucket, key, "part.0"]))
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
      SigV4Request.signed_conn(:post, "/mpbk2/o", query: %{"uploadId" => uid}, body: xml)
      |> call()

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

  test "CreateMultipartUpload x-amz-grant-read persists to completed object ACL" do
    bucket = "mpacl"
    key = "granted.bin"

    SigV4Request.signed_conn(:put, "/#{bucket}") |> call()

    complete =
      complete_single_part(bucket, key, "multipart body", [
        {"x-amz-grant-read", ~s(uri="#{@all_users}")}
      ])

    assert complete.status == 200

    {:ok, obj} = Maxio.Objects.get_metadata(bucket, key)
    assert obj.acl_canned == "public-read"
    assert [%{"permission" => "READ"}] = obj.acl_grants["grants"]

    anon = SigV4Request.anon_conn(:get, "/#{bucket}/#{key}") |> call()
    assert anon.status == 200
    assert anon.resp_body == "multipart body"
  end
end
