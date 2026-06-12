defmodule Mix.Tasks.Maxio.Drive.IoTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Maxio.Cluster.DriveIO
  alias Mix.Tasks.Maxio.Drive.Io

  @task "maxio.drive.io"

  setup do
    DriveIO.reset()
    Mix.Task.reenable(@task)

    on_exit(fn ->
      DriveIO.reset()
      Mix.Task.reenable(@task)
    end)
  end

  test "prints node-local drive IO telemetry" do
    assert :ok = DriveIO.track(:write, fn -> :ok end, bytes: 11)

    output = run_task([])

    assert output =~ "[maxio drive.io] status=ok"
    assert output =~ "active_ops=0"
    assert output =~ "write_ops=1"
    assert output =~ "completed_ops=1"
    assert output =~ "bytes_written=11"
    assert output =~ "avg_latency_us="
    assert output =~ "max_latency_us="
    assert output =~ "throughput_bytes_per_sec="
    assert output =~ "read_throughput_bytes_per_sec="
    assert output =~ "write_throughput_bytes_per_sec="
  end

  test "reset flag clears counters before printing" do
    assert "abc" =
             DriveIO.track(:read, fn -> "abc" end, bytes: fn result -> byte_size(result) end)

    output = run_task(["--reset"])

    assert output =~ "[maxio drive.io] status=reset"
    assert output =~ "read_ops=0"
    assert output =~ "completed_ops=0"
    assert output =~ "bytes_read=0"
  end

  test "invalid args raise usage" do
    assert_raise Mix.Error, ~r/usage: mix maxio\.drive\.io/, fn ->
      Io.run(["unexpected"])
    end
  end

  defp run_task(args) do
    Mix.Task.reenable(@task)
    capture_io(fn -> Io.run(args) end)
  end
end
