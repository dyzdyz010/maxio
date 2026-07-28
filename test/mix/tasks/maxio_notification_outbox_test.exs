defmodule Mix.Tasks.MaxioNotificationOutboxTest do
  use Maxio.DataCase, async: false

  import ExUnit.CaptureIO

  alias Maxio.S3.NotificationOutbox
  alias Mix.Tasks.Maxio.Notification.Outbox

  @task "maxio.notification.outbox"

  setup do
    Mix.Task.reenable(@task)
    on_exit(fn -> Mix.Task.reenable(@task) end)
  end

  test "lists recent outbox events as json with optional status filter" do
    {:ok, pending} = NotificationOutbox.enqueue(event("pending.jpg"))
    {:ok, failed} = NotificationOutbox.enqueue(event("failed.jpg"))
    {:ok, claimed} = NotificationOutbox.claim(failed.id, failure_backoff_ms: 0)

    {:ok, failed} =
      NotificationOutbox.mark_failed(claimed, :destination_down, failure_backoff_ms: 0)

    output =
      capture_io(fn ->
        Outbox.run(["--status", "failed", "--json"])
      end)

    assert %{"count" => 1, "events" => [event]} = Jason.decode!(output)
    assert event["id"] == failed.id
    assert event["status"] == "failed"
    assert event["bucket"] == "notifycli"
    assert event["key"] == "images/failed.jpg"
    assert event["error_reason"] =~ "destination_down"

    refute event["id"] == pending.id
  end

  test "prints text rows without claiming events" do
    {:ok, row} = NotificationOutbox.enqueue(event("text.jpg"))

    output =
      capture_io(fn ->
        Outbox.run(["--limit", "1"])
      end)

    assert output =~ "[maxio notification.outbox] events=1"
    assert output =~ ~s(id="#{row.id}")
    assert output =~ ~s(status="pending")
    assert output =~ ~s(bucket="notifycli")
    assert output =~ ~s(key="images/text.jpg")

    assert %{status: "pending", attempts: 0} = NotificationOutbox.get!(row.id)
  end

  test "text output escapes hostile object keys" do
    key = "evil\nid=forged" <> <<27>> <> "[31m.jpg"
    {:ok, row} = NotificationOutbox.enqueue(event(key))

    output =
      capture_io(fn ->
        Outbox.run(["--limit", "1"])
      end)

    lines = String.split(output, "\n", trim: true)

    assert length(lines) == 2
    assert Enum.at(lines, 0) == "[maxio notification.outbox] events=1"

    row_line = Enum.at(lines, 1)
    assert row_line =~ ~s(id="#{row.id}")
    assert row_line =~ ~s(key="images/evil\\nid=forged)
    refute String.contains?(output, <<27>>)

    assert %{status: "pending", attempts: 0} = NotificationOutbox.get!(row.id)
  end

  test "invalid args fail closed before listing" do
    assert_raise Mix.Error, ~r/usage: mix maxio\.notification\.outbox/, fn ->
      Outbox.run(["--bad"])
    end

    assert_raise Mix.Error, ~r/--limit must be a positive integer/, fn ->
      Outbox.run(["--limit", "0"])
    end

    assert_raise Mix.Error, ~r/--status must be one of/, fn ->
      Outbox.run(["--status", "queued"])
    end
  end

  defp event(key) do
    record = %{
      "eventName" => "ObjectCreated:Put",
      "s3" => %{
        "bucket" => %{"name" => "notifycli"},
        "object" => %{"key" => URI.encode_www_form("images/#{key}")}
      }
    }

    %{
      destination: %{
        type: "Queue",
        arn: "arn:aws:sqs:us-east-1:000000000000:cli",
        id: "cli",
        events: ["s3:ObjectCreated:Put"],
        filter: nil
      },
      message: %{"Records" => [record]},
      record: record,
      event_name: "s3:ObjectCreated:Put",
      bucket: "notifycli",
      key: "images/#{key}"
    }
  end
end
