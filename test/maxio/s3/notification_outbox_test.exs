defmodule Maxio.S3.NotificationOutboxTest do
  use Maxio.DataCase, async: false

  alias Maxio.S3.NotificationOutbox

  test "persisted payload sequencer is durable database sequence" do
    {:ok, row} = NotificationOutbox.enqueue(event("seq-a.jpg"))

    sequencer =
      row.sequence
      |> Integer.to_string(16)
      |> String.upcase()

    assert row.payload["record"]["s3"]["object"]["sequencer"] == sequencer

    assert row.payload["message"]["Records"] |> hd() |> get_in(["s3", "object", "sequencer"]) ==
             sequencer
  end

  test "enqueue_payload with a caller supplied id is idempotent" do
    id = Ecto.UUID.generate()
    payload = NotificationOutbox.event_to_payload(event("sidecar-idempotent.jpg"))

    assert {:ok, first} = NotificationOutbox.enqueue_payload(payload, id: id)
    assert {:ok, second} = NotificationOutbox.enqueue_payload(payload, id: id)

    assert first.id == id
    assert second.id == id
    assert second.sequence == first.sequence
    assert second.inserted_at == first.inserted_at

    assert [^second] = NotificationOutbox.list(status: "pending")
  end

  test "stale claims cannot overwrite a later delivered state" do
    {:ok, row} = NotificationOutbox.enqueue(event("stale.jpg"))
    {:ok, first_claim} = NotificationOutbox.claim(row.id, lease_ms: 0)

    retry_at = DateTime.add(first_claim.next_attempt_at, 1, :millisecond)
    {:ok, second_claim} = NotificationOutbox.claim(row.id, now: retry_at)

    assert second_claim.attempts == first_claim.attempts + 1
    assert {:ok, delivered} = NotificationOutbox.mark_delivered(second_claim)
    assert delivered.status == "delivered"

    assert {:error, :stale_claim} =
             NotificationOutbox.mark_failed(first_claim, :late_failure, failure_backoff_ms: 0)

    final = NotificationOutbox.get!(row.id)
    assert final.status == "delivered"
    assert final.attempts == second_claim.attempts
    assert final.delivered_at
    assert is_nil(final.error_reason)
  end

  defp event(key) do
    record = %{
      "eventName" => "ObjectCreated:Put",
      "s3" => %{
        "bucket" => %{"name" => "notifyoutboxtest"},
        "object" => %{"key" => URI.encode_www_form(key), "sequencer" => "LOCAL"}
      }
    }

    %{
      destination: %{
        type: "Queue",
        arn: "arn:aws:sqs:us-east-1:000000000000:outbox",
        id: "outbox",
        events: ["s3:ObjectCreated:Put"],
        filter: nil
      },
      message: %{"Records" => [record]},
      record: record,
      event_name: "s3:ObjectCreated:Put",
      bucket: "notifyoutboxtest",
      key: key
    }
  end
end
