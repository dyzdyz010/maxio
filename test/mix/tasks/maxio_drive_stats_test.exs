defmodule Mix.Tasks.Maxio.Drive.StatsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Maxio.Drive.Stats

  @task "maxio.drive.stats"

  setup do
    old_env = Application.get_env(:maxio, :drive_stats)
    Mix.Task.reenable(@task)

    base =
      Path.join(System.tmp_dir!(), "maxio_drive_stats_cli_#{System.unique_integer([:positive])}")

    on_exit(fn ->
      restore_env(old_env)
      Mix.Task.reenable(@task)
      File.rm_rf(base)
    end)

    {:ok, base: base}
  end

  test "prints local drive stats with drive flag", %{base: base} do
    drive = Path.join(base, "d0")

    Application.put_env(:maxio, :drive_stats,
      provider: fn ^drive ->
        {:ok,
         %{
           mount_root: "cli-mount",
           capacity_bytes: 10_000,
           free_bytes: 2_500,
           source: :test,
           precision: :exact
         }}
      end
    )

    output = run_task(["--drive", drive])

    assert output =~ "[maxio drive.stats] status=ok mode=drive"
    assert output =~ "endpoints=1 ok=1 errors=0"
    assert output =~ "capacity_bytes=10000"
    assert output =~ "free_bytes=2500"
    assert output =~ "[maxio drive.stat] status=ok"
    assert output =~ "mount_root=\"cli-mount\""
    assert output =~ "source=test precision=exact"
  end

  test "summary-only suppresses per-drive rows", %{base: base} do
    drive = Path.join(base, "d1")

    Application.put_env(:maxio, :drive_stats,
      provider: fn ^drive ->
        {:ok,
         %{
           mount_root: "cli-mount",
           capacity_bytes: 1_000,
           free_bytes: 500,
           source: :test,
           precision: :exact
         }}
      end
    )

    output = run_task(["--drive", drive, "--summary-only"])

    assert output =~ "[maxio drive.stats] status=ok mode=drive"
    refute output =~ "[maxio drive.stat]"
  end

  test "prints no_topology without drive flag when topology is absent" do
    output = run_task(["--summary-only"])

    assert output =~ "[maxio drive.stats] status=no_topology mode=topology"
    assert output =~ "topology_sets=0 endpoints=0 ok=0 errors=0"
  end

  test "invalid args raise usage" do
    assert_raise Mix.Error, ~r/usage: mix maxio\.drive\.stats/, fn ->
      Stats.run(["unexpected"])
    end
  end

  defp run_task(args) do
    Mix.Task.reenable(@task)
    capture_io(fn -> Stats.run(args) end)
  end

  defp restore_env(nil), do: Application.delete_env(:maxio, :drive_stats)
  defp restore_env(value), do: Application.put_env(:maxio, :drive_stats, value)
end
