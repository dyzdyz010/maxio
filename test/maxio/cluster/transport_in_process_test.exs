defmodule Maxio.Cluster.TransportInProcessTest do
  use ExUnit.Case, async: false
  alias Maxio.Cluster.Paths
  alias Maxio.Cluster.Transport.Erpc
  alias Maxio.Cluster.Transport.InProcess
  alias Maxio.Storage.{EpochStore, ObjectEpoch}

  setup do
    InProcess.setup!()
    base = Path.join(System.tmp_dir!(), "maxio_inproc_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(base) end)
    {:ok, base: base}
  end

  test "put/get round-trip 经端点映射", %{base: base} do
    dir = Path.join(base, "n0_d0/b/k")
    s = :crypto.strong_rand_bytes(256)
    assert :ok = InProcess.put_shard(:maxio@n0, dir, 0, s, 256)
    assert InProcess.get_shard(:maxio@n0, dir, 0, 256) == s
  end

  test "打掉端点 -> get nil、put {:error,:unavailable}", %{base: base} do
    dir = Path.join(base, "n1_d0/b/k")
    s = :crypto.strong_rand_bytes(256)
    assert :ok = InProcess.put_shard(:maxio@n1, dir, 0, s, 256)
    InProcess.set_down(:maxio@n1)
    assert InProcess.get_shard(:maxio@n1, dir, 0, 256) == nil
    assert {:error, :unavailable} = InProcess.put_shard(:maxio@n1, dir, 0, s, 256)
    InProcess.set_up(:maxio@n1)
    assert InProcess.get_shard(:maxio@n1, dir, 0, 256) == s
  end

  test "sidecar 在宕机端点回 :unavailable", %{base: base} do
    dir = Path.join(base, "n2_d0/b/k")
    :ok = InProcess.put_sidecar(:maxio@n2, dir, %{"size" => 1})
    InProcess.set_down(:maxio@n2)
    assert {:error, :unavailable} = InProcess.get_sidecar(:maxio@n2, dir)
  end

  test "verify_mutation freezes the same endpoint identity across success and outage", %{
    base: base
  } do
    node = :maxio@n2

    for {name, layout, endpoint} <- [
          {"fs", %{kind: "fs"}, "local"},
          {"shard", %{kind: "shard", index: 1}, "ordinal:1"}
        ] do
      drive = Path.join(base, "proof-drive-#{name}")
      request = published_proof_request!(drive, "key-#{name}", layout)

      assert {:ok,
              {:verified,
               %{
                 "scope" => "endpoint",
                 "mode" => "proof",
                 "status" => "verified",
                 "endpoint" => ^endpoint,
                 "owned" => true
               }}} = InProcess.verify_mutation(node, drive, request)

      InProcess.set_drive_down(node, drive)

      assert {:error,
              {:published_proof_failed, :unavailable,
               %{
                 "scope" => "endpoint",
                 "mode" => "proof",
                 "status" => "failed",
                 "endpoint" => ^endpoint,
                 "owned" => false
               }}} = InProcess.verify_mutation(node, drive, request)

      InProcess.set_drive_up(node, drive)
    end
  end

  test "erpc outage evidence uses layout identity instead of node or drive path" do
    unreachable = :maxio_proof_unreachable@localhost

    for {layout, endpoint} <- [
          {%{kind: "fs"}, "local"},
          {%{kind: "shard", index: 7}, "ordinal:7"}
        ] do
      assert {:error,
              {:published_proof_failed, :unavailable,
               %{
                 "scope" => "endpoint",
                 "mode" => "proof",
                 "status" => "failed",
                 "endpoint" => ^endpoint,
                 "owned" => false
               } = summary}} =
               Erpc.verify_mutation(unreachable, "private-drive-path", %{layout: layout})

      refute Map.has_key?(summary, "node")
      refute Map.has_key?(summary, "path")
    end
  end

  test "erpc normalizes exceptions from local direct apply" do
    assert nil == Erpc.get_shard(Node.self(), nil, 0, 1)
  end

  test "move_shard moves directories and reports unavailable drives", %{base: base} do
    node = :maxio@n2
    drive = Path.join(base, "n2_d1")
    source = Path.join(drive, "b/k")
    destination = Path.join(drive, ".tmp/backup")

    :ok = InProcess.put_sidecar(node, source, %{"size" => 1})
    assert :ok = InProcess.move_shard(node, source, destination)
    assert {:error, :enoent} = InProcess.get_sidecar(node, source)
    assert {:ok, %{"size" => 1}} = InProcess.get_sidecar(node, destination)
    assert {:error, :enoent} = InProcess.move_shard(node, source, destination)

    InProcess.set_drive_down(node, drive)
    assert {:error, :unavailable} = InProcess.move_shard(node, destination, source)
  end

  test "drive-level outage leaves sibling drives on the same node reachable", %{base: base} do
    node = :maxio@n3
    drive0 = Path.join(base, "n3_d0")
    drive1 = Path.join(base, "n3_d1")
    dir0 = Path.join(drive0, "b/k0")
    dir1 = Path.join(drive1, "b/k1")
    shard = :crypto.strong_rand_bytes(128)

    File.mkdir_p!(drive0)
    File.mkdir_p!(drive1)
    assert :ok = InProcess.put_shard(node, dir0, 0, shard, 128)
    assert :ok = InProcess.put_shard(node, dir1, 0, shard, 128)

    InProcess.set_drive_down(node, drive0)

    assert {:error, :unavailable} = InProcess.list_dir(node, drive0, [])
    assert {:ok, _entries} = InProcess.list_dir(node, drive1, [])
    assert InProcess.get_shard(node, dir0, 0, 128) == nil
    assert InProcess.get_shard(node, dir1, 0, 128) == shard

    InProcess.set_drive_up(node, drive0)
    assert InProcess.get_shard(node, dir0, 0, 128) == shard
  end

  test "pressure snapshot injection follows node down state" do
    node = :maxio@n4

    InProcess.set_pressure_snapshot(node, %{s3_in_flight: 1, storage_ops: 2})

    assert {:ok, %{s3_in_flight: 1, storage_ops: 2, combined: 3}} =
             InProcess.pressure_snapshot(node)

    InProcess.set_down(node)

    assert {:error, :unavailable} = InProcess.pressure_snapshot(node)
  end

  test "drive identity probe creates a stable marker and follows drive down state", %{base: base} do
    node = :maxio@n5
    drive = Path.join(base, "n5_d0")
    File.mkdir_p!(drive)

    assert {:ok, %{drive_uuid: drive_uuid}} = InProcess.probe_drive_identity(node, drive)
    assert drive_uuid =~ ~r/\A[0-9a-f]{32}\z/
    assert {:ok, %{drive_uuid: ^drive_uuid}} = InProcess.probe_drive_identity(node, drive)

    InProcess.set_drive_down(node, drive)
    assert {:error, :unavailable} = InProcess.probe_drive_identity(node, drive)
  end

  test "drive hardware evidence follows drive down state", %{base: base} do
    node = :maxio@n6
    drive = Path.join(base, "n6_d0")
    File.mkdir_p!(drive)

    provider = fn ^drive ->
      {:ok,
       %{
         mount_root: "hardware-mount",
         major_minor: "8:1",
         block_device: "sda1",
         source: :test
       }}
    end

    assert {:ok, %{mount_root: "hardware-mount", block_device: "sda1"}} =
             InProcess.drive_hardware_evidence(node, drive, provider: provider)

    InProcess.set_drive_down(node, drive)

    assert {:error, :unavailable} =
             InProcess.drive_hardware_evidence(node, drive, provider: provider)
  end

  test "drive stats follow drive down state", %{base: base} do
    node = :maxio@n7
    drive = Path.join(base, "n7_d0")
    File.mkdir_p!(drive)

    provider = fn ^drive ->
      {:ok,
       %{
         mount_root: "test-mount",
         capacity_bytes: 1_000,
         free_bytes: 300,
         source: :test,
         precision: :exact
       }}
    end

    assert {:ok, %{capacity_bytes: 1_000, free_bytes: 300}} =
             InProcess.drive_stats(node, drive, provider: provider)

    InProcess.set_drive_down(node, drive)
    assert {:error, :unavailable} = InProcess.drive_stats(node, drive, provider: provider)
  end

  test "strict layout quarantine follows drive down state", %{base: base} do
    node = :maxio@n8
    drive = Path.join(base, "n8_d0")
    File.mkdir_p!(Path.join(drive, "bucket-a"))

    InProcess.set_drive_down(node, drive)

    assert {:error, :unavailable} =
             InProcess.quarantine_layout_roots(node, drive, ["bucket-a"], "q-1", %{})
  end

  defp published_proof_request!(drive, key, layout) do
    {:ok, target} = ObjectEpoch.object_target("inprocess-proof", key, "null")
    {:ok, final_rel} = Paths.object_rel("inprocess-proof", key, "null")
    {:ok, token} = ObjectEpoch.token(1, "00000000-0000-0000-0000-00000000000a")

    sidecar =
      %{
        "format" => "maxio/2",
        "etag" => "etag",
        "size" => 4,
        "sha256" => String.duplicate("a", 64),
        "versions" => [%{"version_id" => "null", "type" => "object"}]
      }
      |> maybe_put_shards(layout)

    raw_meta = Jason.encode!(sidecar)
    fingerprint = ObjectEpoch.fingerprint("etag", 4, raw_meta)

    {:ok, epoch} =
      ObjectEpoch.new(target, token, %{
        operation: "put",
        phase: "published",
        value_type: "object",
        fingerprint: fingerprint,
        updated_at: DateTime.utc_now()
      })

    final_dir = Path.join(drive, final_rel)
    File.mkdir_p!(final_dir)
    File.write!(Path.join(final_dir, "part.0"), "data")
    File.write!(Path.join(final_dir, "meta.json"), raw_meta)
    assert {:ok, :applied} = EpochStore.cas(drive, epoch, {:claim, token})

    %{
      target: target,
      token: token,
      mutation_id: token["mutation_id"],
      final_rel: final_rel,
      expected_fingerprint: fingerprint,
      layout: layout
    }
  end

  defp maybe_put_shards(sidecar, %{kind: "fs"}), do: sidecar

  defp maybe_put_shards(sidecar, %{kind: "shard"}) do
    Map.put(sidecar, "shards", [
      %{"drive" => 0, "shard_file_size" => 4, "block_hashes" => []},
      %{"drive" => 1, "shard_file_size" => 4, "block_hashes" => []}
    ])
  end
end
