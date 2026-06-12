defmodule Maxio.S3.StorageClassTest do
  @moduledoc """
  S3 storage-class 可见语义回归：

    * PutObject / CopyObject / CreateMultipartUpload 接受 x-amz-storage-class；
    * 非 STANDARD 对象经 GET/HEAD 回显 x-amz-storage-class，ListObjectsV2 写 StorageClass；
    * CopyObject 缺省目标 storage class 为 STANDARD，显式 header 可改变 storage class；
    * 非法 storage class 在写任何对象前 400 InvalidStorageClass。
  """
  use Maxio.DataCase, async: false

  import Plug.Conn, only: [get_resp_header: 2]

  alias Maxio.{Multipart, Objects}
  alias Maxio.S3.{Endpoint, StorageClass}
  alias Maxio.Test.SigV4Request

  @data_dir Path.join(System.tmp_dir!(), "maxio_storage_class_test")

  setup do
    File.rm_rf(@data_dir)
    File.mkdir_p!(@data_dir)

    prev_s3 = Application.get_env(:maxio, :s3)
    prev_multipart_min_part_size = Application.get_env(:maxio, :multipart_min_part_size, :unset)

    Application.put_env(:maxio, :s3, Keyword.put(prev_s3, :data_dir, @data_dir))
    Application.put_env(:maxio, :multipart_min_part_size, 1)

    on_exit(fn ->
      Application.put_env(:maxio, :s3, prev_s3)

      case prev_multipart_min_part_size do
        :unset -> Application.delete_env(:maxio, :multipart_min_part_size)
        value -> Application.put_env(:maxio, :multipart_min_part_size, value)
      end

      File.rm_rf(@data_dir)
    end)

    :ok
  end

  test "storage class parser defaults, normalizes, and rejects invalid values" do
    assert StorageClass.parse!(nil) == "STANDARD"
    assert StorageClass.parse!("") == "STANDARD"
    assert StorageClass.parse!(" standard_ia ") == "STANDARD_IA"
    assert "FSX_ONTAP" in StorageClass.valid_values()

    err = assert_raise Maxio.S3.Error, fn -> StorageClass.parse!("coldline") end
    assert err.code == "InvalidStorageClass"
  end

  test "PutObject x-amz-storage-class persists and GET/HEAD/LIST expose non-STANDARD class" do
    SigV4Request.signed_conn(:put, "/scput") |> call()

    put =
      SigV4Request.signed_conn(:put, "/scput/archive.bin",
        body: "payload",
        headers: [{"x-amz-storage-class", "STANDARD_IA"}]
      )
      |> call()

    assert put.status == 200
    {:ok, obj} = Objects.get_metadata("scput", "archive.bin")
    assert obj.storage_class == "STANDARD_IA"

    get = SigV4Request.signed_conn(:get, "/scput/archive.bin") |> call()
    assert get.status == 200
    assert get_resp_header(get, "x-amz-storage-class") == ["STANDARD_IA"]

    head = SigV4Request.signed_conn(:head, "/scput/archive.bin") |> call()
    assert head.status == 200
    assert get_resp_header(head, "x-amz-storage-class") == ["STANDARD_IA"]

    list = SigV4Request.signed_conn(:get, "/scput", query: %{"list-type" => "2"}) |> call()
    assert list.status == 200
    assert list.resp_body =~ "<Key>archive.bin</Key>"
    assert list.resp_body =~ "<StorageClass>STANDARD_IA</StorageClass>"
  end

  test "STANDARD objects omit x-amz-storage-class on GET/HEAD" do
    SigV4Request.signed_conn(:put, "/scstd") |> call()
    SigV4Request.signed_conn(:put, "/scstd/std.txt", body: "payload") |> call()

    get = SigV4Request.signed_conn(:get, "/scstd/std.txt") |> call()
    assert get.status == 200
    assert get_resp_header(get, "x-amz-storage-class") == []

    head = SigV4Request.signed_conn(:head, "/scstd/std.txt") |> call()
    assert head.status == 200
    assert get_resp_header(head, "x-amz-storage-class") == []
  end

  test "invalid PutObject storage class returns 400 before object commit" do
    SigV4Request.signed_conn(:put, "/scbad") |> call()

    put =
      SigV4Request.signed_conn(:put, "/scbad/k.txt",
        body: "payload",
        headers: [{"x-amz-storage-class", "COLDLINE"}]
      )
      |> call()

    assert put.status == 400
    assert put.resp_body =~ "<Code>InvalidStorageClass</Code>"
    assert {:error, :not_found} = Objects.get_metadata("scbad", "k.txt")
  end

  test "invalid CopyObject storage class returns 400 before target commit" do
    SigV4Request.signed_conn(:put, "/sccopybad") |> call()
    SigV4Request.signed_conn(:put, "/sccopybad/src.txt", body: "payload") |> call()

    copy =
      SigV4Request.signed_conn(:put, "/sccopybad/dst.txt",
        headers: [
          {"x-amz-copy-source", "/sccopybad/src.txt"},
          {"x-amz-storage-class", "COLDLINE"}
        ]
      )
      |> call()

    assert copy.status == 400
    assert copy.resp_body =~ "<Code>InvalidStorageClass</Code>"
    assert {:error, :not_found} = Objects.get_metadata("sccopybad", "dst.txt")
  end

  test "CopyObject defaults target storage class to STANDARD and explicit header changes it" do
    SigV4Request.signed_conn(:put, "/sccopy") |> call()

    SigV4Request.signed_conn(:put, "/sccopy/src.txt",
      body: "copy payload",
      headers: [{"x-amz-storage-class", "STANDARD_IA"}]
    )
    |> call()

    default_copy =
      SigV4Request.signed_conn(:put, "/sccopy/dst-standard.txt",
        headers: [{"x-amz-copy-source", "/sccopy/src.txt"}]
      )
      |> call()

    assert default_copy.status == 200
    {:ok, standard_dst} = Objects.get_metadata("sccopy", "dst-standard.txt")
    assert standard_dst.storage_class == "STANDARD"

    head_standard = SigV4Request.signed_conn(:head, "/sccopy/dst-standard.txt") |> call()
    assert head_standard.status == 200
    assert get_resp_header(head_standard, "x-amz-storage-class") == []

    explicit_copy =
      SigV4Request.signed_conn(:put, "/sccopy/dst-onezone.txt",
        headers: [
          {"x-amz-copy-source", "/sccopy/src.txt"},
          {"x-amz-storage-class", "ONEZONE_IA"}
        ]
      )
      |> call()

    assert explicit_copy.status == 200
    {:ok, explicit_dst} = Objects.get_metadata("sccopy", "dst-onezone.txt")
    assert explicit_dst.storage_class == "ONEZONE_IA"

    head_explicit = SigV4Request.signed_conn(:head, "/sccopy/dst-onezone.txt") |> call()
    assert head_explicit.status == 200
    assert get_resp_header(head_explicit, "x-amz-storage-class") == ["ONEZONE_IA"]
  end

  test "CopyObject self-copy can change storage class" do
    SigV4Request.signed_conn(:put, "/scself") |> call()
    SigV4Request.signed_conn(:put, "/scself/k.txt", body: "payload") |> call()

    copy =
      SigV4Request.signed_conn(:put, "/scself/k.txt",
        headers: [
          {"x-amz-copy-source", "/scself/k.txt"},
          {"x-amz-storage-class", "GLACIER_IR"}
        ]
      )
      |> call()

    assert copy.status == 200
    {:ok, obj} = Objects.get_metadata("scself", "k.txt")
    assert obj.storage_class == "GLACIER_IR"

    head = SigV4Request.signed_conn(:head, "/scself/k.txt") |> call()
    assert get_resp_header(head, "x-amz-storage-class") == ["GLACIER_IR"]
  end

  test "CopyObject decrypts SSE-S3 source before changing storage class" do
    SigV4Request.signed_conn(:put, "/scsse") |> call()

    put =
      SigV4Request.signed_conn(:put, "/scsse/secret.txt",
        body: "secret payload",
        headers: [{"x-amz-server-side-encryption", "AES256"}]
      )
      |> call()

    assert put.status == 200

    copy =
      SigV4Request.signed_conn(:put, "/scsse/secret.txt",
        headers: [
          {"x-amz-copy-source", "/scsse/secret.txt"},
          {"x-amz-storage-class", "STANDARD_IA"}
        ]
      )
      |> call()

    assert copy.status == 200

    {:ok, obj} = Objects.get_metadata("scsse", "secret.txt")
    assert obj.storage_class == "STANDARD_IA"
    assert obj.sse_algorithm == nil

    get = SigV4Request.signed_conn(:get, "/scsse/secret.txt") |> call()
    assert get.status == 200
    assert get.resp_body == "secret payload"
    assert get_resp_header(get, "x-amz-server-side-encryption") == []
    assert get_resp_header(get, "x-amz-storage-class") == ["STANDARD_IA"]
  end

  test "invalid CreateMultipartUpload storage class returns 400 before session commit" do
    SigV4Request.signed_conn(:put, "/scmpubad") |> call()

    init =
      SigV4Request.signed_conn(:post, "/scmpubad/mp.bin",
        query: %{"uploads" => ""},
        headers: [{"x-amz-storage-class", "COLDLINE"}]
      )
      |> call()

    assert init.status == 400
    assert init.resp_body =~ "<Code>InvalidStorageClass</Code>"
    assert {:error, :not_found} = Multipart.get_upload("scmpubad", "mp.bin", "missing")
    assert Multipart.list_uploads("scmpubad").uploads == []
  end

  test "CreateMultipartUpload x-amz-storage-class carries through list parts, complete, and HEAD" do
    SigV4Request.signed_conn(:put, "/scmpu") |> call()

    init =
      SigV4Request.signed_conn(:post, "/scmpu/mp.bin",
        query: %{"uploads" => ""},
        headers: [{"x-amz-storage-class", "INTELLIGENT_TIERING"}]
      )
      |> call()

    assert init.status == 200
    uid = upload_id(init.resp_body)
    {:ok, upload} = Multipart.get_upload("scmpu", "mp.bin", uid)
    assert upload.storage_class == "INTELLIGENT_TIERING"

    list_uploads = SigV4Request.signed_conn(:get, "/scmpu", query: %{"uploads" => ""}) |> call()
    assert list_uploads.status == 200
    assert list_uploads.resp_body =~ "<StorageClass>INTELLIGENT_TIERING</StorageClass>"

    up =
      SigV4Request.signed_conn(:put, "/scmpu/mp.bin",
        query: %{"partNumber" => "1", "uploadId" => uid},
        body: "multipart payload"
      )
      |> call()

    assert up.status == 200
    [etag1] = get_resp_header(up, "etag")

    list_parts =
      SigV4Request.signed_conn(:get, "/scmpu/mp.bin", query: %{"uploadId" => uid}) |> call()

    assert list_parts.status == 200
    assert list_parts.resp_body =~ "<StorageClass>INTELLIGENT_TIERING</StorageClass>"

    complete_xml =
      "<CompleteMultipartUpload>" <>
        "<Part><PartNumber>1</PartNumber><ETag>#{etag1}</ETag></Part>" <>
        "</CompleteMultipartUpload>"

    complete =
      SigV4Request.signed_conn(:post, "/scmpu/mp.bin",
        query: %{"uploadId" => uid},
        body: complete_xml
      )
      |> call()

    assert complete.status == 200
    {:ok, obj} = Objects.get_metadata("scmpu", "mp.bin")
    assert obj.storage_class == "INTELLIGENT_TIERING"

    head = SigV4Request.signed_conn(:head, "/scmpu/mp.bin") |> call()
    assert head.status == 200
    assert get_resp_header(head, "x-amz-storage-class") == ["INTELLIGENT_TIERING"]
  end

  defp call(conn), do: Endpoint.call(conn, Endpoint.init([]))

  defp upload_id(xml) do
    [_, rest] = String.split(xml, "<UploadId>")
    [id, _] = String.split(rest, "</UploadId>")
    id
  end
end
