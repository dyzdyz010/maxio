defmodule Maxio.Console.DirectMultipartUpload.UnfinishedOperationsTest do
  use Maxio.DataCase, async: false

  import Ecto.Query

  alias Maxio.Console.DirectMultipartUpload
  alias Maxio.Multipart
  alias Maxio.Multipart.Upload
  alias Maxio.Repo

  @bucket "direct-prune-bucket"
  @principal "arn:aws:iam:::root"
  @other_principal "arn:aws:iam:::user/other"
  @access_key "AKIAIOSFODNN7EXAMPLE"
  @now ~U[2026-06-29 00:00:00Z]
  @old DateTime.add(@now, -7_200, :second)
  @recent DateTime.add(@now, -600, :second)

  setup do
    {:ok, _bucket} = Maxio.Buckets.create(@bucket, @principal)
    :ok = Maxio.Storage.put_bucket(@bucket)
    :ok
  end

  test "dry-run selects old active uploads without mutating S3 MPU authority or history" do
    {old, _registry} = start_direct_upload("docs/old.bin")
    touch_upload(old, @old)

    {recent, _registry} = start_direct_upload("docs/recent.bin")
    touch_upload(recent, @recent)

    assert {:ok, summary} =
             DirectMultipartUpload.prune_active(
               bucket: @bucket,
               prefix: "docs/",
               scope: "recursive",
               all_owners: true,
               older_than_seconds: 3_600,
               now: @now,
               dry_run: true
             )

    assert summary.matched == 1
    assert summary.selected == 1
    assert summary.would_abort == 1
    assert summary.aborted == 0
    assert summary.failed == 0

    assert {:ok, _upload} = Multipart.get_upload(@bucket, "docs/old.bin", old.upload_id)
    assert {:ok, _upload} = Multipart.get_upload(@bucket, "docs/recent.bin", recent.upload_id)
    assert [] = DirectMultipartUpload.list_history(@bucket, "docs/", @principal)
  end

  test "confirmed prune aborts via S3 MPU authority and records non-secret terminal history" do
    {visible, _registry} = start_direct_upload("docs/visible.bin", file_size: 6, part_size: 3)
    touch_upload(visible, @old)
    put_part(visible, 1, "900150983cd24fb0d6963f7d28e17f72", 3)

    {other, _registry} =
      start_direct_upload("docs/other.bin", principal_arn: @other_principal, file_size: 6)

    touch_upload(other, @old)

    assert {:ok, summary} =
             DirectMultipartUpload.prune_active(
               bucket: @bucket,
               prefix: "docs/",
               principal_arn: @principal,
               older_than_seconds: 3_600,
               now: @now,
               dry_run: false,
               confirm_abort: true
             )

    assert summary.matched == 1
    assert summary.selected == 1
    assert summary.aborted == 1
    assert summary.not_found == 0
    assert summary.failed == 0

    assert {:error, :not_found} =
             Multipart.get_upload(@bucket, "docs/visible.bin", visible.upload_id)

    assert {:ok, _upload} = Multipart.get_upload(@bucket, "docs/other.bin", other.upload_id)

    [history] = DirectMultipartUpload.list_history(@bucket, "docs/", @principal)
    assert history.terminal_state == "aborted"
    assert history.upload_id == visible.upload_id
    assert history.part_count == 1
    assert history.uploaded_size == 3
  end

  test "prune policy supports folder scope, literal search, declared size filters and limit" do
    {top_a, _registry} = start_direct_upload("docs/top-a%.bin", file_size: 10)
    {top_b, _registry} = start_direct_upload("docs/top-b%.bin", file_size: 12)
    {small, _registry} = start_direct_upload("docs/small%.bin", file_size: 2)
    {nested, _registry} = start_direct_upload("docs/nested/deep%.bin", file_size: 10)

    Enum.each([top_a, top_b, small, nested], &touch_upload(&1, @old))

    assert {:ok, summary} =
             DirectMultipartUpload.prune_active(
               bucket: @bucket,
               prefix: "docs/",
               scope: "folder",
               query: "%",
               all_owners: true,
               older_than_seconds: 3_600,
               min_file_size: 5,
               max_file_size: 12,
               limit: 1,
               now: @now,
               dry_run: true
             )

    assert summary.matched == 2
    assert summary.selected == 1
    assert summary.skipped == 1
    assert summary.would_abort == 1
  end

  test "confirmed prune requires explicit confirmation and an owner scope" do
    assert {:error, :owner_scope_required} =
             DirectMultipartUpload.prune_active(
               older_than_seconds: 3_600,
               now: @now,
               dry_run: true
             )

    assert {:error, :confirm_abort_required} =
             DirectMultipartUpload.prune_active(
               all_owners: true,
               older_than_seconds: 3_600,
               now: @now,
               dry_run: false
             )

    assert {:error, :ambiguous_owner_scope} =
             DirectMultipartUpload.prune_active(
               all_owners: true,
               principal_arn: @principal,
               older_than_seconds: 3_600,
               now: @now,
               dry_run: true
             )
  end

  test "storage abort failures are reported and leave active uploads retryable" do
    previous = Application.get_env(:maxio, :storage_backend)
    Application.put_env(:maxio, :storage_backend, Maxio.Test.StorageAbortErrorBackend)

    on_exit(fn ->
      Application.put_env(:maxio, :storage_backend, previous)
    end)

    {upload, _registry} = start_direct_upload("docs/fail.bin")
    touch_upload(upload, @old)

    assert {:ok, summary} =
             DirectMultipartUpload.prune_active(
               bucket: @bucket,
               all_owners: true,
               older_than_seconds: 3_600,
               now: @now,
               dry_run: false,
               confirm_abort: true
             )

    assert summary.aborted == 0
    assert summary.failed == 1
    assert [%{bucket: @bucket, key: "docs/fail.bin"}] = summary.errors
    assert {:ok, _upload} = Multipart.get_upload(@bucket, "docs/fail.bin", upload.upload_id)
    assert [] = DirectMultipartUpload.list_history(@bucket, "docs/", @principal)
  end

  test "SSE-C prune summaries do not expose customer key material" do
    {upload, _registry} =
      start_direct_upload("docs/sse-c.bin",
        sse_algorithm: "SSE-C",
        sse_envelope: %{"customer_key_md5_b64" => "do-not-log"}
      )

    touch_upload(upload, @old)

    assert {:ok, summary} =
             DirectMultipartUpload.prune_active(
               bucket: @bucket,
               all_owners: true,
               older_than_seconds: 3_600,
               now: @now,
               dry_run: true
             )

    refute inspect(summary) =~ "do-not-log"
    refute inspect(summary) =~ "customer_key"
  end

  defp start_direct_upload(key, opts \\ []) do
    principal_arn = Keyword.get(opts, :principal_arn, @principal)

    {:ok, upload} =
      Multipart.initiate(@bucket, key, %{
        owner: principal_arn,
        content_type: "application/octet-stream",
        storage_class: "STANDARD",
        sse_algorithm: Keyword.get(opts, :sse_algorithm),
        sse_envelope: Keyword.get(opts, :sse_envelope)
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

  defp touch_upload(%Upload{} = upload, inserted_at) do
    Repo.update_all(
      from(u in Upload, where: u.id == ^upload.id),
      set: [inserted_at: inserted_at, updated_at: inserted_at]
    )

    Repo.get!(Upload, upload.id)
  end

  defp put_part(upload, part_number, etag, size) do
    assert {:ok, _part} = Multipart.put_part(upload, part_number, %{etag: etag, size: size})
  end
end
