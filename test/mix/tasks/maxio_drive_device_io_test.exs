defmodule Mix.Tasks.Maxio.Drive.DeviceIoTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Maxio.Cluster.DriveDeviceIO
  alias Mix.Tasks.Maxio.Drive.DeviceIo

  @task "maxio.drive.device_io"

  setup do
    previous_env = Application.get_env(:maxio, :drive_device_io)
    DriveDeviceIO.reset()
    Mix.Task.reenable(@task)

    base =
      Path.join(
        System.tmp_dir!(),
        "maxio_drive_device_io_cli_#{System.unique_integer([:positive])}"
      )

    on_exit(fn ->
      resume_drive_device_io()
      restore_env(previous_env)
      DriveDeviceIO.reset()
      Mix.Task.reenable(@task)
      File.rm_rf(base)
    end)

    {:ok, base: base}
  end

  test "prints local device IO stats with drive flag", %{base: base} do
    drive = Path.join(base, "d0")

    Application.put_env(:maxio, :drive_device_io,
      provider: fn ^drive ->
        {:ok,
         %{
           mount_root: "cli-device-mount",
           device_id: "8:1",
           device_name: "sda1",
           queue_depth: 2,
           busy_percent_x100: 3_000,
           read_bytes_per_sec: 100,
           write_bytes_per_sec: 200,
           ops_per_sec: 5,
           avg_latency_us: 1_000,
           source: :test
         }}
      end
    )

    output = run_task(["--drive", drive])

    assert output =~ "[maxio drive.device_io] status=ok sample_status=ok mode=drive"
    assert output =~ "endpoints=1 ok=1 errors=0 pressure=3"
    assert output =~ "read_bytes_per_sec=100"
    assert output =~ "write_bytes_per_sec=200"
    assert output =~ "[maxio drive.device_io.sample] status=ok"
    assert output =~ "mount_root=\"cli-device-mount\""
    assert output =~ "device_id=\"8:1\""
    assert output =~ "source=test"
  end

  test "cached summary-only suppresses per-drive rows", %{base: base} do
    drive = Path.join(base, "d1")
    owner = Process.whereis(DriveDeviceIO)
    parent = self()

    :ok = :sys.suspend(owner)

    output =
      try do
        :sys.replace_state(owner, fn state ->
          _ =
            DriveDeviceIO.sample_local_drive(drive,
              provider: fn ^drive ->
                send(parent, {:drive_device_io_cache_writer, self()})
                {:ok, %{device_id: "cached-dev", queue_depth: 1}}
              end,
              now_ms: System.monotonic_time(:millisecond)
            )

          state
        end)

        assert_receive {:drive_device_io_cache_writer, writer}
        assert writer == owner

        run_task(["--cached", "--summary-only"])
      after
        :ok = :sys.resume(owner)
      end

    assert %{enabled?: true} = :sys.get_state(owner)
    assert output =~ "[maxio drive.device_io] status=ok sample_status=ok mode=cached"
    assert output =~ "pressure=1"
    refute output =~ "[maxio drive.device_io.sample]"
  end

  test "reset clears cached pressure before printing cached summary", %{base: base} do
    drive = Path.join(base, "d2")

    _ =
      DriveDeviceIO.sample_local_drive(drive,
        provider: fn ^drive -> {:ok, %{device_id: "reset-dev", queue_depth: 2}} end,
        now_ms: System.monotonic_time(:millisecond)
      )

    output = run_task(["--cached", "--summary-only", "--reset"])

    assert output =~ "[maxio drive.device_io] status=reset sample_status=no_topology mode=cached"
    assert output =~ "pressure=0"
  end

  test "invalid args raise usage" do
    assert_raise Mix.Error, ~r/usage: mix maxio\.drive\.device_io/, fn ->
      DeviceIo.run(["unexpected"])
    end
  end

  defp run_task(args) do
    Mix.Task.reenable(@task)
    capture_io(fn -> DeviceIo.run(args) end)
  end

  defp resume_drive_device_io do
    case Process.whereis(DriveDeviceIO) do
      nil -> :ok
      pid -> :sys.resume(pid)
    end
  catch
    :exit, _reason -> :ok
  end

  defp restore_env(nil), do: Application.delete_env(:maxio, :drive_device_io)
  defp restore_env(value), do: Application.put_env(:maxio, :drive_device_io, value)
end
