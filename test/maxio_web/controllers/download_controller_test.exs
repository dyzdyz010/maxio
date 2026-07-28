defmodule MaxioWeb.DownloadControllerTest do
  use MaxioWeb.ConnCase, async: false

  setup %{conn: conn} do
    {:ok, _b} = Maxio.Buckets.create("dl-bucket", "arn:aws:iam:::root")
    {:ok, conn: log_in_console(conn)}
  end

  test "download streams existing object bytes", %{conn: conn} do
    put_object("dl-bucket", "file.txt", "null", ["hello world"], content_type: "text/plain")

    conn = get(conn, ~p"/buckets/dl-bucket/download/file.txt")

    assert conn.status == 200
    assert response(conn, 200) == "hello world"
    assert get_resp_header(conn, "content-disposition") == [~s(attachment; filename="file.txt")]
  end

  test "inline preview streams safe text object", %{conn: conn} do
    put_object("dl-bucket", "file.txt", "null", ["hello world"], content_type: "text/plain")

    conn = get(conn, ~p"/buckets/dl-bucket/preview/file.txt")

    assert conn.status == 200
    assert response(conn, 200) == "hello world"
    assert get_resp_header(conn, "content-disposition") == [~s(inline; filename="file.txt")]
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    assert get_resp_header(conn, "content-security-policy") == ["sandbox"]
    assert [content_type] = get_resp_header(conn, "content-type")
    assert String.starts_with?(content_type, "text/plain")
  end

  test "inline preview can select a specific object version", %{conn: conn} do
    version_id = Maxio.Versioning.VersionId.generate()

    put_object("dl-bucket", "file.txt", "null", ["latest"], content_type: "text/plain")
    put_object("dl-bucket", "file.txt", version_id, ["old"], content_type: "text/plain")

    conn = get(conn, ~p"/buckets/dl-bucket/preview/file.txt?versionId=#{version_id}")

    assert conn.status == 200
    assert response(conn, 200) == "old"
    assert get_resp_header(conn, "content-disposition") == [~s(inline; filename="file.txt")]
  end

  test "inline preview rejects browser-executable content types", %{conn: conn} do
    put_object("dl-bucket", "page.html", "null", ["<h1>unsafe</h1>"], content_type: "text/html")

    conn = get(conn, ~p"/buckets/dl-bucket/preview/page.html")

    assert conn.status == 415
    assert response(conn, 415) == "Preview Not Supported"
    assert get_resp_header(conn, "content-disposition") == []
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
  end

  test "inline preview rejects svg image objects", %{conn: conn} do
    put_object("dl-bucket", "vector.svg", "null", ["<svg></svg>"], content_type: "image/svg+xml")

    conn = get(conn, ~p"/buckets/dl-bucket/preview/vector.svg")

    assert conn.status == 415
    assert response(conn, 415) == "Preview Not Supported"
    assert get_resp_header(conn, "content-disposition") == []
  end

  test "inline preview rejects objects over the preview cap", %{conn: conn} do
    put_object("dl-bucket", "huge.txt", "null", ["small"], %{
      content_type: "text/plain",
      size: MaxioWeb.ObjectPreview.max_bytes() + 1
    })

    conn = get(conn, ~p"/buckets/dl-bucket/preview/huge.txt")

    assert conn.status == 415
    assert response(conn, 415) == "Preview Not Supported"
  end

  test "inline preview returns 404 for delete markers", %{conn: conn} do
    put_object("dl-bucket", "deleted.txt", "null", ["body"], content_type: "text/plain")
    {:ok, _marker} = Maxio.Objects.insert_delete_marker("dl-bucket", "deleted.txt", "Enabled")

    conn = get(conn, ~p"/buckets/dl-bucket/preview/deleted.txt")

    assert conn.status == 404
  end

  test "storage read failures are not reported as missing metadata", %{conn: conn} do
    {:ok, _object} =
      Maxio.Objects.put_version_with_id("dl-bucket", "metadata-only.txt", "null", %{
        size: 4,
        etag: "meta-only",
        content_type: "text/plain"
      })

    conn = get(conn, ~p"/buckets/dl-bucket/download/metadata-only.txt")

    assert conn.status == 500
    assert response(conn, 500) == "Storage Read Failed"
  end

  test "download and preview routes require a console session", %{conn: _conn} do
    put_object("dl-bucket", "private.txt", "null", ["secret"], content_type: "text/plain")

    for path <- [
          ~p"/buckets/dl-bucket/download/private.txt",
          ~p"/buckets/dl-bucket/preview/private.txt"
        ] do
      conn = get(build_conn(), path)
      assert redirected_to(conn) == "/login"
    end
  end

  test "download returns 404 for missing object", %{conn: conn} do
    conn = get(conn, ~p"/buckets/dl-bucket/download/nope.txt")
    assert conn.status == 404
  end

  defp put_object(bucket, key, version_id, chunks, attrs) do
    {:ok, %{size: size, etag: etag}} = Maxio.Storage.put(bucket, key, version_id, chunks)

    object_attrs =
      %{
        size: size,
        etag: etag,
        content_type: "application/octet-stream"
      }
      |> Map.merge(Map.new(attrs))

    {:ok, object} = Maxio.Objects.put_version_with_id(bucket, key, version_id, object_attrs)
    object
  end
end
