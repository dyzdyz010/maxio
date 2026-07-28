defmodule Maxio.S3.InFlightTest.BlockingBackend do
  @moduledoc false
  @behaviour Maxio.Storage.Backend

  alias Maxio.Storage.FS

  defdelegate local_topology(opts \\ []), to: FS

  @impl true
  def put(bucket, key, version_id, chunks, opts) do
    case Application.get_env(:maxio, :in_flight_test_put_result, :ok) do
      :write_quorum ->
        {:error, :write_quorum}

      :ok ->
        FS.put(bucket, key, version_id, chunks, wrap_publish_barrier(opts))
    end
  end

  defp wrap_publish_barrier(opts) do
    case Keyword.fetch(opts, :around_object_commit) do
      {:ok, around_object_commit} ->
        Keyword.put(opts, :around_object_commit, fn prepared, publish ->
          around_object_commit.(prepared, fn commit_opts ->
            parent = Application.fetch_env!(:maxio, :in_flight_test_parent)
            send(parent, {:blocking_backend_publish_started, self()})

            receive do
              :continue_blocking_publish -> publish.(commit_opts)
            after
              5_000 -> raise "blocking backend publish timed out"
            end
          end)
        end)

      :error ->
        opts
    end
  end

  @impl true
  def get(_bucket, _key, _version_id, _range, _opts) do
    parent = Application.fetch_env!(:maxio, :in_flight_test_parent)

    stream =
      Stream.resource(
        fn -> :pending end,
        fn
          :pending ->
            send(parent, {:blocking_backend_get_started, self()})

            receive do
              :continue_blocking_get -> {["payload"], :done}
            after
              5_000 -> raise "blocking backend get timed out"
            end

          :done ->
            {:halt, :done}
        end,
        fn _ -> :ok end
      )

    {:ok, stream}
  end

  @impl true
  def stat(bucket, key, version_id, opts), do: FS.stat(bucket, key, version_id, opts)

  @impl true
  def delete(bucket, key, version_id, opts), do: FS.delete(bucket, key, version_id, opts)

  @impl true
  def put_bucket(bucket), do: FS.put_bucket(bucket)

  @impl true
  def delete_bucket(bucket), do: FS.delete_bucket(bucket)

  @impl true
  def put_part(bucket, key, upload_id, part_number, chunks, opts),
    do: FS.put_part(bucket, key, upload_id, part_number, chunks, opts)

  @impl true
  def get_part_stream(bucket, key, upload_id, part_number, opts),
    do: FS.get_part_stream(bucket, key, upload_id, part_number, opts)

  @impl true
  def assemble(bucket, key, upload_id, part_numbers, opts),
    do: FS.assemble(bucket, key, upload_id, part_numbers, opts)

  @impl true
  def abort_upload(bucket, key, upload_id, opts),
    do: FS.abort_upload(bucket, key, upload_id, opts)

  @impl true
  def put_delete_marker(bucket, key, version_id, entry_opts, opts),
    do: FS.put_delete_marker(bucket, key, version_id, entry_opts, opts)

  @impl true
  def delete_version(bucket, key, version_id, opts),
    do: FS.delete_version(bucket, key, version_id, opts)

  @impl true
  def put_notification_ledgers(bucket, key, entries, opts),
    do: FS.put_notification_ledgers(bucket, key, entries, opts)

  @impl true
  def list_notification_ledgers(bucket, key_filter, opts),
    do: FS.list_notification_ledgers(bucket, key_filter, opts)

  @impl true
  def delete_notification_ledgers(bucket, key, ids, opts),
    do: FS.delete_notification_ledgers(bucket, key, ids, opts)

  @impl true
  def claim_epoch(target, token, operation, opts),
    do: FS.claim_epoch(target, token, operation, opts)

  @impl true
  def current_epoch(target, opts), do: FS.current_epoch(target, opts)

  @impl true
  def restore_if_current(ctx, opts), do: FS.restore_if_current(ctx, opts)

  @impl true
  def finalize_if_current(ctx, opts), do: FS.finalize_if_current(ctx, opts)
end

