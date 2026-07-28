defmodule Maxio.S3.ReplicationDeliverySchedulerTest do
  use Maxio.DataCase, async: false

  alias Maxio.Cluster.Placement
  alias Maxio.{Buckets, ObjectMeta, Objects, Storage}
  alias Maxio.S3.ReplicationDelivery.Scheduler
  alias Maxio.S3.ReplicationOutbox
  alias Maxio.S3.ReplicationOutbox.Event
  alias Maxio.Versioning.VersionId

  @data_dir Path.join(System.tmp_dir!(), "maxio_replication_delivery_scheduler")

  setup do
    File.rm_rf(@data_dir)
    File.mkdir_p!(@data_dir)

    previous_s3 = Application.get_env(:maxio, :s3)
    previous_authoritative_source = Application.get_env(:maxio, :authoritative_source)
    previous_scheduler = Application.get_env(:maxio, :replication_delivery_scheduler)

    Application.put_env(:maxio, :s3, Keyword.put(previous_s3, :data_dir, @data_dir))
    Application.put_env(:maxio, :authoritative_source, read: :pg, list: :pg, write: :pg)

    on_exit(fn ->
      restore_env(:s3, previous_s3)
      restore_env(:authoritative_source, previous_authoritative_source)
      restore_env(:replication_delivery_scheduler, previous_scheduler)
      File.rm_rf(@data_dir)
    end)

    :ok
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

  test "invalid interval and drain limit fall back to defaults" do
    pid = start_scheduler(enabled: false, interval_ms: 0, drain_limit: 0)

    assert %{enabled: false, interval_ms: 60_000, scheduled?: false} =
             Scheduler.status(pid)

    assert {:ok, %{claimed: 0, completed: 0, failed: 0}} = Scheduler.run_now(pid, [])
  end

  test "manual run_now drains due replication outbox rows and records last result" do
    create_versioned_bucket("rschedmanualsrc")
    create_versioned_bucket("rschedmanualdst")

    source =
      put_source_object("rschedmanualsrc", "logs/manual.txt", "manual replication payload")

    {:ok, event} = enqueue_task("rschedmanualsrc", "rschedmanualdst", source)

    pid =
      start_scheduler(
        enabled: false,
        drain_limit: 10,
        failure_backoff_ms: 0
      )

    assert {:ok, %{claimed: 1, completed: 1, failed: 0}} = Scheduler.run_now(pid, [])

    assert %{status: "completed", attempts: 1} = outbox_event(event.id)

    assert %{replication_status: "COMPLETED"} =
             ObjectMeta.get("rschedmanualsrc", "logs/manual.txt", source.version_id)

    assert %{replication_status: "REPLICA"} =
             ObjectMeta.get("rschedmanualdst", "logs/manual.txt", source.version_id)

    assert read_object("rschedmanualdst", "logs/manual.txt", source.version_id) ==
             "manual replication payload"

    assert %{last_result: {:ok, %{claimed: 1, completed: 1, failed: 0}}} =
             Scheduler.status(pid)
  end

  test "run_opts limit overrides configured drain limit" do
    create_versioned_bucket("rschedlimitsrc")
    create_versioned_bucket("rschedlimitdst")

    first = put_source_object("rschedlimitsrc", "logs/limited-a.txt", "first")
    second = put_source_object("rschedlimitsrc", "logs/limited-b.txt", "second")

    {:ok, _first_event} = enqueue_task("rschedlimitsrc", "rschedlimitdst", first)
    {:ok, _second_event} = enqueue_task("rschedlimitsrc", "rschedlimitdst", second)

    pid =
      start_scheduler(
        enabled: false,
        drain_limit: 2,
        run_opts: [limit: 1],
        failure_backoff_ms: 0
      )

    assert {:ok, %{claimed: 1, completed: 1, failed: 0}} = Scheduler.run_now(pid, [])

    statuses =
      ReplicationOutbox.list(limit: 10)
      |> Map.new(fn event -> {event.source_key, event.status} end)

    assert Enum.count(statuses, fn {_key, status} -> status == "completed" end) == 1
    assert Enum.count(statuses, fn {_key, status} -> status == "pending" end) == 1
  end

  test "enabled scheduler drains automatically and reschedules" do
    create_versioned_bucket("rschedautosrc")
    create_versioned_bucket("rschedautodst")

    source = put_source_object("rschedautosrc", "logs/scheduled.txt", "scheduled payload")
    {:ok, event} = enqueue_task("rschedautosrc", "rschedautodst", source)

    pid =
      start_scheduler(
        enabled: true,
        initial_delay_ms: 0,
        interval_ms: 60_000,
        drain_limit: 10,
        failure_backoff_ms: 0
      )

    assert_eventually(fn -> outbox_event(event.id).status == "completed" end)

    assert %{status: "completed", attempts: 1} = outbox_event(event.id)

    assert %{
             enabled: true,
             scheduled?: true,
             last_result: {:ok, %{claimed: 1, completed: 1, failed: 0}}
           } = Scheduler.status(pid)
  end

  test "stray drain messages are ignored" do
    create_versioned_bucket("rschedstraysrc")
    create_versioned_bucket("rschedstraydst")

    source = put_source_object("rschedstraysrc", "logs/stray.txt", "stray payload")
    {:ok, event} = enqueue_task("rschedstraysrc", "rschedstraydst", source)

    pid =
      start_scheduler(
        enabled: true,
        initial_delay_ms: 60_000,
        interval_ms: 60_000,
        drain_limit: 10,
        failure_backoff_ms: 0
      )

    send(pid, :drain)
    send(pid, {:drain, make_ref()})
    send(pid, {:drain, nil})
    _state = :sys.get_state(pid)

    assert %{status: "pending", attempts: 0} = outbox_event(event.id)
    assert %{enabled: true, scheduled?: true, last_result: nil} = Scheduler.status(pid)
  end

  test "drain errors are recorded without crashing scheduler" do
    pid =
      start_scheduler(
        enabled: false,
        repo: Maxio.Test.ReplicationOutboxFailingRepo
      )

    assert {:error, :forced_replication_scheduler_failure} = Scheduler.run_now(pid, [])

    assert %{last_result: {:error, :forced_replication_scheduler_failure}} =
             Scheduler.status(pid)
  end

  test "worker exits are recorded without hanging run_now" do
    pid =
      start_scheduler(
        enabled: false,
        repo: Maxio.Test.ReplicationOutboxKillingRepo
      )

    assert {:error, {:drain_worker_down, :killed}} = Scheduler.run_now(pid, [])

    assert %{last_result: {:error, {:drain_worker_down, :killed}}, draining?: false} =
             Scheduler.status(pid)
  end

  defp start_scheduler(opts) do
    opts =
      opts
      |> Keyword.put_new(:name, nil)
      |> Keyword.put_new(:interval_ms, 60_000)

    start_supervised!({Scheduler, opts})
  end

  defp create_versioned_bucket(name) do
    assert {:ok, _bucket} = Buckets.create(name, "owner")
    assert :ok = Storage.put_bucket(name)
    assert :ok = Buckets.put_versioning(name, "Enabled", nil)
  end

  defp put_source_object(bucket, key, body) do
    version_id = VersionId.generate()
    size = byte_size(body)

    object_meta = %{
      size: size,
      content_type: "text/plain",
      storage_class: "STANDARD",
      tags: %{},
      user_metadata: %{},
      replication_status: "PENDING"
    }

    assert {:ok, write_result} =
             Storage.put(bucket, key, version_id, [body], object_meta: object_meta)

    attrs =
      %{
        size: write_result.size,
        etag: write_result.etag,
        content_type: "text/plain",
        storage_class: "STANDARD",
        metadata: %{},
        tags: %{},
        replication_status: "PENDING"
      }
      |> Map.merge(Placement.attrs_from_result(write_result))

    assert {:ok, object} = Objects.put_version_with_id(bucket, key, version_id, attrs)
    object
  end

  defp enqueue_task(source_bucket, destination_bucket, source) do
    ReplicationOutbox.enqueue(%{
      source_bucket: source.bucket_name,
      source_key: source.key,
      source_version_id: source.version_id,
      event_name: "s3:ObjectCreated:Put",
      destination_bucket: destination_bucket,
      rule_id: "scheduler",
      destination_storage_class: nil,
      source_etag: source.etag,
      source_size: source.size,
      payload: %{"source_bucket" => source_bucket}
    })
  end

  defp read_object(bucket, key, version_id) do
    object = ObjectMeta.get(bucket, key, version_id)
    {:ok, stream} = Storage.get(bucket, key, version_id, nil, Placement.storage_opts(object))
    stream |> Enum.to_list() |> IO.iodata_to_binary()
  end

  defp outbox_event(id), do: Repo.get!(Event, id)

  defp assert_eventually(fun, timeout_ms \\ 2_000) when is_function(fun, 0) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    unless eventually?(fun, deadline) do
      flunk("condition did not become true within #{timeout_ms}ms")
    end
  end

  defp eventually?(fun, deadline) do
    if fun.() do
      true
    else
      if System.monotonic_time(:millisecond) >= deadline do
        false
      else
        receive do
        after
          10 -> eventually?(fun, deadline)
        end
      end
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:maxio, key)
  defp restore_env(key, value), do: Application.put_env(:maxio, key, value)
end
