defmodule Maxio.Cluster.DriveIdentityTest do
  use Maxio.DataCase, async: false

  alias Maxio.Cluster.{DriveIdentity, Transport.InProcess}

  setup do
    :ok = InProcess.setup!()

    base =
      Path.join(System.tmp_dir!(), "maxio_drive_identity_#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf(base) end)

    {:ok, base: base}
  end

  test "marker file names are constrained to a file name", %{base: base} do
    drive = Path.join(base, "name-check")

    assert DriveIdentity.marker_file_name(marker_file: ".custom-drive-id.json") ==
             ".custom-drive-id.json"

    assert DriveIdentity.marker_file_name(marker_file: "../outside.json") ==
             DriveIdentity.marker_file_name()

    assert DriveIdentity.marker_path(drive, marker_file: "..\\outside.json") ==
             DriveIdentity.marker_path(drive)
  end

  test "first probe creates a local marker and persisted endpoint identity", %{base: base} do
    drive = Path.join(base, "d0")
    endpoint = {Node.self(), drive}
    File.mkdir_p!(drive)

    assert {:ok, status} =
             DriveIdentity.probe_endpoint(endpoint,
               transport: InProcess,
               set_id: 0,
               endpoint_index: 1,
               now: ~U[2026-06-12 00:00:00.000000Z]
             )

    assert status.endpoint == {Node.self(), Path.expand(drive)}
    assert status.drive_uuid =~ ~r/\A[0-9a-f]{32}\z/
    assert status.generation == 1
    refute status.identity_heal_required?
    refute status.replacement_detected?
    assert File.exists?(DriveIdentity.marker_path(drive))

    assert {:ok, same} =
             DriveIdentity.probe_endpoint(endpoint,
               transport: InProcess,
               set_id: 0,
               endpoint_index: 1,
               now: ~U[2026-06-12 00:01:00.000000Z]
             )

    assert same.drive_uuid == status.drive_uuid
    assert same.generation == 1
    refute same.identity_heal_required?
    refute same.replacement_detected?
  end

  test "same endpoint with a new marker is recorded as a replacement", %{base: base} do
    drive = Path.join(base, "d1")
    endpoint = {Node.self(), drive}
    File.mkdir_p!(drive)

    assert {:ok, first} =
             DriveIdentity.probe_endpoint(endpoint,
               transport: InProcess,
               set_id: 2,
               endpoint_index: 3,
               now: ~U[2026-06-12 00:00:00.000000Z]
             )

    File.rm!(DriveIdentity.marker_path(drive))

    assert {:ok, replacement} =
             DriveIdentity.probe_endpoint(endpoint,
               transport: InProcess,
               set_id: 2,
               endpoint_index: 3,
               now: ~U[2026-06-12 00:02:00.000000Z]
             )

    assert replacement.drive_uuid != first.drive_uuid
    assert replacement.previous_drive_uuid == first.drive_uuid
    assert replacement.generation == 2
    assert replacement.identity_heal_required?
    assert replacement.replacement_detected?

    assert {:ok, cleared} =
             DriveIdentity.clear_heal_required(endpoint, now: ~U[2026-06-12 00:03:00.000000Z])

    refute cleared.identity_heal_required?
    assert cleared.generation == 2
  end

  test "corrupt local marker fails closed without creating persisted state", %{base: base} do
    drive = Path.join(base, "d2")
    endpoint = {Node.self(), drive}
    File.mkdir_p!(drive)
    File.write!(DriveIdentity.marker_path(drive), "not-json")

    assert {:error, {:invalid_identity_marker, _reason}} =
             DriveIdentity.probe_endpoint(endpoint, transport: InProcess)

    assert {:error, :not_found} = DriveIdentity.status(endpoint)
  end

  test "unavailable endpoint does not register identity state", %{base: base} do
    drive = Path.join(base, "d3")
    endpoint = {Node.self(), drive}
    File.mkdir_p!(drive)
    InProcess.set_drive_down(Node.self(), drive)

    assert {:error, :unavailable} =
             DriveIdentity.probe_endpoint(endpoint, transport: InProcess)

    assert {:error, :not_found} = DriveIdentity.status(endpoint)
  end
end
