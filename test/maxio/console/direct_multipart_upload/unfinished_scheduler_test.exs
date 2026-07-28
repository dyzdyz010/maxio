defmodule Maxio.Console.DirectMultipartUpload.UnfinishedSchedulerTest do
  use Maxio.DataCase, async: false

  import Ecto.Query

  alias Maxio.Console.DirectMultipartUpload
  alias Maxio.Console.DirectMultipartUpload.Scheduler
  alias Maxio.Multipart
  alias Maxio.Multipart.Upload
  alias Maxio.Repo

  @bucket "direct-prune-scheduler-bucket"
  @principal "arn:aws:iam:::root"
  @other_principal "arn:aws:iam:::user/other"
  @access_key "AKIAIOSFODNN7EXAMPLE"
  @old ~U[2026-06-28 00:00:00Z]
  @now ~U[2026-06-29 00:00:00Z]

  setup do
    previous = Application.get_env(:maxio, :console_direct_multipart_pruner)
    {:ok, _bucket} = Maxio.Buckets.create(@bucket, @principal)
    :ok = Maxio.Storage.put_bucket(@bucket)

    on_exit(fn ->
      restore_env(:console_direct_multipart_pruner, previous)
    end)

    :ok
  end

  test "disabled scheduler starts without scheduling periodic prune" do
    name = unique_name()
    pid = start_supervised!({Scheduler, name: name, enabled: false})

    assert is_pid(pid)
    assert %{enabled: false, scheduled?: false, last_result: nil} = Scheduler.status(name)
  end

  test "run_now evaluates prune policy through the scheduler process" do
    {upload, _registry} = start_direct_upload("docs/scheduled.bin")
    touch_upload(upload, @old)

    name = unique_name()

    start_supervised!(
      {Scheduler,
       name: name,
       enabled: false,
       older_than_seconds: 3_600,
       dry_run: true,
       all_owners: true,
       run_opts: [bucket: @bucket, prefix: "docs/", now: @now]}
    )

    assert {:ok, summary} = Scheduler.run_now(name, [])
    assert summary.dry_run == true
    assert summary.would_abort == 1
    assert {:ok, _upload} = Multipart.get_upload(@bucket, "docs/scheduled.bin", upload.upload_id)

    assert %{last_result: {:ok, ^summary}} = Scheduler.status(name)
  end

  test "run_now can execute confirmed aborts when configured explicitly" do
    {upload, _registry} = start_direct_upload("docs/confirmed.bin")
    touch_upload(upload, @old)

    name = unique_name()

    start_supervised!(
      {Scheduler,
       name: name,
       enabled: false,
       older_than_seconds: 3_600,
       dry_run: false,
       confirm_abort: true,
       all_owners: true,
       run_opts: [bucket: @bucket, now: @now]}
    )

    assert {:ok, summary} = Scheduler.run_now(name, [])
    assert summary.aborted == 1

    assert {:error, :not_found} =
             Multipart.get_upload(@bucket, "docs/confirmed.bin", upload.upload_id)
  end

  test "run_now owner filter is not widened by scheduler all-owner default" do
    {visible, _registry} = start_direct_upload("docs/visible-owner.bin")
    {hidden, _registry} = start_direct_upload("docs/hidden-owner.bin", @other_principal)
    touch_upload(visible, @old)
    touch_upload(hidden, @old)

    name = unique_name()

    start_supervised!(
      {Scheduler,
       name: name,
       enabled: false,
       older_than_seconds: 3_600,
       dry_run: false,
       confirm_abort: true,
       run_opts: [bucket: @bucket, principal_arn: @principal, now: @now]}
    )

    assert {:ok, summary} = Scheduler.run_now(name, [])
    assert summary.aborted == 1
    assert summary.principal_arn == @principal
    assert summary.all_owners == false

    assert {:error, :not_found} =
             Multipart.get_upload(@bucket, "docs/visible-owner.bin", visible.upload_id)

    assert {:ok, _upload} =
             Multipart.get_upload(@bucket, "docs/hidden-owner.bin", hidden.upload_id)
  end

  defp start_direct_upload(key, principal_arn \\ @principal) do
    {:ok, upload} =
      Multipart.initiate(@bucket, key, %{
        owner: principal_arn,
        content_type: "application/octet-stream",
        storage_class: "STANDARD"
      })

    {:ok, registry} =
      DirectMultipartUpload.register(upload, %{
        principal_arn: principal_arn,
        access_key: @access_key,
        file_name: Path.basename(key),
        file_size: 3,
        file_last_modified: 1_710_000_000_000,
        part_size: 3
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

  defp unique_name do
    :"direct_multipart_prune_scheduler_#{System.unique_integer([:positive])}"
  end

  defp restore_env(key, nil), do: Application.delete_env(:maxio, key)
  defp restore_env(key, value), do: Application.put_env(:maxio, key, value)
end
