defmodule Maxio.Cluster.DriveIOTest do
  use ExUnit.Case, async: false

  alias Maxio.Cluster.{DriveIO, IOPressure}

  setup do
    DriveIO.reset()

    on_exit(fn -> DriveIO.reset() end)
  end

  test "tracks active read operations and records bytes without changing the result" do
    parent = self()

    task =
      Task.async(fn ->
        DriveIO.track(
          :read,
          fn ->
            send(parent, {:inside_drive_io, self()})

            receive do
              :release_drive_io -> "abc"
            end
          end,
          bytes: fn result -> byte_size(result) end
        )
      end)

    assert_receive {:inside_drive_io, worker}
    assert DriveIO.active_count() == 1
    assert IOPressure.count(:storage_ops) == 1
    assert IOPressure.count(:combined) >= 1

    send(worker, :release_drive_io)

    assert Task.await(task) == "abc"

    assert %{
             active_ops: 0,
             active_read_ops: 0,
             read_ops: 1,
             bytes_read: 3,
             errors: 0
           } = DriveIO.snapshot()
  end

  test "releases active counters and increments errors when storage code raises" do
    assert_raise RuntimeError, "boom", fn ->
      DriveIO.track(:write, fn -> raise "boom" end)
    end

    assert %{
             active_ops: 0,
             active_write_ops: 0,
             write_ops: 1,
             errors: 1
           } = DriveIO.snapshot()
  end

  test "byte accounting is fail-open and never changes storage results" do
    assert DriveIO.track(:read, fn -> "abc" end, bytes: fn _result -> raise "bad byte fun" end) ==
             "abc"

    assert %{active_ops: 0, read_ops: 1, bytes_read: 0, errors: 0} = DriveIO.snapshot()
  end

  test "normalizes pressure source names" do
    assert IOPressure.normalize_source("s3-in-flight") == :s3_in_flight
    assert IOPressure.normalize_source("storage-ops") == :storage_ops
    assert IOPressure.normalize_source("combined") == :combined
    assert IOPressure.normalize_source("unknown") == :combined
  end
end
