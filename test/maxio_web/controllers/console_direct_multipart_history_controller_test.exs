defmodule MaxioWeb.ConsoleDirectMultipartHistoryControllerTest do
  use MaxioWeb.ConnCase, async: false

  alias Maxio.Console.DirectMultipartUpload
  alias Maxio.Console.DirectMultipartUpload.History
  alias Maxio.Multipart
  alias Maxio.Repo

  @bucket "history-export-bucket"
  @principal "arn:aws:iam:::root"
  @access_key "AKIAIOSFODNN7EXAMPLE"

  setup %{conn: conn} do
    {:ok, _bucket} = Maxio.Buckets.create(@bucket, @principal)
    :ok = Maxio.Storage.put_bucket(@bucket)

    {:ok, conn: log_in_console(conn)}
  end

  test "CSV export requires a Console session" do
    conn = get(build_conn(), ~p"/buckets/#{@bucket}/direct-multipart/history.csv")

    assert redirected_to(conn) == "/login"
  end

  test "CSV export filters terminal history and omits direct upload secrets", %{conn: conn} do
    completed = record_completed("docs/=formula.bin", file_name: "=formula.bin")
    _nested = record_completed("docs/nested/deep.bin")
    _aborted = record_aborted("docs/keep-aborted.bin")

    _other_principal =
      record_completed("docs/other-principal.bin", principal_arn: "arn:aws:iam:::user/other")

    conn =
      conn
      |> put_req_header("accept", "text/csv")
      |> get(
        ~p"/buckets/#{@bucket}/direct-multipart/history.csv?#{%{prefix: "docs/", mpu_scope: "folder", mpu_state: "completed", mpu_q: "formula", mpu_limit: "25"}}"
      )

    body = response(conn, 200)

    assert [content_type] = get_resp_header(conn, "content-type")
    assert String.starts_with?(content_type, "text/csv")

    assert get_resp_header(conn, "content-disposition") == [
             ~s(attachment; filename="maxio-direct-multipart-history.csv")
           ]

    assert body =~
             ~s("terminal_state","bucket","key","upload_id","file_name","file_size","file_last_modified")

    assert body =~
             ~s("completed","#{@bucket}","docs/=formula.bin","#{completed.upload_id}","'=formula.bin")

    refute body =~ "docs/nested/deep.bin"
    refute body =~ "docs/keep-aborted.bin"
    refute body =~ "docs/other-principal.bin"

    refute body =~ @access_key
    refute body =~ "secret"
    refute body =~ "X-Amz-Signature"
    refute body =~ "x-amz-server-side-encryption-customer-key"
  end

  test "CSV export can include recursive prefix history up to a capped requested limit", %{
    conn: conn
  } do
    _top = record_completed("docs/top.csv")
    nested = record_completed("docs/nested/deep.csv")

    conn =
      get(
        conn,
        ~p"/buckets/#{@bucket}/direct-multipart/history.csv?#{%{prefix: "docs/", mpu_scope: "recursive", mpu_state: "completed", mpu_q: "deep", mpu_limit: "999999"}}"
      )

    body = response(conn, 200)

    assert body =~ nested.upload_id
    assert body =~ "docs/nested/deep.csv"
    refute body =~ "docs/top.csv"
  end

  test "CSV export prefixes spreadsheet formula cells across exported fields", %{conn: conn} do
    insert_history(%{key: "+key.csv", upload_id: "-upload", file_name: "@file.csv"})
    insert_history(%{key: "\tkey.csv", upload_id: "+upload", file_name: "-file.csv"})
    insert_history(%{key: "\nkey.csv", upload_id: "@upload", file_name: "\tfile.csv"})

    conn =
      get(
        conn,
        ~p"/buckets/#{@bucket}/direct-multipart/history.csv?#{%{mpu_scope: "bucket", mpu_state: "completed", mpu_limit: "25"}}"
      )

    body = response(conn, 200)

    assert body =~ ~s("'+key.csv")
    assert body =~ ~s("'-upload")
    assert body =~ ~s("'@file.csv")
    assert body =~ "\"'\tkey.csv\""
    assert body =~ ~s("'+upload")
    assert body =~ ~s("'-file.csv")
    assert body =~ "\"'\nkey.csv\""
    assert body =~ ~s("'@upload")
    assert body =~ "\"'\tfile.csv\""
  end

  test "CSV export returns 404 for a missing bucket", %{conn: conn} do
    conn = get(conn, ~p"/buckets/no-such/direct-multipart/history.csv")

    assert response(conn, 404) == "bucket not found"
  end

  defp record_completed(key, opts \\ []) do
    {upload, _registry} = start_direct_upload(key, opts)

    assert {:ok, history} =
             DirectMultipartUpload.record_completed(upload, %{
               etag: Keyword.get(opts, :etag, "etag-#{Path.basename(key)}"),
               version_id: Keyword.get(opts, :version_id, "null"),
               size: Keyword.get(opts, :uploaded_size, 3)
             })

    history
  end

  defp record_aborted(key, opts \\ []) do
    {_upload, registry} = start_direct_upload(key, opts)

    assert :ok =
             DirectMultipartUpload.abort(
               registry.id,
               Keyword.get(opts, :principal_arn, @principal)
             )

    DirectMultipartUpload.list_history(
      @bucket,
      key,
      Keyword.get(opts, :principal_arn, @principal)
    )
    |> List.first()
  end

  defp start_direct_upload(key, opts) do
    principal_arn = Keyword.get(opts, :principal_arn, @principal)

    {:ok, upload} =
      Multipart.initiate(@bucket, key, %{
        owner: principal_arn,
        content_type: Keyword.get(opts, :content_type, "text/plain"),
        storage_class: Keyword.get(opts, :storage_class, "STANDARD"),
        sse_algorithm: Keyword.get(opts, :sse_algorithm)
      })

    {:ok, registry} =
      DirectMultipartUpload.register(upload, %{
        principal_arn: principal_arn,
        access_key: Keyword.get(opts, :access_key, @access_key),
        file_name: Keyword.get(opts, :file_name, Path.basename(key)),
        file_size: Keyword.get(opts, :file_size, 3),
        file_last_modified: Keyword.get(opts, :file_last_modified, 1_710_000_000_000),
        part_size: Keyword.get(opts, :part_size, 3)
      })

    {upload, registry}
  end

  defp insert_history(attrs) do
    now = DateTime.utc_now()

    attrs =
      Map.merge(
        %{
          upload_id: Ecto.UUID.generate(),
          terminal_state: "completed",
          bucket_name: @bucket,
          key: "object.csv",
          principal_arn: @principal,
          access_key: @access_key,
          file_name: "object.csv",
          file_size: 3,
          file_last_modified: 1_710_000_000_000,
          part_size: 3,
          part_count: 1,
          uploaded_size: 3,
          terminal_at: now
        },
        attrs
      )

    assert {:ok, _history} = %History{} |> History.changeset(attrs) |> Repo.insert()
  end
end
