defmodule Mix.Tasks.MaxioReplicationDrainTest do
  use Maxio.DataCase, async: false

  import ExUnit.CaptureIO

  alias Maxio.{Buckets, Objects}
  alias Maxio.S3.ReplicationOutbox
  alias Mix.Tasks.Maxio.Replication.Drain

  @task "maxio.replication.drain"

  setup do
    Mix.Task.reenable(@task)
    on_exit(fn -> Mix.Task.reenable(@task) end)
  end

  test "drains due replication tasks and prints json summary" do
    {:ok, _bucket} = Buckets.create("missing-src", "owner")

    {:ok, _object} =
      Objects.put_version_with_id("missing-src", "images/cli.jpg", task().source_version_id, %{
        size: 42,
        etag: "\"etag\"",
        replication_status: "PENDING"
      })

    {:ok, row} = ReplicationOutbox.enqueue(task())

    output =
      capture_io(fn ->
        Drain.run(["--json"])
      end)

    assert %{"claimed" => 1, "completed" => 0, "failed" => 1} = Jason.decode!(output)

    row_id = row.id

    assert [%{id: ^row_id, status: "failed", attempts: 1, error_reason: error_reason}] =
             ReplicationOutbox.list(status: "failed")

    assert error_reason =~ "destination_bucket_not_found"
  end

  test "invalid args fail closed before draining" do
    assert_raise Mix.Error, ~r/usage: mix maxio\.replication\.drain/, fn ->
      Drain.run(["--bad"])
    end

    assert_raise Mix.Error, ~r/--limit must be a positive integer/, fn ->
      Drain.run(["--limit", "0"])
    end
  end

  defp task do
    %{
      source_bucket: "missing-src",
      source_key: "images/cli.jpg",
      source_version_id: "01JREPLDRAIN00000000000000",
      event_name: "s3:ObjectCreated:Put",
      destination_bucket: "missing-dst",
      rule_id: "cli",
      destination_storage_class: nil,
      source_etag: "\"etag\"",
      source_size: 42
    }
  end
end
