defmodule Maxio.S3.SDKHighFreqMatrixTest do
  @moduledoc """
  Compact compatibility matrix for SDK/CLI high-frequency S3 operations.
  """

  use Maxio.DataCase, async: false

  import Plug.Conn

  alias Maxio.S3.Endpoint
  alias Maxio.Test.SigV4Request

  @data_dir Path.join(System.tmp_dir!(), "maxio_sdk_highfreq_matrix")

  setup do
    File.rm_rf(@data_dir)
    File.mkdir_p!(@data_dir)

    prev = Application.get_env(:maxio, :s3, [])
    Application.put_env(:maxio, :s3, Keyword.put(prev, :data_dir, @data_dir))

    on_exit(fn ->
      Application.put_env(:maxio, :s3, prev)
      File.rm_rf(@data_dir)
    end)

    :ok
  end

  defp call(conn), do: Endpoint.call(conn, Endpoint.init([]))

  test "service and bucket metadata SDK matrix covers ListBuckets, HeadBucket, and location" do
    create_bucket("sdkmeta1")
    create_bucket("sdkmeta2")

    listed = list_buckets()
    assert listed.status == 200
    assert listed.resp_body =~ "<ListAllMyBucketsResult"
    assert listed.resp_body =~ "<Owner>"
    assert listed.resp_body =~ "<ID>#{SigV4Request.access_key()}</ID>"
    assert listed.resp_body =~ "<DisplayName>maxio</DisplayName>"
    assert listed.resp_body =~ "<Name>sdkmeta1</Name>"
    assert listed.resp_body =~ "<Name>sdkmeta2</Name>"
    assert listed.resp_body =~ "<CreationDate>"

    head = head_bucket("sdkmeta1")
    assert head.status == 200
    assert head.resp_body == ""
    assert get_resp_header(head, "x-amz-bucket-region") == ["us-east-1"]

    missing = head_bucket("sdkmissing")
    assert missing.status == 404
    assert missing.resp_body == ""

    location = get_bucket_location("sdkmeta1")
    assert location.status == 200
    assert location.resp_body =~ "<LocationConstraint"
    refute location.resp_body =~ "us-east-1"
  end

  test "DeleteObject SDK matrix is idempotent and creates versioned delete markers" do
    create_bucket("sdkdel1")
    put_object("sdkdel1", "plain.txt", "delete me")

    deleted = delete_object("sdkdel1", "plain.txt")
    assert deleted.status == 204
    assert deleted.resp_body == ""
    assert get_object("sdkdel1", "plain.txt").status == 404

    missing = delete_object("sdkdel1", "missing.txt")
    assert missing.status == 204
    assert missing.resp_body == ""

    create_bucket("sdkdel2")
    enable_versioning("sdkdel2")
    put = put_object("sdkdel2", "versioned.txt", "v1")
    [version_id] = get_resp_header(put, "x-amz-version-id")

    marker = delete_object("sdkdel2", "versioned.txt")
    assert marker.status == 204
    assert marker.resp_body == ""
    assert get_resp_header(marker, "x-amz-delete-marker") == ["true"]
    assert [_delete_marker_version] = get_resp_header(marker, "x-amz-version-id")

    current = get_object("sdkdel2", "versioned.txt")
    assert current.status == 404
    assert get_resp_header(current, "x-amz-delete-marker") == ["true"]

    old = get_object("sdkdel2", "versioned.txt", %{"versionId" => version_id})
    assert old.status == 200
    assert old.resp_body == "v1"
  end

  test "DeleteObjects SDK matrix returns per-key Deleted entries and honors Quiet" do
    create_bucket("sdkdelm")
    put_object("sdkdelm", "a.txt", "a")
    put_object("sdkdelm", "b.txt", "b")

    verbose_body =
      """
      <Delete>
        <Object><Key>a.txt</Key></Object>
        <Object><Key>missing.txt</Key></Object>
      </Delete>
      """

    verbose = delete_objects("sdkdelm", verbose_body)
    assert verbose.status == 200
    assert verbose.resp_body =~ "<DeleteResult"
    assert verbose.resp_body =~ "<Deleted><Key>a.txt</Key></Deleted>"
    assert verbose.resp_body =~ "<Deleted><Key>missing.txt</Key></Deleted>"
    refute verbose.resp_body =~ "<Error>"

    assert get_object("sdkdelm", "a.txt").status == 404
    assert get_object("sdkdelm", "b.txt").status == 200

    quiet_body =
      """
      <Delete>
        <Quiet>true</Quiet>
        <Object><Key>b.txt</Key></Object>
      </Delete>
      """

    quiet = delete_objects("sdkdelm", quiet_body)
    assert quiet.status == 200
    assert quiet.resp_body =~ "<DeleteResult"
    refute quiet.resp_body =~ "<Deleted>"
    refute quiet.resp_body =~ "<Error>"
    assert get_object("sdkdelm", "b.txt").status == 404
  end

  test "CopyObject SDK matrix returns CopyObjectResult and persists destination bytes" do
    create_bucket("sdkcopy")
    put = put_object("sdkcopy", "source.txt", "copy me", [{"content-type", "text/plain"}])
    [etag] = get_resp_header(put, "etag")

    copied = copy_object("sdkcopy", "dest.txt", "/sdkcopy/source.txt")
    assert copied.status == 200
    assert copied.resp_body =~ "<CopyObjectResult"
    assert copied.resp_body =~ "<ETag>#{etag}</ETag>"
    assert copied.resp_body =~ "<LastModified>"

    dest = get_object("sdkcopy", "dest.txt")
    assert dest.status == 200
    assert dest.resp_body == "copy me"
    assert get_resp_header(dest, "etag") == [etag]

    missing_source = copy_object("sdkcopy", "missing-dest.txt", "/sdkcopy/missing.txt")
    assert_s3_error(missing_source, 404, "NoSuchKey")
    assert get_object("sdkcopy", "missing-dest.txt").status == 404
  end

  test "CopyObject source condition SDK matrix returns 200 or 412 without partial targets" do
    create_bucket("sdkccond")
    put = put_object("sdkccond", "source.txt", "source")
    [etag] = get_resp_header(put, "etag")

    matched =
      copy_object("sdkccond", "matched.txt", "/sdkccond/source.txt", [
        {"x-amz-copy-source-if-match", etag}
      ])

    assert matched.status == 200
    assert get_object("sdkccond", "matched.txt").resp_body == "source"

    wrong_match =
      copy_object("sdkccond", "wrong-match.txt", "/sdkccond/source.txt", [
        {"x-amz-copy-source-if-match", "\"wrong\""}
      ])

    assert_s3_error(wrong_match, 412, "PreconditionFailed")
    assert get_object("sdkccond", "wrong-match.txt").status == 404

    none_match_hit =
      copy_object("sdkccond", "none-match-hit.txt", "/sdkccond/source.txt", [
        {"x-amz-copy-source-if-none-match", etag}
      ])

    assert_s3_error(none_match_hit, 412, "PreconditionFailed")
    assert get_object("sdkccond", "none-match-hit.txt").status == 404
  end

  defp create_bucket(bucket) do
    conn = SigV4Request.signed_conn(:put, "/#{bucket}") |> call()
    assert conn.status == 200
    conn
  end

  defp enable_versioning(bucket) do
    body = "<VersioningConfiguration><Status>Enabled</Status></VersioningConfiguration>"

    conn =
      SigV4Request.signed_conn(:put, "/#{bucket}", query: %{"versioning" => ""}, body: body)
      |> call()

    assert conn.status == 200
    conn
  end

  defp put_object(bucket, key, body, headers \\ []) do
    conn =
      SigV4Request.signed_conn(:put, "/#{bucket}/#{key}", body: body, headers: headers)
      |> call()

    assert conn.status == 200
    conn
  end

  defp get_object(bucket, key, query \\ %{}) do
    SigV4Request.signed_conn(:get, "/#{bucket}/#{key}", query: query)
    |> call()
  end

  defp list_buckets do
    SigV4Request.signed_conn(:get, "/")
    |> call()
  end

  defp head_bucket(bucket) do
    SigV4Request.signed_conn(:head, "/#{bucket}")
    |> call()
  end

  defp get_bucket_location(bucket) do
    SigV4Request.signed_conn(:get, "/#{bucket}", query: %{"location" => ""})
    |> call()
  end

  defp delete_object(bucket, key) do
    SigV4Request.signed_conn(:delete, "/#{bucket}/#{key}")
    |> call()
  end

  defp delete_objects(bucket, body) do
    SigV4Request.signed_conn(:post, "/#{bucket}", query: %{"delete" => ""}, body: body)
    |> call()
  end

  defp copy_object(bucket, key, source, headers \\ []) do
    SigV4Request.signed_conn(:put, "/#{bucket}/#{key}",
      headers: [{"x-amz-copy-source", source} | headers]
    )
    |> call()
  end

  defp assert_s3_error(conn, status, code) do
    assert conn.status == status
    assert conn.resp_body =~ "<Code>#{code}</Code>"
  end
end
