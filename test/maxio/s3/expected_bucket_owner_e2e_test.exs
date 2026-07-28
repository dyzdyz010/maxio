defmodule Maxio.S3.ExpectedBucketOwnerE2ETest do
  use Maxio.DataCase, async: false

  import Plug.Conn

  alias Maxio.S3.Endpoint
  alias Maxio.Test.SigV4Request

  @data_dir Path.join(System.tmp_dir!(), "maxio_expected_owner_e2e")
  @owner "000000000000"
  @other_owner "999999999999"

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

  test "x-amz-expected-bucket-owner is enforced for object read write and delete paths" do
    SigV4Request.signed_conn(:put, "/ownobj") |> call()

    denied_put =
      SigV4Request.signed_conn(:put, "/ownobj/object.txt",
        body: "blocked",
        headers: [{"x-amz-expected-bucket-owner", @other_owner}]
      )
      |> call()

    assert denied_put.status == 403
    assert denied_put.resp_body =~ "<Code>AccessDenied</Code>"
    assert (SigV4Request.signed_conn(:get, "/ownobj/object.txt") |> call()).status == 404

    put =
      SigV4Request.signed_conn(:put, "/ownobj/object.txt",
        body: "kept",
        headers: [{"x-amz-expected-bucket-owner", @owner}]
      )
      |> call()

    assert put.status == 200

    denied_get =
      SigV4Request.signed_conn(:get, "/ownobj/object.txt",
        headers: [{"x-amz-expected-bucket-owner", @other_owner}]
      )
      |> call()

    assert denied_get.status == 403

    denied_head =
      SigV4Request.signed_conn(:head, "/ownobj/object.txt",
        headers: [{"x-amz-expected-bucket-owner", @other_owner}]
      )
      |> call()

    assert denied_head.status == 403

    denied_delete =
      SigV4Request.signed_conn(:delete, "/ownobj/object.txt",
        headers: [{"x-amz-expected-bucket-owner", @other_owner}]
      )
      |> call()

    assert denied_delete.status == 403
    assert (SigV4Request.signed_conn(:get, "/ownobj/object.txt") |> call()).resp_body == "kept"

    denied_delete_objects =
      SigV4Request.signed_conn(:post, "/ownobj",
        query: %{"delete" => ""},
        body: "<Delete><Object><Key>object.txt</Key></Object></Delete>",
        headers: [{"x-amz-expected-bucket-owner", @other_owner}]
      )
      |> call()

    assert denied_delete_objects.status == 403
    assert (SigV4Request.signed_conn(:get, "/ownobj/object.txt") |> call()).resp_body == "kept"

    delete =
      SigV4Request.signed_conn(:delete, "/ownobj/object.txt",
        headers: [{"x-amz-expected-bucket-owner", @owner}]
      )
      |> call()

    assert delete.status == 204
    assert (SigV4Request.signed_conn(:get, "/ownobj/object.txt") |> call()).status == 404
  end

  test "CopyObject enforces destination and source expected bucket owners before target commit" do
    SigV4Request.signed_conn(:put, "/owncopysrc") |> call()
    SigV4Request.signed_conn(:put, "/owncopydst") |> call()
    SigV4Request.signed_conn(:put, "/owncopysrc/source.txt", body: "copy body") |> call()

    denied_destination =
      SigV4Request.signed_conn(:put, "/owncopydst/dest.txt",
        headers: [
          {"x-amz-copy-source", "/owncopysrc/source.txt"},
          {"x-amz-expected-bucket-owner", @other_owner}
        ]
      )
      |> call()

    assert denied_destination.status == 403
    assert (SigV4Request.signed_conn(:get, "/owncopydst/dest.txt") |> call()).status == 404

    denied_source =
      SigV4Request.signed_conn(:put, "/owncopydst/dest.txt",
        headers: [
          {"x-amz-copy-source", "/owncopysrc/source.txt"},
          {"x-amz-expected-bucket-owner", @owner},
          {"x-amz-source-expected-bucket-owner", @other_owner}
        ]
      )
      |> call()

    assert denied_source.status == 403
    assert (SigV4Request.signed_conn(:get, "/owncopydst/dest.txt") |> call()).status == 404

    missing_source_bucket =
      SigV4Request.signed_conn(:put, "/owncopydst/missing-source.txt",
        headers: [
          {"x-amz-copy-source", "/owncopymissing/source.txt"},
          {"x-amz-expected-bucket-owner", @owner},
          {"x-amz-source-expected-bucket-owner", @other_owner}
        ]
      )
      |> call()

    assert missing_source_bucket.status == 404
    assert missing_source_bucket.resp_body =~ "<Code>NoSuchBucket</Code>"

    assert (SigV4Request.signed_conn(:get, "/owncopydst/missing-source.txt") |> call()).status ==
             404

    missing_source_key =
      SigV4Request.signed_conn(:put, "/owncopydst/missing-key.txt",
        headers: [
          {"x-amz-copy-source", "/owncopysrc/missing.txt"},
          {"x-amz-expected-bucket-owner", @owner},
          {"x-amz-source-expected-bucket-owner", @other_owner}
        ]
      )
      |> call()

    assert missing_source_key.status == 404
    assert missing_source_key.resp_body =~ "<Code>NoSuchKey</Code>"
    assert (SigV4Request.signed_conn(:get, "/owncopydst/missing-key.txt") |> call()).status == 404

    copied =
      SigV4Request.signed_conn(:put, "/owncopydst/dest.txt",
        headers: [
          {"x-amz-copy-source", "/owncopysrc/source.txt"},
          {"x-amz-expected-bucket-owner", @owner},
          {"x-amz-source-expected-bucket-owner", @owner}
        ]
      )
      |> call()

    assert copied.status == 200

    assert (SigV4Request.signed_conn(:get, "/owncopydst/dest.txt") |> call()).resp_body ==
             "copy body"
  end

  test "multipart destination expected owner is enforced for create upload list complete and abort" do
    SigV4Request.signed_conn(:put, "/ownmpu") |> call()

    denied_create =
      SigV4Request.signed_conn(:post, "/ownmpu/object.bin",
        query: %{"uploads" => ""},
        headers: [{"x-amz-expected-bucket-owner", @other_owner}]
      )
      |> call()

    assert denied_create.status == 403

    missing_upload_part_bucket =
      SigV4Request.signed_conn(:put, "/ownmpumissing/object.bin",
        query: %{"partNumber" => "1", "uploadId" => "missing-upload"},
        body: "part-one",
        headers: [{"x-amz-expected-bucket-owner", @other_owner}]
      )
      |> call()

    assert missing_upload_part_bucket.status == 404
    assert missing_upload_part_bucket.resp_body =~ "<Code>NoSuchBucket</Code>"

    missing_complete_bucket =
      complete_multipart_upload("ownmpumissing", "object.bin", "missing-upload", [], [
        {"x-amz-expected-bucket-owner", @other_owner}
      ])

    assert missing_complete_bucket.status == 404
    assert missing_complete_bucket.resp_body =~ "<Code>NoSuchBucket</Code>"

    missing_abort_bucket =
      SigV4Request.signed_conn(:delete, "/ownmpumissing/object.bin",
        query: %{"uploadId" => "missing-upload"},
        headers: [{"x-amz-expected-bucket-owner", @other_owner}]
      )
      |> call()

    assert missing_abort_bucket.status == 404
    assert missing_abort_bucket.resp_body =~ "<Code>NoSuchBucket</Code>"

    missing_list_parts_bucket =
      SigV4Request.signed_conn(:get, "/ownmpumissing/object.bin",
        query: %{"uploadId" => "missing-upload"},
        headers: [{"x-amz-expected-bucket-owner", @other_owner}]
      )
      |> call()

    assert missing_list_parts_bucket.status == 404
    assert missing_list_parts_bucket.resp_body =~ "<Code>NoSuchBucket</Code>"

    init =
      SigV4Request.signed_conn(:post, "/ownmpu/object.bin",
        query: %{"uploads" => ""},
        headers: [{"x-amz-expected-bucket-owner", @owner}]
      )
      |> call()

    assert init.status == 200
    upload_id = upload_id(init.resp_body)

    denied_uploads =
      SigV4Request.signed_conn(:get, "/ownmpu",
        query: %{"uploads" => ""},
        headers: [{"x-amz-expected-bucket-owner", @other_owner}]
      )
      |> call()

    assert denied_uploads.status == 403

    uploads =
      SigV4Request.signed_conn(:get, "/ownmpu",
        query: %{"uploads" => ""},
        headers: [{"x-amz-expected-bucket-owner", @owner}]
      )
      |> call()

    assert uploads.status == 200
    assert uploads.resp_body =~ upload_id

    denied_part =
      SigV4Request.signed_conn(:put, "/ownmpu/object.bin",
        query: %{"partNumber" => "1", "uploadId" => upload_id},
        body: "part-one",
        headers: [{"x-amz-expected-bucket-owner", @other_owner}]
      )
      |> call()

    assert denied_part.status == 403

    empty_parts =
      SigV4Request.signed_conn(:get, "/ownmpu/object.bin",
        query: %{"uploadId" => upload_id},
        headers: [{"x-amz-expected-bucket-owner", @owner}]
      )
      |> call()

    assert empty_parts.status == 200
    refute empty_parts.resp_body =~ "<Part>"

    part =
      SigV4Request.signed_conn(:put, "/ownmpu/object.bin",
        query: %{"partNumber" => "1", "uploadId" => upload_id},
        body: "part-one",
        headers: [{"x-amz-expected-bucket-owner", @owner}]
      )
      |> call()

    assert part.status == 200
    [etag] = get_resp_header(part, "etag")

    denied_complete =
      complete_multipart_upload("ownmpu", "object.bin", upload_id, [etag], [
        {"x-amz-expected-bucket-owner", @other_owner}
      ])

    assert denied_complete.status == 403
    assert (SigV4Request.signed_conn(:get, "/ownmpu/object.bin") |> call()).status == 404

    denied_abort =
      SigV4Request.signed_conn(:delete, "/ownmpu/object.bin",
        query: %{"uploadId" => upload_id},
        headers: [{"x-amz-expected-bucket-owner", @other_owner}]
      )
      |> call()

    assert denied_abort.status == 403

    complete =
      complete_multipart_upload("ownmpu", "object.bin", upload_id, [etag], [
        {"x-amz-expected-bucket-owner", @owner}
      ])

    assert complete.status == 200

    assert (SigV4Request.signed_conn(:get, "/ownmpu/object.bin") |> call()).resp_body ==
             "part-one"
  end

  test "UploadPartCopy enforces destination and source expected owners before storing the copied part" do
    SigV4Request.signed_conn(:put, "/ownpartcopy") |> call()
    SigV4Request.signed_conn(:put, "/ownpartcopy/source.txt", body: "copied part") |> call()

    init =
      SigV4Request.signed_conn(:post, "/ownpartcopy/object.bin", query: %{"uploads" => ""})
      |> call()

    assert init.status == 200
    upload_id = upload_id(init.resp_body)

    denied_destination =
      SigV4Request.signed_conn(:put, "/ownpartcopy/object.bin",
        query: %{"partNumber" => "1", "uploadId" => upload_id},
        headers: [
          {"x-amz-copy-source", "/ownpartcopy/source.txt"},
          {"x-amz-expected-bucket-owner", @other_owner}
        ]
      )
      |> call()

    assert denied_destination.status == 403

    denied_source =
      SigV4Request.signed_conn(:put, "/ownpartcopy/object.bin",
        query: %{"partNumber" => "1", "uploadId" => upload_id},
        headers: [
          {"x-amz-copy-source", "/ownpartcopy/source.txt"},
          {"x-amz-expected-bucket-owner", @owner},
          {"x-amz-source-expected-bucket-owner", @other_owner}
        ]
      )
      |> call()

    assert denied_source.status == 403

    missing_source_bucket =
      SigV4Request.signed_conn(:put, "/ownpartcopy/object.bin",
        query: %{"partNumber" => "1", "uploadId" => upload_id},
        headers: [
          {"x-amz-copy-source", "/ownpartcopymissing/source.txt"},
          {"x-amz-expected-bucket-owner", @owner},
          {"x-amz-source-expected-bucket-owner", @other_owner}
        ]
      )
      |> call()

    assert missing_source_bucket.status == 404
    assert missing_source_bucket.resp_body =~ "<Code>NoSuchBucket</Code>"

    missing_source_key =
      SigV4Request.signed_conn(:put, "/ownpartcopy/object.bin",
        query: %{"partNumber" => "1", "uploadId" => upload_id},
        headers: [
          {"x-amz-copy-source", "/ownpartcopy/missing.txt"},
          {"x-amz-expected-bucket-owner", @owner},
          {"x-amz-source-expected-bucket-owner", @other_owner}
        ]
      )
      |> call()

    assert missing_source_key.status == 404
    assert missing_source_key.resp_body =~ "<Code>NoSuchKey</Code>"

    empty_parts =
      SigV4Request.signed_conn(:get, "/ownpartcopy/object.bin",
        query: %{"uploadId" => upload_id},
        headers: [{"x-amz-expected-bucket-owner", @owner}]
      )
      |> call()

    assert empty_parts.status == 200
    refute empty_parts.resp_body =~ "<Part>"

    copied =
      SigV4Request.signed_conn(:put, "/ownpartcopy/object.bin",
        query: %{"partNumber" => "1", "uploadId" => upload_id},
        headers: [
          {"x-amz-copy-source", "/ownpartcopy/source.txt"},
          {"x-amz-expected-bucket-owner", @owner},
          {"x-amz-source-expected-bucket-owner", @owner}
        ]
      )
      |> call()

    assert copied.status == 200
    assert copied.resp_body =~ "<CopyPartResult"
  end

  defp complete_multipart_upload(bucket, key, upload_id, etags, headers) do
    parts =
      etags
      |> Enum.with_index(1)
      |> Enum.map(fn {etag, part_number} ->
        """
        <Part><PartNumber>#{part_number}</PartNumber><ETag>#{etag}</ETag></Part>
        """
      end)

    body = IO.iodata_to_binary(["<CompleteMultipartUpload>", parts, "</CompleteMultipartUpload>"])

    SigV4Request.signed_conn(:post, "/#{bucket}/#{key}",
      query: %{"uploadId" => upload_id},
      body: body,
      headers: headers
    )
    |> call()
  end

  defp upload_id(xml) do
    [_, id] = Regex.run(~r/<UploadId>([^<]+)<\/UploadId>/, xml)
    id
  end
end
