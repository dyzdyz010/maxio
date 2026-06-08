defmodule MaxioWeb.DownloadControllerTest do
  use MaxioWeb.ConnCase, async: true

  setup %{conn: conn} do
    {:ok, _b} = Maxio.Buckets.create("dl-bucket", "arn:aws:iam:::root")
    {:ok, conn: log_in_console(conn)}
  end

  test "下载已存在对象返回字节", %{conn: conn} do
    {:ok, %{size: size, etag: etag}} =
      Maxio.Storage.put("dl-bucket", "file.txt", "null", ["hello world"])

    {:ok, _o} =
      Maxio.Objects.put_version_with_id("dl-bucket", "file.txt", "null", %{
        size: size,
        etag: etag,
        content_type: "text/plain"
      })

    conn = get(conn, ~p"/buckets/dl-bucket/download/file.txt")
    assert conn.status == 200
    assert response(conn, 200) == "hello world"
    assert get_resp_header(conn, "content-disposition") == [~s(attachment; filename="file.txt")]
  end

  test "下载不存在对象 404", %{conn: conn} do
    conn = get(conn, ~p"/buckets/dl-bucket/download/nope.txt")
    assert conn.status == 404
  end
end
