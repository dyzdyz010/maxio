defmodule Mix.Tasks.MaxioReplicationBackfillTest do
  use Maxio.DataCase, async: false

  import ExUnit.CaptureIO

  alias Maxio.{Buckets, Objects}
  alias Maxio.S3.{Replication, ReplicationOutbox}
  alias Mix.Tasks.Maxio.Replication.Backfill

  @task "maxio.replication.backfill"

  setup do
    Mix.Task.reenable(@task)
    on_exit(fn -> Mix.Task.reenable(@task) end)
  end

  test "dry-run json reports matching tasks without writing outbox rows" do
    put_source_object!("backfillcli", "logs/cli.txt", "01JBACKFILLCLI0000000001")
    put_replication_config!("backfillcli", "replica-dest")

    output =
      capture_io(fn ->
        Backfill.run(["--source-bucket", "backfillcli", "--dry-run", "--json"])
      end)

    assert %{
             "dry_run" => true,
             "scanned_versions" => 1,
             "matched_tasks" => 1,
             "would_enqueue_tasks" => 1,
             "enqueued_tasks" => 0
           } = Jason.decode!(output)

    assert ReplicationOutbox.list(status: "pending") == []
  end

  test "confirm json writes idempotent outbox rows and reports existing rows on rerun" do
    put_source_object!("backfillcliconfirm", "logs/cli.txt", "01JBACKFILLCLI0000000002")
    put_replication_config!("backfillcliconfirm", "replica-dest")

    first =
      capture_io(fn ->
        Backfill.run(["--source-bucket", "backfillcliconfirm", "--confirm", "--json"])
      end)
      |> Jason.decode!()

    assert %{"dry_run" => false, "enqueued_tasks" => 1, "existing_tasks" => 0} = first
    assert [%{status: "pending"}] = ReplicationOutbox.list(status: "pending")

    second =
      capture_io(fn ->
        Backfill.run(["--source-bucket", "backfillcliconfirm", "--confirm", "--json"])
      end)
      |> Jason.decode!()

    assert %{"enqueued_tasks" => 0, "existing_tasks" => 1} = second
    assert length(ReplicationOutbox.list(limit: 10)) == 1
  end

  test "limit json exposes resume markers for bounded backfill chunks" do
    {:ok, _source} = Buckets.create("backfillmarkers", "owner")
    {:ok, _dest} = Buckets.create("replica-dest", "owner")
    :ok = Buckets.put_versioning("backfillmarkers", "Enabled", nil)
    :ok = Buckets.put_versioning("replica-dest", "Enabled", nil)

    insert_source_object!("backfillmarkers", "logs/a.txt", "null")
    insert_source_object!("backfillmarkers", "logs/a.txt", "01JBACKFILLCLI0000000100")
    put_replication_config!("backfillmarkers", "replica-dest")

    first =
      capture_io(fn ->
        Backfill.run(["--source-bucket", "backfillmarkers", "--limit", "1", "--json"])
      end)
      |> Jason.decode!()

    assert %{
             "scanned_versions" => 1,
             "is_truncated" => true,
             "next_key_marker" => "logs/a.txt",
             "next_version_id_marker" => "null"
           } = first

    second =
      capture_io(fn ->
        Backfill.run([
          "--source-bucket",
          "backfillmarkers",
          "--key-marker",
          first["next_key_marker"],
          "--version-id-marker",
          first["next_version_id_marker"],
          "--limit",
          "1",
          "--json"
        ])
      end)
      |> Jason.decode!()

    assert %{
             "scanned_versions" => 1,
             "is_truncated" => false,
             "next_key_marker" => nil,
             "next_version_id_marker" => nil
           } = second
  end

  test "invalid args fail closed before scanning" do
    assert_raise Mix.Error, ~r/--source-bucket is required/, fn ->
      Backfill.run(["--dry-run"])
    end

    assert_raise Mix.Error, ~r/choose exactly one/, fn ->
      Backfill.run(["--source-bucket", "bucket", "--dry-run", "--confirm"])
    end

    assert_raise Mix.Error, ~r/--limit must be a positive integer/, fn ->
      Backfill.run(["--source-bucket", "bucket", "--limit", "0"])
    end

    assert_raise Mix.Error, ~r/--key-marker requires --version-id-marker/, fn ->
      Backfill.run(["--source-bucket", "bucket", "--key-marker", "logs/a.txt"])
    end

    assert_raise Mix.Error, ~r/--version-id-marker requires --key-marker/, fn ->
      Backfill.run(["--source-bucket", "bucket", "--version-id-marker", "01J"])
    end
  end

  defp put_source_object!(bucket, key, version_id) do
    {:ok, _source} = Buckets.create(bucket, "owner")
    {:ok, _dest} = Buckets.create("replica-dest", "owner")
    :ok = Buckets.put_versioning(bucket, "Enabled", nil)
    :ok = Buckets.put_versioning("replica-dest", "Enabled", nil)

    insert_source_object!(bucket, key, version_id)
  end

  defp insert_source_object!(bucket, key, version_id) do
    {:ok, _object} =
      Objects.put_version_with_id(bucket, key, version_id, %{
        size: 3,
        etag: "\"etag\""
      })
  end

  defp put_replication_config!(source_bucket, destination_bucket) do
    Replication.put_config(source_bucket, %{
      "Role" => "arn:aws:iam::000000000000:role/replication",
      "Rules" => [
        %{
          "ID" => "cli",
          "Priority" => 1,
          "Filter" => %{"Prefix" => "logs/"},
          "Status" => "Enabled",
          "DeleteMarkerReplication" => %{"Status" => "Disabled"},
          "Destination" => %{"Bucket" => "arn:aws:s3:::#{destination_bucket}"}
        }
      ]
    })
  end
end
