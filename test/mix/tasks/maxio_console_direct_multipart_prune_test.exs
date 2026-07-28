defmodule Mix.Tasks.MaxioConsoleDirectMultipartPruneTest do
  use Maxio.DataCase, async: false

  import Ecto.Query
  import ExUnit.CaptureIO

  alias Maxio.Console.DirectMultipartUpload
  alias Maxio.Multipart
  alias Maxio.Multipart.Upload
  alias Maxio.Repo
  alias Mix.Tasks.Maxio.Console.DirectMultipart.Prune

  @task "maxio.console.direct_multipart.prune"
  @bucket "direct-prune-cli-bucket"
  @principal "arn:aws:iam:::root"
  @access_key "AKIAIOSFODNN7EXAMPLE"
  @old ~U[2026-06-28 00:00:00Z]

  setup do
    Mix.Task.reenable(@task)
    {:ok, _bucket} = Maxio.Buckets.create(@bucket, @principal)
    :ok = Maxio.Storage.put_bucket(@bucket)

    on_exit(fn -> Mix.Task.reenable(@task) end)

    :ok
  end

  test "dry-run prints JSON summary and leaves uploads active" do
    {upload, _registry} = start_direct_upload("docs/dry-run.bin")
    touch_upload(upload, @old)

    output =
      capture_io(fn ->
        Prune.run([
          "--bucket",
          @bucket,
          "--prefix",
          "docs/",
          "--all-owners",
          "--older-than-minutes",
          "60",
          "--dry-run",
          "--json"
        ])
      end)

    assert %{
             "dry_run" => true,
             "matched" => 1,
             "selected" => 1,
             "would_abort" => 1,
             "aborted" => 0
           } = Jason.decode!(output)

    assert {:ok, _upload} = Multipart.get_upload(@bucket, "docs/dry-run.bin", upload.upload_id)
  end

  test "confirmed prune aborts matching owner-scoped uploads" do
    {upload, _registry} = start_direct_upload("docs/abort.bin")
    touch_upload(upload, @old)

    output =
      capture_io(fn ->
        Prune.run([
          "--bucket",
          @bucket,
          "--principal-arn",
          @principal,
          "--older-than-seconds",
          "3600",
          "--confirm-abort"
        ])
      end)

    assert output =~ "[maxio console.direct_multipart.prune]"
    assert output =~ "aborted=1"

    assert {:error, :not_found} =
             Multipart.get_upload(@bucket, "docs/abort.bin", upload.upload_id)

    assert [_history] = DirectMultipartUpload.list_history(@bucket, "docs/", @principal)
  end

  test "invalid arguments fail closed before pruning" do
    assert_raise Mix.Error, ~r/--dry-run or --confirm-abort is required/, fn ->
      Prune.run(["--all-owners", "--older-than-seconds", "60"])
    end

    assert_raise Mix.Error, ~r/--all-owners, --principal-arn, or --access-key is required/, fn ->
      Prune.run(["--older-than-seconds", "60", "--dry-run"])
    end

    assert_raise Mix.Error, ~r/use either --older-than-seconds or --older-than-minutes/, fn ->
      Prune.run([
        "--all-owners",
        "--older-than-seconds",
        "60",
        "--older-than-minutes",
        "1",
        "--dry-run"
      ])
    end

    assert_raise Mix.Error, ~r/--limit must be a positive integer/, fn ->
      Prune.run(["--all-owners", "--older-than-seconds", "60", "--limit", "0", "--dry-run"])
    end
  end

  defp start_direct_upload(key) do
    {:ok, upload} =
      Multipart.initiate(@bucket, key, %{
        owner: @principal,
        content_type: "application/octet-stream",
        storage_class: "STANDARD"
      })

    {:ok, registry} =
      DirectMultipartUpload.register(upload, %{
        principal_arn: @principal,
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
end
