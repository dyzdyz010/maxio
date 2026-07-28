defmodule Maxio.S3.SystemHeadersTest do
  @moduledoc """
  S3 对象可控系统头（Content-Disposition / Content-Encoding / Cache-Control / Expires）
  的写入与回显取证。
  """
  use Maxio.DataCase, async: false

  import Plug.Conn, only: [get_resp_header: 2]

  alias Maxio.Objects
  alias Maxio.S3.Endpoint
  alias Maxio.Test.SigV4Request

  @data_dir Path.join(System.tmp_dir!(), "maxio_system_headers_test")
  @expires "Wed, 21 Oct 2037 07:28:00 GMT"
  @redirect "/redirect-target.html"

  setup do
    File.rm_rf(@data_dir)
    File.mkdir_p!(@data_dir)

    prev_s3 = Application.get_env(:maxio, :s3)
    prev_backend = Application.get_env(:maxio, :storage_backend, :unset)
    prev_authority = Application.get_env(:maxio, :authoritative_source, :unset)
    prev_multipart_min_part_size = Application.get_env(:maxio, :multipart_min_part_size, :unset)

    Application.put_env(:maxio, :s3, Keyword.put(prev_s3, :data_dir, @data_dir))
    Application.put_env(:maxio, :storage_backend, Maxio.Storage.FS)
    Application.put_env(:maxio, :multipart_min_part_size, 1)

    on_exit(fn ->
      Application.put_env(:maxio, :s3, prev_s3)
      restore_env(:storage_backend, prev_backend)
      restore_env(:authoritative_source, prev_authority)
      restore_env(:multipart_min_part_size, prev_multipart_min_part_size)
      File.rm_rf(@data_dir)
    end)

    :ok
  end

  test "PutObject persists controlled system headers and HEAD/GET echoes them" do
    SigV4Request.signed_conn(:put, "/sh-put") |> call()

    put =
      SigV4Request.signed_conn(:put, "/sh-put/k.txt",
        body: "payload",
        headers: system_headers()
      )
      |> call()

    assert put.status == 200

    {:ok, obj} = Objects.get_metadata("sh-put", "k.txt")
    assert obj.content_encoding == "gzip"
    assert obj.content_disposition == ~s(attachment; filename="report.txt")
    assert obj.cache_control == "max-age=60"
    assert obj.expires == @expires
    assert obj.website_redirect_location == @redirect
    assert obj.metadata == %{}

    head = SigV4Request.signed_conn(:head, "/sh-put/k.txt") |> call()
    assert head.status == 200
    assert_system_headers(head)

    get = SigV4Request.signed_conn(:get, "/sh-put/k.txt") |> call()
    assert get.status == 200
    assert_system_headers(get)
  end

  test "CopyObject COPY inherits controlled system headers from source" do
    SigV4Request.signed_conn(:put, "/sh-copy") |> call()

    SigV4Request.signed_conn(:put, "/sh-copy/src.txt",
      body: "source",
      headers: system_headers() ++ [{"x-amz-meta-owner", "alice"}]
    )
    |> call()

    copy =
      SigV4Request.signed_conn(:put, "/sh-copy/dst.txt",
        headers: [{"x-amz-copy-source", "/sh-copy/src.txt"}]
      )
      |> call()

    assert copy.status == 200

    head = SigV4Request.signed_conn(:head, "/sh-copy/dst.txt") |> call()
    assert head.status == 200
    assert_system_headers(head)
    assert get_resp_header(head, "x-amz-meta-owner") == ["alice"]
  end

  test "CopyObject REPLACE applies request system headers and clears omitted source headers" do
    SigV4Request.signed_conn(:put, "/sh-replace") |> call()

    SigV4Request.signed_conn(:put, "/sh-replace/src.txt",
      body: "source",
      headers: system_headers() ++ [{"x-amz-meta-owner", "alice"}]
    )
    |> call()

    copy =
      SigV4Request.signed_conn(:put, "/sh-replace/dst.txt",
        headers: [
          {"x-amz-copy-source", "/sh-replace/src.txt"},
          {"x-amz-metadata-directive", "REPLACE"},
          {"content-type", "application/json"},
          {"cache-control", "no-store"},
          {"x-amz-meta-owner", "bob"}
        ]
      )
      |> call()

    assert copy.status == 200

    head = SigV4Request.signed_conn(:head, "/sh-replace/dst.txt") |> call()
    assert head.status == 200
    assert get_resp_header(head, "content-type") == ["application/json"]
    assert get_resp_header(head, "cache-control") == ["no-store"]
    assert get_resp_header(head, "x-amz-meta-owner") == ["bob"]
    assert get_resp_header(head, "content-encoding") == []
    assert get_resp_header(head, "content-disposition") == []
    assert get_resp_header(head, "expires") == []
    assert get_resp_header(head, "x-amz-website-redirect-location") == []
  end

  test "CopyObject metadata-directive COPY does not copy website redirect unless requested" do
    SigV4Request.signed_conn(:put, "/sh-redirect-copy") |> call()

    SigV4Request.signed_conn(:put, "/sh-redirect-copy/src.txt",
      body: "source",
      headers: system_headers()
    )
    |> call()

    copy_without_redirect =
      SigV4Request.signed_conn(:put, "/sh-redirect-copy/no-redirect.txt",
        headers: [
          {"x-amz-copy-source", "/sh-redirect-copy/src.txt"},
          {"x-amz-metadata-directive", "COPY"}
        ]
      )
      |> call()

    assert copy_without_redirect.status == 200

    head_without_redirect =
      SigV4Request.signed_conn(:head, "/sh-redirect-copy/no-redirect.txt") |> call()

    assert head_without_redirect.status == 200
    assert get_resp_header(head_without_redirect, "cache-control") == ["max-age=60"]
    assert get_resp_header(head_without_redirect, "x-amz-website-redirect-location") == []

    explicit_redirect = "/explicit-target.html"

    copy_with_redirect =
      SigV4Request.signed_conn(:put, "/sh-redirect-copy/with-redirect.txt",
        headers: [
          {"x-amz-copy-source", "/sh-redirect-copy/src.txt"},
          {"x-amz-metadata-directive", "COPY"},
          {"x-amz-website-redirect-location", explicit_redirect}
        ]
      )
      |> call()

    assert copy_with_redirect.status == 200

    head_with_redirect =
      SigV4Request.signed_conn(:head, "/sh-redirect-copy/with-redirect.txt") |> call()

    assert head_with_redirect.status == 200
    assert get_resp_header(head_with_redirect, "cache-control") == ["max-age=60"]

    assert get_resp_header(head_with_redirect, "x-amz-website-redirect-location") == [
             explicit_redirect
           ]
  end

  test "CopyObject same-key guard treats website redirect changes as object changes" do
    SigV4Request.signed_conn(:put, "/sh-self-redirect") |> call()

    SigV4Request.signed_conn(:put, "/sh-self-redirect/k.txt",
      body: "source",
      headers: system_headers()
    )
    |> call()

    no_change =
      SigV4Request.signed_conn(:put, "/sh-self-redirect/k.txt",
        headers: [{"x-amz-copy-source", "/sh-self-redirect/k.txt"}]
      )
      |> call()

    assert no_change.status == 400
    assert no_change.resp_body =~ "<Code>InvalidRequest</Code>"

    changed_redirect = "/changed-target.html"

    changed =
      SigV4Request.signed_conn(:put, "/sh-self-redirect/k.txt",
        headers: [
          {"x-amz-copy-source", "/sh-self-redirect/k.txt"},
          {"x-amz-website-redirect-location", changed_redirect}
        ]
      )
      |> call()

    assert changed.status == 200

    head = SigV4Request.signed_conn(:head, "/sh-self-redirect/k.txt") |> call()
    assert head.status == 200
    assert get_resp_header(head, "x-amz-website-redirect-location") == [changed_redirect]
  end

  test "CopyObject rejects invalid metadata and tagging directives before target commit" do
    SigV4Request.signed_conn(:put, "/sh-bad-directive") |> call()
    SigV4Request.signed_conn(:put, "/sh-bad-directive/src.txt", body: "source") |> call()

    bad_meta =
      SigV4Request.signed_conn(:put, "/sh-bad-directive/meta.txt",
        headers: [
          {"x-amz-copy-source", "/sh-bad-directive/src.txt"},
          {"x-amz-metadata-directive", "MERGE"}
        ]
      )
      |> call()

    assert bad_meta.status == 400
    assert bad_meta.resp_body =~ "InvalidArgument"
    assert {:error, :not_found} = Objects.get_metadata("sh-bad-directive", "meta.txt")

    bad_tags =
      SigV4Request.signed_conn(:put, "/sh-bad-directive/tags.txt",
        headers: [
          {"x-amz-copy-source", "/sh-bad-directive/src.txt"},
          {"x-amz-tagging-directive", "MERGE"}
        ]
      )
      |> call()

    assert bad_tags.status == 400
    assert bad_tags.resp_body =~ "InvalidArgument"
    assert {:error, :not_found} = Objects.get_metadata("sh-bad-directive", "tags.txt")
  end

  test "CopyObject COPY reads source metadata from FS sidecar authority when PG row is missing" do
    SigV4Request.signed_conn(:put, "/sh-copy-sidecar") |> call()

    SigV4Request.signed_conn(:put, "/sh-copy-sidecar/src.txt",
      body: "source",
      headers: system_headers()
    )
    |> call()

    :ok = Objects.delete_metadata("sh-copy-sidecar", "src.txt")
    Application.put_env(:maxio, :authoritative_source, read: :sidecar, list: :sidecar)

    copy =
      SigV4Request.signed_conn(:put, "/sh-copy-sidecar/dst.txt",
        headers: [{"x-amz-copy-source", "/sh-copy-sidecar/src.txt"}]
      )
      |> call()

    assert copy.status == 200

    head = SigV4Request.signed_conn(:head, "/sh-copy-sidecar/dst.txt") |> call()
    assert head.status == 200
    assert_system_headers(head)
  end

  test "Multipart Create captures controlled system headers through Complete" do
    SigV4Request.signed_conn(:put, "/sh-mpu") |> call()

    init =
      SigV4Request.signed_conn(:post, "/sh-mpu/mp.bin",
        query: %{"uploads" => ""},
        headers: system_headers()
      )
      |> call()

    assert init.status == 200
    uid = upload_id(init.resp_body)

    up =
      SigV4Request.signed_conn(:put, "/sh-mpu/mp.bin",
        query: %{"partNumber" => "1", "uploadId" => uid},
        body: "multipart payload"
      )
      |> call()

    assert up.status == 200
    [etag1] = get_resp_header(up, "etag")

    complete_xml =
      "<CompleteMultipartUpload>" <>
        "<Part><PartNumber>1</PartNumber><ETag>#{etag1}</ETag></Part>" <>
        "</CompleteMultipartUpload>"

    complete =
      SigV4Request.signed_conn(:post, "/sh-mpu/mp.bin",
        query: %{"uploadId" => uid},
        body: complete_xml
      )
      |> call()

    assert complete.status == 200

    head = SigV4Request.signed_conn(:head, "/sh-mpu/mp.bin") |> call()
    assert head.status == 200
    assert_system_headers(head)

    :ok = Objects.delete_metadata("sh-mpu", "mp.bin")
    Application.put_env(:maxio, :authoritative_source, read: :sidecar, list: :sidecar)

    sidecar_head = SigV4Request.signed_conn(:head, "/sh-mpu/mp.bin") |> call()
    assert sidecar_head.status == 200
    assert_system_headers(sidecar_head)
  end

  test "aws-chunked PutObject does not persist transfer Content-Encoding as object metadata" do
    SigV4Request.signed_conn(:put, "/sh-stream") |> call()

    put =
      SigV4Request.signed_chunked_conn(:put, "/sh-stream/k.txt", "streamed payload")
      |> call()

    assert put.status == 200

    {:ok, obj} = Objects.get_metadata("sh-stream", "k.txt")
    assert obj.content_encoding == nil

    head = SigV4Request.signed_conn(:head, "/sh-stream/k.txt") |> call()
    assert head.status == 200
    assert get_resp_header(head, "content-encoding") == []
  end

  test "read=:sidecar on FS authority preserves controlled system headers" do
    SigV4Request.signed_conn(:put, "/sh-sidecar") |> call()

    SigV4Request.signed_conn(:put, "/sh-sidecar/k.txt",
      body: "payload",
      headers: system_headers()
    )
    |> call()

    :ok = Objects.delete_metadata("sh-sidecar", "k.txt")
    Application.put_env(:maxio, :authoritative_source, read: :sidecar, list: :sidecar)

    head = SigV4Request.signed_conn(:head, "/sh-sidecar/k.txt") |> call()
    assert head.status == 200
    assert_system_headers(head)
  end

  defp system_headers do
    [
      {"content-type", "text/plain"},
      {"content-encoding", "gzip"},
      {"content-disposition", ~s(attachment; filename="report.txt")},
      {"cache-control", "max-age=60"},
      {"expires", @expires},
      {"x-amz-website-redirect-location", @redirect}
    ]
  end

  defp assert_system_headers(conn) do
    assert get_resp_header(conn, "content-encoding") == ["gzip"]
    assert get_resp_header(conn, "content-disposition") == [~s(attachment; filename="report.txt")]
    assert get_resp_header(conn, "cache-control") == ["max-age=60"]
    assert get_resp_header(conn, "expires") == [@expires]
    assert get_resp_header(conn, "x-amz-website-redirect-location") == [@redirect]
  end

  defp call(conn), do: Endpoint.call(conn, Endpoint.init([]))

  defp upload_id(xml) do
    [_, rest] = String.split(xml, "<UploadId>")
    [id, _] = String.split(rest, "</UploadId>")
    id
  end

  defp restore_env(key, :unset), do: Application.delete_env(:maxio, key)
  defp restore_env(key, value), do: Application.put_env(:maxio, key, value)
end
