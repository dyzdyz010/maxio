defmodule Mix.Tasks.Maxio.Drive.IdentitiesTest do
  use Maxio.DataCase, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Maxio.Drive.Identities
  alias Maxio.Cluster.{DriveIdentity, Topology, Transport.InProcess}

  @task "maxio.drive.identities"

  setup do
    :ok = InProcess.setup!()

    base =
      Path.join(
        System.tmp_dir!(),
        "maxio_drive_identities_cli_#{System.unique_integer([:positive])}"
      )

    prev_transport = Application.get_env(:maxio, :shard_transport)
    topo_key = {Topology, :topology}
    prev_topology = :persistent_term.get(topo_key, :__maxio_no_topology__)

    Application.put_env(:maxio, :shard_transport, InProcess)
    :persistent_term.erase(topo_key)
    Mix.Task.reenable(@task)

    on_exit(fn ->
      restore_env(:shard_transport, prev_transport)
      restore_topology(prev_topology)
      File.rm_rf(base)
      Mix.Task.reenable(@task)
    end)

    {:ok, base: base}
  end

  test "prints persisted identity inventory", %{base: base} do
    drive = Path.join(base, "d0")
    uuid = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

    assert {:ok, _status} =
             DriveIdentity.register_observation({Node.self(), drive}, %{drive_uuid: uuid},
               set_id: 0,
               endpoint_index: 1,
               now: ~U[2026-06-13 00:00:00.000000Z]
             )

    output = run_task([])

    assert output =~ "[maxio drive.identities] status=ok mode=snapshot"
    assert output =~ "total=1"
    assert output =~ "heal_required=0"
    assert output =~ "replacements=0"
    assert output =~ "[maxio drive.identity] status=ok"
    assert output =~ "drive=#{inspect(Path.expand(drive))}"
    assert output =~ "drive_uuid=#{uuid}"
    assert output =~ "generation=1"
    assert output =~ "last_seen_at=2026-06-13T00:00:00.000000Z"
  end

  test "filters heal-required rows and supports summary-only", %{base: base} do
    stable_drive = Path.join(base, "stable")
    replaced_drive = Path.join(base, "replaced")

    assert {:ok, _status} =
             DriveIdentity.register_observation(
               {Node.self(), stable_drive},
               %{drive_uuid: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"},
               set_id: 0,
               endpoint_index: 0
             )

    assert {:ok, _first} =
             DriveIdentity.register_observation(
               {Node.self(), replaced_drive},
               %{drive_uuid: "cccccccccccccccccccccccccccccccc"},
               set_id: 0,
               endpoint_index: 1
             )

    assert {:ok, _replacement} =
             DriveIdentity.register_observation(
               {Node.self(), replaced_drive},
               %{drive_uuid: "dddddddddddddddddddddddddddddddd"},
               set_id: 0,
               endpoint_index: 1
             )

    output = run_task(["--heal-required"])

    assert output =~ "total=1"
    assert output =~ "heal_required=1"
    assert output =~ "replacements=1"
    assert output =~ "drive=#{inspect(Path.expand(replaced_drive))}"
    assert output =~ "replaced=true"
    refute output =~ "drive=#{inspect(Path.expand(stable_drive))}"

    summary = run_task(["--heal-required", "--summary-only"])

    assert summary =~ "total=1"
    refute summary =~ "[maxio drive.identity] status=ok"
  end

  test "probe walks configured topology and creates missing markers", %{base: base} do
    drives = [Path.join(base, "p0"), Path.join(base, "p1")]
    Enum.each(drives, &File.mkdir_p!/1)
    put_topology(Enum.map(drives, &{Node.self(), &1}))

    output = run_task(["--probe"])

    assert output =~ "[maxio drive.identities] status=ok mode=probe"
    assert output =~ "topology_sets=1"
    assert output =~ "endpoints=2"
    assert output =~ "probed=2"
    assert output =~ "ok=2"
    assert output =~ "errors=0"
    assert output =~ "total=2"

    assert Enum.all?(drives, fn drive -> File.exists?(DriveIdentity.marker_path(drive)) end)
  end

  test "probe supports custom marker file names", %{base: base} do
    marker_file = ".custom-drive-id.json"
    drives = [Path.join(base, "custom0"), Path.join(base, "custom1")]
    Enum.each(drives, &File.mkdir_p!/1)
    put_topology(Enum.map(drives, &{Node.self(), &1}))

    output = run_task(["--probe", "--marker-file", marker_file])

    assert output =~ "[maxio drive.identities] status=ok mode=probe"
    assert output =~ "total=2"

    assert Enum.all?(drives, fn drive ->
             File.exists?(DriveIdentity.marker_path(drive, marker_file: marker_file))
           end)

    refute Enum.any?(drives, fn drive -> File.exists?(DriveIdentity.marker_path(drive)) end)
  end

  test "probe can refuse missing marker creation", %{base: base} do
    drives = [Path.join(base, "readonly0"), Path.join(base, "readonly1")]
    Enum.each(drives, &File.mkdir_p!/1)
    put_topology(Enum.map(drives, &{Node.self(), &1}))

    output = run_task(["--probe", "--no-create-missing"])

    assert output =~ "[maxio drive.identities] status=partial mode=probe"
    assert output =~ "probed=2"
    assert output =~ "ok=0"
    assert output =~ "errors=2"
    assert output =~ "total=0"
    assert output =~ "[maxio drive.identity] status=error"
    assert output =~ "reason=:missing_identity"
    refute Enum.any?(drives, fn drive -> File.exists?(DriveIdentity.marker_path(drive)) end)
  end

  test "probe reports corrupt marker without replacing it", %{base: base} do
    drives = [Path.join(base, "corrupt0"), Path.join(base, "corrupt1")]
    Enum.each(drives, &File.mkdir_p!/1)
    marker_path = DriveIdentity.marker_path(hd(drives))
    Enum.each(drives, fn drive -> File.write!(DriveIdentity.marker_path(drive), "not-json") end)
    put_topology(Enum.map(drives, &{Node.self(), &1}))

    output = run_task(["--probe"])

    assert output =~ "[maxio drive.identities] status=partial mode=probe"
    assert output =~ "errors=2"
    assert output =~ "total=0"
    assert output =~ "invalid_identity_marker"
    assert File.read!(marker_path) == "not-json"
  end

  test "probe without topology is explicit", %{base: _base} do
    output = run_task(["--probe"])

    assert output =~ "[maxio drive.identities] status=no_topology mode=probe"
    assert output =~ "topology_sets=0"
    assert output =~ "endpoints=0"
    assert output =~ "probed=0"
  end

  test "invalid args raise usage" do
    assert_raise Mix.Error, ~r/usage: mix maxio\.drive\.identities/, fn ->
      Identities.run(["unexpected"])
    end
  end

  test "invalid marker file path fragments raise" do
    assert_raise Mix.Error, ~r/invalid --marker-file/, fn ->
      Identities.run(["--probe", "--marker-file", "../escape.json"])
    end

    assert_raise Mix.Error, ~r/invalid --marker-file/, fn ->
      Identities.run(["--probe", "--marker-file", "..\\escape.json"])
    end
  end

  defp run_task(args) do
    Mix.Task.reenable(@task)
    capture_io(fn -> Identities.run(args) end)
  end

  defp put_topology(endpoints) do
    topology =
      Topology.parse_and_validate!(
        data_shards: 1,
        parity_shards: 1,
        block_size: 1024,
        allow_colocated_endpoints: true,
        pools: [%{id: 0, sets: [%{id: 0, endpoints: endpoints}]}]
      )

    :persistent_term.put({Topology, :topology}, topology)
  end

  defp restore_topology(:__maxio_no_topology__), do: :persistent_term.erase({Topology, :topology})
  defp restore_topology(topology), do: :persistent_term.put({Topology, :topology}, topology)

  defp restore_env(key, nil), do: Application.delete_env(:maxio, key)
  defp restore_env(key, value), do: Application.put_env(:maxio, key, value)
end
