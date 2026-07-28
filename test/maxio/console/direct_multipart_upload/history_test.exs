defmodule Maxio.Console.DirectMultipartUpload.HistoryTest do
  use Maxio.DataCase, async: false

  alias Maxio.Console.DirectMultipartUpload
  alias Maxio.Multipart

  @principal "arn:aws:iam:::root"
  @access_key "AKIAIOSFODNN7EXAMPLE"

  setup do
    {:ok, _bucket} = Maxio.Buckets.create("history-bucket", @principal)
    :ok = Maxio.Storage.put_bucket("history-bucket")
    :ok
  end

  test "record_completed stores a non-secret terminal snapshot and is idempotent" do
    {upload, _registry} =
      start_direct_upload("docs/secret.bin",
        file_size: 6,
        part_size: 3,
        sse_algorithm: "SSE-C",
        sse_envelope: %{"customer_key_md5" => "not-a-secret"}
      )

    put_part(upload, 1, "900150983cd24fb0d6963f7d28e17f72", 3)
    put_part(upload, 2, "4ed9407630eb1000c0f6b63842defa7d", 3)

    assert {:ok, history} =
             DirectMultipartUpload.record_completed(upload, %{
               etag: "8e18a6d3619b553c27c7028ea9067e05-2",
               version_id: "null",
               size: 6
             })

    assert history.terminal_state == "completed"
    assert history.bucket_name == "history-bucket"
    assert history.key == "docs/secret.bin"
    assert history.upload_id == upload.upload_id
    assert history.part_count == 2
    assert history.uploaded_size == 6
    assert history.etag == "8e18a6d3619b553c27c7028ea9067e05-2"
    assert history.version_id == "null"
    assert history.sse_algorithm == "SSE-C"
    assert history.sse_customer_key_required == true
    refute inspect(history) =~ "customer-key"
    refute inspect(history) =~ "not-a-secret"

    assert :ok =
             DirectMultipartUpload.record_completed(upload, %{
               etag: "different",
               version_id: "other",
               size: 6
             })

    histories = DirectMultipartUpload.list_history("history-bucket", "docs/", @principal)
    assert length(histories) == 1
    assert hd(histories).etag == "8e18a6d3619b553c27c7028ea9067e05-2"
  end

  test "abort records terminal history before active registry is deleted" do
    {upload, registry} = start_direct_upload("docs/abort.bin", file_size: 3, part_size: 3)
    put_part(upload, 1, "900150983cd24fb0d6963f7d28e17f72", 3)

    assert :ok = DirectMultipartUpload.abort(registry.id, @principal)

    assert {:error, :not_found} =
             Multipart.get_upload("history-bucket", "docs/abort.bin", upload.upload_id)

    [history] = DirectMultipartUpload.list_history("history-bucket", "docs/", @principal)
    assert history.terminal_state == "aborted"
    assert history.upload_id == upload.upload_id
    assert history.part_count == 1
    assert history.uploaded_size == 3
    assert history.etag == nil
    assert history.version_id == nil
  end

  test "abort failure does not record aborted terminal history" do
    previous = Application.get_env(:maxio, :storage_backend)
    Application.put_env(:maxio, :storage_backend, Maxio.Test.StorageAbortFailBackend)

    on_exit(fn ->
      Application.put_env(:maxio, :storage_backend, previous)
    end)

    {_upload, registry} = start_direct_upload("docs/abort-fail.bin", file_size: 3, part_size: 3)

    assert_raise RuntimeError, "abort failed", fn ->
      DirectMultipartUpload.abort(registry.id, @principal)
    end

    assert [] = DirectMultipartUpload.list_history("history-bucket", "docs/", @principal)
  end

  test "abort storage error keeps active upload and counts bulk failure" do
    previous = Application.get_env(:maxio, :storage_backend)
    Application.put_env(:maxio, :storage_backend, Maxio.Test.StorageAbortErrorBackend)

    on_exit(fn ->
      Application.put_env(:maxio, :storage_backend, previous)
    end)

    {upload, registry} = start_direct_upload("docs/abort-error.bin", file_size: 3, part_size: 3)

    assert {:error, :write_quorum} = DirectMultipartUpload.abort(registry.id, @principal)
    assert [] = DirectMultipartUpload.list_history("history-bucket", "docs/", @principal)

    assert {:ok, _upload} =
             Multipart.get_upload("history-bucket", "docs/abort-error.bin", upload.upload_id)

    result = DirectMultipartUpload.abort_many([registry.id], @principal)

    assert result.aborted == 0
    assert result.not_found == 0
    assert result.failed == 1
    assert result.skipped == 0

    assert [] = DirectMultipartUpload.list_history("history-bucket", "docs/", @principal)

    assert {:ok, _upload} =
             Multipart.get_upload("history-bucket", "docs/abort-error.bin", upload.upload_id)
  end

  test "terminal cleanup removes upload metadata even when part cleanup returns an error" do
    previous = Application.get_env(:maxio, :storage_backend)
    Application.put_env(:maxio, :storage_backend, Maxio.Test.StorageAbortErrorBackend)

    on_exit(fn ->
      Application.put_env(:maxio, :storage_backend, previous)
    end)

    {upload, _registry} = start_direct_upload("docs/cleanup-error.bin")

    assert {:error, :write_quorum} = Multipart.cleanup_after_terminal(upload)

    assert {:error, :not_found} =
             Multipart.get_upload("history-bucket", "docs/cleanup-error.bin", upload.upload_id)
  end

  test "bulk abort treats invalid registry ids as not found instead of raising" do
    result = DirectMultipartUpload.abort_many(["not-a-uuid"], @principal)

    assert result.aborted == 0
    assert result.not_found == 1
    assert result.failed == 0
    assert result.skipped == 0
  end

  test "list_history is scoped by principal, bucket and prefix" do
    {upload, _registry} = start_direct_upload("docs/visible.bin")
    assert {:ok, _history} = DirectMultipartUpload.record_completed(upload, %{size: 3})

    assert [_] = DirectMultipartUpload.list_history("history-bucket", "docs/", @principal)
    assert [] = DirectMultipartUpload.list_history("history-bucket", "other/", @principal)

    assert [] =
             DirectMultipartUpload.list_history(
               "history-bucket",
               "docs/",
               "arn:aws:iam:::user/other"
             )

    assert [] = DirectMultipartUpload.list_history("other-bucket", "docs/", @principal)
  end

  test "list_active supports folder, recursive, bucket scope and literal search" do
    start_direct_upload("docs/top.bin")
    start_direct_upload("docs/nested/deep.bin")
    start_direct_upload("other/top.bin")
    start_direct_upload("docs/literal%_name.bin")

    assert active_keys(scope: "folder") == ["docs/literal%_name.bin", "docs/top.bin"]

    assert active_keys(scope: "recursive") == [
             "docs/literal%_name.bin",
             "docs/nested/deep.bin",
             "docs/top.bin"
           ]

    assert active_keys(scope: "bucket") == [
             "docs/literal%_name.bin",
             "docs/nested/deep.bin",
             "docs/top.bin",
             "other/top.bin"
           ]

    assert active_keys(scope: "recursive", query: "%_") == ["docs/literal%_name.bin"]
  end

  test "list_history filters state and search before limiting folder-scope rows" do
    {top, _registry} = start_direct_upload("docs/top-completed.bin")
    assert {:ok, _history} = DirectMultipartUpload.record_completed(top, %{size: 3})

    {nested, _registry} = start_direct_upload("docs/nested/newer-completed.bin")
    assert {:ok, _history} = DirectMultipartUpload.record_completed(nested, %{size: 3})

    assert ["docs/top-completed.bin"] =
             history_keys(scope: "folder", terminal_state: "completed", limit: 1)

    {_abort_upload, abort_registry} = start_direct_upload("docs/abort-filter.bin")
    assert :ok = DirectMultipartUpload.abort(abort_registry.id, @principal)

    assert ["docs/abort-filter.bin"] =
             history_keys(scope: "recursive", terminal_state: "aborted", query: "abort")
  end

  test "scope filters treat prefix wildcard characters literally" do
    {top, _registry} = start_direct_upload("docs%_/top.bin")
    {nested, _registry} = start_direct_upload("docs%_/nested/deep.bin")
    {percent_wildcard, _registry} = start_direct_upload("docsAZ/top.bin")
    {underscore_wildcard, _registry} = start_direct_upload("docs%a/top.bin")

    for upload <- [top, nested, percent_wildcard, underscore_wildcard] do
      assert {:ok, _history} = DirectMultipartUpload.record_completed(upload, %{size: 3})
    end

    assert ["docs%_/top.bin"] =
             active_keys("docs%_/", scope: "folder")

    assert ["docs%_/nested/deep.bin", "docs%_/top.bin"] =
             active_keys("docs%_/", scope: "recursive")

    assert ["docs%_/nested/deep.bin", "docs%_/top.bin"] =
             history_keys("docs%_/", scope: "recursive")
             |> Enum.sort()
  end

  test "history retention prunes oldest rows per principal and bucket" do
    previous = Application.get_env(:maxio, :console, :__unset__)
    Application.put_env(:maxio, :console, direct_multipart_history_limit: 2)

    on_exit(fn ->
      case previous do
        :__unset__ -> Application.delete_env(:maxio, :console)
        value -> Application.put_env(:maxio, :console, value)
      end
    end)

    for index <- 1..3 do
      {upload, _registry} = start_direct_upload("docs/retained-#{index}.bin")
      assert {:ok, _history} = DirectMultipartUpload.record_completed(upload, %{size: 3})
    end

    histories =
      DirectMultipartUpload.list_history("history-bucket", "docs/", @principal, limit: 10)

    assert length(histories) == 2
    assert Enum.map(histories, & &1.key) == ["docs/retained-3.bin", "docs/retained-2.bin"]
  end

  defp start_direct_upload(key, opts \\ []) do
    {:ok, upload} =
      Multipart.initiate("history-bucket", key, %{
        owner: @principal,
        content_type: "application/octet-stream",
        storage_class: "STANDARD",
        sse_algorithm: Keyword.get(opts, :sse_algorithm),
        sse_envelope: Keyword.get(opts, :sse_envelope)
      })

    {:ok, registry} =
      DirectMultipartUpload.register(upload, %{
        principal_arn: @principal,
        access_key: @access_key,
        file_name: Path.basename(key),
        file_size: Keyword.get(opts, :file_size, 3),
        file_last_modified: Keyword.get(opts, :file_last_modified, 1_710_000_000_000),
        part_size: Keyword.get(opts, :part_size, 3)
      })

    {upload, registry}
  end

  defp put_part(upload, part_number, etag, size) do
    assert {:ok, _part} = Multipart.put_part(upload, part_number, %{etag: etag, size: size})
  end

  defp active_keys(opts) do
    active_keys("docs/", opts)
  end

  defp active_keys(prefix, opts) do
    "history-bucket"
    |> DirectMultipartUpload.list_active(prefix, @principal, opts)
    |> Enum.map(& &1.key)
  end

  defp history_keys(opts) do
    history_keys("docs/", opts)
  end

  defp history_keys(prefix, opts) do
    "history-bucket"
    |> DirectMultipartUpload.list_history(prefix, @principal, opts)
    |> Enum.map(& &1.key)
  end
end