defmodule Maxio.S3.InFlightTest do
  use Maxio.DataCase, async: false

  alias Maxio.{Buckets, Objects}
  alias Maxio.S3.{Endpoint, InFlight}
  alias Maxio.Test.SigV4Request

  @owner "arn:aws:iam:::root"

  setup do
    InFlight.reset()

    data_dir =
      Path.join(
        System.tmp_dir!(),
        "maxio_in_flight_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(data_dir)

    previous_backend = Application.get_env(:maxio, :storage_backend)
    previous_parent = Application.get_env(:maxio, :in_flight_test_parent)
    previous_put_result = Application.get_env(:maxio, :in_flight_test_put_result)
    previous_s3 = Application.fetch_env!(:maxio, :s3)

    Application.put_env(:maxio, :s3, Keyword.put(previous_s3, :data_dir, data_dir))

    on_exit(fn ->
      InFlight.reset()
      Application.put_env(:maxio, :storage_backend, previous_backend)
      Application.put_env(:maxio, :s3, previous_s3)
      File.rm_rf(data_dir)

      if previous_parent do
        Application.put_env(:maxio, :in_flight_test_parent, previous_parent)
      else
        Application.delete_env(:maxio, :in_flight_test_parent)
      end

      if previous_put_result do
        Application.put_env(:maxio, :in_flight_test_put_result, previous_put_result)
      else
        Application.delete_env(:maxio, :in_flight_test_put_result)
      end
    end)
  end

  test "track increments during work and decrements after success or exception" do
    parent = self()

    task =
      Task.async(fn ->
        InFlight.track(fn ->
          send(parent, {:inside_track, self()})

          receive do
            :finish_track -> :ok
          end
        end)
      end)

    assert_receive {:inside_track, task_pid}
    assert InFlight.count() == 1
    send(task_pid, :finish_track)
    assert :ok = Task.await(task)
    assert InFlight.count() == 0

    assert_raise RuntimeError, "boom", fn ->
      InFlight.track(fn -> raise "boom" end)
    end

    assert InFlight.count() == 0
  end

  test "track counts concurrent workers" do
    parent = self()

    tasks =
      for _ <- 1..2 do
        Task.async(fn ->
          InFlight.track(fn ->
            send(parent, {:inside_track, self()})

            receive do
              :finish_track -> :ok
            end
          end)
        end)
      end

    pids =
      for _ <- 1..2 do
        assert_receive {:inside_track, pid}
        pid
      end

    assert InFlight.count() == 2
    assert InFlight.over?(1)
    refute InFlight.over?(2)

    Enum.each(pids, &send(&1, :finish_track))
    Enum.each(tasks, &Task.await/1)

    assert InFlight.count() == 0
  end

  test "S3 dispatch counts a live handler until it returns" do
    bucket = "inflight-#{System.unique_integer([:positive])}"
    {:ok, _bucket} = Buckets.create(bucket, @owner)

    Application.put_env(:maxio, :storage_backend, Maxio.S3.InFlightTest.BlockingBackend)
    Application.put_env(:maxio, :in_flight_test_parent, self())

    conn = SigV4Request.signed_conn(:put, "/#{bucket}/object.txt", body: "payload")
    task = Task.async(fn -> Endpoint.call(conn, Endpoint.init([])) end)

    backend_pid = await_blocking_publish!(task)
    assert InFlight.count() == 1

    send(backend_pid, :continue_blocking_publish)
    conn = Task.await(task)

    assert conn.status == 200
    assert InFlight.count() == 0
  end

  test "S3 dispatch keeps count during chunked GET stream" do
    bucket = "inflight-get-#{System.unique_integer([:positive])}"
    {:ok, _bucket} = Buckets.create(bucket, @owner)

    {:ok, _object} =
      Objects.put_version_with_id(bucket, "object.txt", "null", %{
        size: 7,
        etag: "etag-get",
        content_type: "text/plain"
      })

    Application.put_env(:maxio, :storage_backend, Maxio.S3.InFlightTest.BlockingBackend)
    Application.put_env(:maxio, :in_flight_test_parent, self())

    conn = SigV4Request.signed_conn(:get, "/#{bucket}/object.txt")
    task = Task.async(fn -> Endpoint.call(conn, Endpoint.init([])) end)

    stream_pid = await_blocking_get!(task)
    assert InFlight.count() == 1

    send(stream_pid, :continue_blocking_get)
    conn = Task.await(task)

    assert conn.status == 200
    assert conn.resp_body == "payload"
    assert InFlight.count() == 0
  end

  test "S3 dispatch releases count on mapped storage errors" do
    bucket = "inflight-error-#{System.unique_integer([:positive])}"
    {:ok, _bucket} = Buckets.create(bucket, @owner)

    Application.put_env(:maxio, :storage_backend, Maxio.S3.InFlightTest.BlockingBackend)
    Application.put_env(:maxio, :in_flight_test_put_result, :write_quorum)

    conn =
      SigV4Request.signed_conn(:put, "/#{bucket}/object.txt", body: "payload")
      |> Endpoint.call(Endpoint.init([]))

    assert conn.status == 503
    assert InFlight.count() == 0
  end

  defp await_blocking_publish!(task) do
    receive do
      {:blocking_backend_publish_started, backend_pid} ->
        backend_pid

      {ref, conn} when ref == task.ref ->
        flunk("S3 handler returned with status #{conn.status} before staged publish blocked")

      {:DOWN, ref, :process, _pid, reason} when ref == task.ref ->
        flunk("S3 handler exited before staged publish blocked: #{inspect(reason)}")
    after
      5_000 ->
        flunk("S3 handler did not reach the staged publish barrier")
    end
  end

  defp await_blocking_get!(task) do
    receive do
      {:blocking_backend_get_started, stream_pid} ->
        stream_pid

      {ref, conn} when ref == task.ref ->
        flunk("S3 GET handler returned with status #{conn.status} before its stream blocked")

      {:DOWN, ref, :process, _pid, reason} when ref == task.ref ->
        flunk("S3 GET handler exited before its stream blocked: #{inspect(reason)}")
    after
      5_000 ->
        flunk("S3 GET handler did not reach the stream barrier")
    end
  end
end
