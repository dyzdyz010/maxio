defmodule Mix.Tasks.MaxioNotificationDrainTest do
  use Maxio.DataCase, async: false

  import ExUnit.CaptureIO

  alias Maxio.S3.NotificationOutbox
  alias Mix.Tasks.Maxio.Notification.Drain

  @task "maxio.notification.drain"

  setup do
    previous_delivery = Application.get_env(:maxio, :notification_delivery)
    Mix.Task.reenable(@task)

    on_exit(fn ->
      restore_env(:notification_delivery, previous_delivery)
      Mix.Task.reenable(@task)
    end)
  end

  test "drains due outbox events and prints json summary" do
    {:ok, row} = NotificationOutbox.enqueue(event())

    Application.put_env(:maxio, :notification_delivery,
      deliverer: {Maxio.Test.NotificationDeliverer, self()},
      async?: false
    )

    output =
      capture_io(fn ->
        Drain.run(["--json"])
      end)

    assert %{"claimed" => 1, "delivered" => 1, "failed" => 0} = Jason.decode!(output)
    assert_receive {:maxio_notification, delivered}
    assert delivered.bucket == "notifycli"
    assert delivered.key == "images/cli.jpg"

    assert %{status: "delivered", attempts: 1} = NotificationOutbox.get!(row.id)
  end

  test "invalid args fail closed before draining" do
    assert_raise Mix.Error, ~r/usage: mix maxio\.notification\.drain/, fn ->
      Drain.run(["--bad"])
    end

    assert_raise Mix.Error, ~r/--limit must be a positive integer/, fn ->
      Drain.run(["--limit", "0"])
    end
  end

  defp event do
    record = %{
      "eventName" => "ObjectCreated:Put",
      "s3" => %{
        "bucket" => %{"name" => "notifycli"},
        "object" => %{"key" => "images%2Fcli.jpg"}
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
      key: "images/cli.jpg"
    }
  end

  defp restore_env(key, nil), do: Application.delete_env(:maxio, key)
  defp restore_env(key, value), do: Application.put_env(:maxio, key, value)
end
