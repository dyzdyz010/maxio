defmodule Maxio.S3.InFlightTest.BlockingBackend do
  @moduledoc false

  def put(_bucket, _key, _version_id, chunks, _opts) do
    case Application.get_env(:maxio, :in_flight_test_put_result, :ok) do
      :write_quorum ->
        {:error, :write_quorum}

      :ok ->
        parent = Application.fetch_env!(:maxio, :in_flight_test_parent)
        send(parent, {:blocking_backend_put_started, self()})

        receive do
          :continue_blocking_put -> :ok
        after
          5_000 -> raise "blocking backend timed out"
        end

        body = chunks |> Enum.to_list() |> IO.iodata_to_binary()

        {:ok,
         %{
           size: byte_size(body),
           etag: Base.encode16(:crypto.hash(:md5, body), case: :lower),
           sha256: Base.encode16(:crypto.hash(:sha256, body), case: :lower)
         }}
    end
  end

  def get(_bucket, _key, _version_id, _range) do
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

  def delete(_bucket, _key, _version_id), do: :ok
end

defmodule Maxio.S3.InFlightTest do
  use Maxio.DataCase, async: false

  alias Maxio.{Buckets, Objects}
  alias Maxio.S3.{Endpoint, InFlight}
  alias Maxio.Test.SigV4Request

  @owner "arn:aws:iam:::root"

  setup do
    InFlight.reset()

    previous_backend = Application.get_env(:maxio, :storage_backend)
    previous_parent = Application.get_env(:maxio, :in_flight_test_parent)
    previous_put_result = Application.get_env(:maxio, :in_flight_test_put_result)

    on_exit(fn ->
      InFlight.reset()
      Application.put_env(:maxio, :storage_backend, previous_backend)

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

    assert_receive {:blocking_backend_put_started, backend_pid}
    assert InFlight.count() == 1

    send(backend_pid, :continue_blocking_put)
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

    assert_receive {:blocking_backend_get_started, stream_pid}
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
end
