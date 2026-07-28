defmodule Maxio.S3.NotificationDeliverySchedulerTest do
  use Maxio.DataCase, async: false

  alias Maxio.S3.NotificationDelivery.Scheduler
  alias Maxio.S3.NotificationOutbox

  setup do
    previous_delivery = Application.get_env(:maxio, :notification_delivery)
    previous_scheduler = Application.get_env(:maxio, :notification_delivery_scheduler)

    Application.delete_env(:maxio, :notification_delivery)

    on_exit(fn ->
      restore_env(:notification_delivery, previous_delivery)
      restore_env(:notification_delivery_scheduler, previous_scheduler)
    end)
  end

  test "disabled scheduler starts without scheduling periodic drains" do
    pid = start_scheduler(enabled: false)

    assert %{
             enabled: false,
             interval_ms: 60_000,
             scheduled?: false,
             last_result: nil
           } = Scheduler.status(pid)
  end

  test "invalid interval falls back to default interval" do
    pid = start_scheduler(enabled: false, interval_ms: 0)

    assert %{enabled: false, interval_ms: 60_000, scheduled?: false} = Scheduler.status(pid)
  end

  test "manual run_now drains due outbox rows and records last result" do
    {:ok, row} = NotificationOutbox.enqueue(event("manual.jpg"))

    pid =
      start_scheduler(
        enabled: false,
        deliverer: {Maxio.Test.NotificationDeliverer, self()},
        drain_limit: 10,
        failure_backoff_ms: 0
      )

    assert {:ok, %{claimed: 1, delivered: 1, failed: 0}} = Scheduler.run_now(pid, [])
    assert_receive {:maxio_notification, delivered}
    assert delivered.bucket == "notifyscheduler"
    assert delivered.key == "manual.jpg"

    assert %{status: "delivered", attempts: 1} = NotificationOutbox.get!(row.id)

    assert %{last_result: {:ok, %{claimed: 1, delivered: 1, failed: 0}}} =
             Scheduler.status(pid)
  end

  test "run_opts limit overrides configured drain limit" do
    {:ok, first} = NotificationOutbox.enqueue(event("limited-a.jpg"))
    {:ok, second} = NotificationOutbox.enqueue(event("limited-b.jpg"))

    pid =
      start_scheduler(
        enabled: false,
        deliverer: {Maxio.Test.NotificationDeliverer, self()},
        drain_limit: 2,
        run_opts: [limit: 1]
      )

    assert {:ok, %{claimed: 1, delivered: 1, failed: 0}} = Scheduler.run_now(pid, [])
    assert_receive {:maxio_notification, delivered}

    delivered_key = delivered.key
    assert delivered_key in ["limited-a.jpg", "limited-b.jpg"]

    statuses =
      [NotificationOutbox.get!(first.id), NotificationOutbox.get!(second.id)]
      |> Map.new(fn row -> {row.object_key, row.status} end)

    assert statuses[delivered_key] == "delivered"

    pending_key =
      ["limited-a.jpg", "limited-b.jpg"]
      |> Enum.reject(&(&1 == delivered_key))
      |> hd()

    assert statuses[pending_key] == "pending"
  end

  test "enabled scheduler drains automatically and reschedules" do
    {:ok, row} = NotificationOutbox.enqueue(event("scheduled.jpg"))

    pid =
      start_scheduler(
        enabled: true,
        initial_delay_ms: 0,
        interval_ms: 60_000,
        deliverer: {Maxio.Test.NotificationDeliverer, self()},
        failure_backoff_ms: 0
      )

    assert_receive {:maxio_notification, delivered}, 1_000
    assert delivered.key == "scheduled.jpg"

    _state = :sys.get_state(pid)

    assert %{status: "delivered", attempts: 1} = NotificationOutbox.get!(row.id)

    assert %{
             enabled: true,
             scheduled?: true,
             last_result: {:ok, %{claimed: 1, delivered: 1, failed: 0}}
           } = Scheduler.status(pid)
  end

  test "run_now without deliverer leaves due rows pending" do
    {:ok, row} = NotificationOutbox.enqueue(event("pending.jpg"))
    pid = start_scheduler(enabled: false)

    assert {:error, :no_deliverer} = Scheduler.run_now(pid, [])

    assert %{status: "pending", attempts: 0, delivered_at: nil} =
             NotificationOutbox.get!(row.id)

    assert %{last_result: {:error, :no_deliverer}} = Scheduler.status(pid)
  end

  defp start_scheduler(opts) do
    opts =
      opts
      |> Keyword.put_new(:name, nil)
      |> Keyword.put_new(:interval_ms, 60_000)

    start_supervised!({Scheduler, opts})
  end

  defp event(key) do
    record = %{
      "eventName" => "ObjectCreated:Put",
      "s3" => %{
        "bucket" => %{"name" => "notifyscheduler"},
        "object" => %{"key" => URI.encode_www_form(key), "sequencer" => "LOCAL"}
      }
    }

    %{
      destination: %{
        type: "Queue",
        arn: "arn:aws:sqs:us-east-1:000000000000:scheduler",
        id: "scheduler",
        events: ["s3:ObjectCreated:Put"],
        filter: nil
      },
      message: %{"Records" => [record]},
      record: record,
      event_name: "s3:ObjectCreated:Put",
      bucket: "notifyscheduler",
      key: key
    }
  end

  defp restore_env(key, nil), do: Application.delete_env(:maxio, key)
  defp restore_env(key, value), do: Application.put_env(:maxio, key, value)
end
