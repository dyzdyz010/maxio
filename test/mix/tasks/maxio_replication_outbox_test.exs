defmodule Mix.Tasks.MaxioReplicationOutboxTest do
  use Maxio.DataCase, async: false

  import ExUnit.CaptureIO

  alias Maxio.S3.ReplicationOutbox
  alias Mix.Tasks.Maxio.Replication.Outbox

  @task "maxio.replication.outbox"

  setup do
    Mix.Task.reenable(@task)
    on_exit(fn -> Mix.Task.reenable(@task) end)
  end

  test "lists recent replication tasks as json with optional status filter" do
    {:ok, pending} = ReplicationOutbox.enqueue(task("pending.jpg"))
    {:ok, failed} = ReplicationOutbox.enqueue(task("failed.jpg"))
    {:ok, claimed} = ReplicationOutbox.claim(failed.id, failure_backoff_ms: 0)

    {:ok, failed} =
      ReplicationOutbox.mark_failed(claimed, :destination_down, failure_backoff_ms: 0)

    output =
      capture_io(fn ->
        Outbox.run(["--status", "failed", "--json"])
      end)

    assert %{"count" => 1, "events" => [event]} = Jason.decode!(output)
    assert event["id"] == failed.id
    assert event["status"] == "failed"
    assert event["source_bucket"] == "replcli"
    assert event["source_key"] == "images/failed.jpg"
    assert event["destination_bucket"] == "replclidst"
    assert event["error_reason"] =~ "destination_down"

    refute event["id"] == pending.id
  end

  test "prints text rows without claiming tasks" do
    {:ok, row} = ReplicationOutbox.enqueue(task("text.jpg"))

    output =
      capture_io(fn ->
        Outbox.run(["--limit", "1"])
      end)

    assert output =~ "[maxio replication.outbox] tasks=1"
    assert output =~ ~s(id="#{row.id}")
    assert output =~ ~s(status="pending")
    assert output =~ ~s(source="replcli"/"images/text.jpg")
    assert output =~ ~s(destination_bucket="replclidst")

    row_id = row.id

    assert [%{id: ^row_id, status: "pending", attempts: 0}] =
             ReplicationOutbox.list(status: "pending")
  end

  test "text output escapes hostile object keys" do
    key = "evil\nid=forged" <> <<27>> <> "[31m.jpg"
    {:ok, row} = ReplicationOutbox.enqueue(task(key))

    output =
      capture_io(fn ->
        Outbox.run(["--limit", "1"])
      end)

    lines = String.split(output, "\n", trim: true)

    assert length(lines) == 2
    assert Enum.at(lines, 0) == "[maxio replication.outbox] tasks=1"

    row_line = Enum.at(lines, 1)
    assert row_line =~ ~s(id="#{row.id}")
    assert row_line =~ ~s(source="replcli"/"images/evil\\nid=forged)
    refute String.contains?(output, <<27>>)
  end

  test "invalid args fail closed before listing" do
    assert_raise Mix.Error, ~r/usage: mix maxio\.replication\.outbox/, fn ->
      Outbox.run(["--bad"])
    end

    assert_raise Mix.Error, ~r/--limit must be a positive integer/, fn ->
      Outbox.run(["--limit", "0"])
    end

    assert_raise Mix.Error, ~r/--status must be one of/, fn ->
      Outbox.run(["--status", "queued"])
    end
  end

  defp task(key) do
    %{
      source_bucket: "replcli",
      source_key: "images/#{key}",
      source_version_id: "01JREPLCLI0000000000000000",
      event_name: "s3:ObjectCreated:Put",
      destination_bucket: "replclidst",
      rule_id: "cli",
      destination_storage_class: "STANDARD_IA",
      source_etag: "\"etag\"",
      source_size: 42
    }
  end
end
