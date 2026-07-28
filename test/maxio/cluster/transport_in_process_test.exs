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

  # --- Task 2 R1：Transport / InProcess endpoint union RED ---

  @tag :task2_red_endpoint
  test "task2 red: InProcess finalize_mutation returns the endpoint union bound to the captured ordinal",
       %{base: base} do
    node = :maxio@n2

    for {name, layout, endpoint} <- [
          {"fs", %{kind: "fs"}, "local"},
          {"shard", %{kind: "shard", index: 1}, "ordinal:1"}
        ] do
      drive = Path.join(base, "t2-finalize-drive-#{name}")
      request = published_proof_request!(drive, "t2-key-#{name}", layout)

      assert {:ok,
              {:finalized,
               %{
                 "scope" => "endpoint",
                 "mode" => "finalize",
                 "status" => "finalized",
                 "endpoint" => ^endpoint,
                 "owned" => true,
                 "proof_passed" => true,
                 "finalized" => true
               }}} = InProcess.finalize_mutation(node, drive, request)

      # 端点不可用时仍绑定捕获到的 ordinal，成为该 ordinal 的 unavailable。
      InProcess.set_drive_down(node, drive)

      assert {:error,
              {:published_proof_failed, :unavailable,
               %{
                 "scope" => "endpoint",
                 "mode" => "finalize",
                 "status" => "failed",
                 "endpoint" => ^endpoint,
                 "owned" => false
               }}} = InProcess.finalize_mutation(node, drive, request)

      InProcess.set_drive_up(node, drive)
    end
  end

  @tag :task2_red_endpoint
  test "task2 red: erpc finalize outage binds the captured ordinal without node or drive paths" do
    unreachable = :maxio_proof_unreachable@localhost

    for {layout, endpoint} <- [
          {%{kind: "fs"}, "local"},
          {%{kind: "shard", index: 5}, "ordinal:5"}
        ] do
      assert {:error,
              {:published_proof_failed, :unavailable,
               %{
                 "scope" => "endpoint",
                 "mode" => "finalize",
                 "status" => "failed",
                 "endpoint" => ^endpoint,
                 "owned" => false
               } = summary}} =
               Erpc.finalize_mutation(unreachable, "private-drive-path", %{layout: layout})

      refute Map.has_key?(summary, "node")
      refute Map.has_key?(summary, "path")
      refute inspect(summary) =~ "private-drive-path"
    end
  end

  @tag :task2_red_endpoint
  test "task2 control: verify outage evidence already binds the captured ordinal", %{base: base} do
    node = :maxio@n2
    drive = Path.join(base, "t2-control-drive")
    request = published_proof_request!(drive, "t2-control-key", %{kind: "shard", index: 2})

    InProcess.set_drive_down(node, drive)

    assert {:error,
            {:published_proof_failed, :unavailable,
             %{"endpoint" => "ordinal:2", "mode" => "proof", "owned" => false} = summary}} =
             InProcess.verify_mutation(node, drive, request)

    refute Map.has_key?(summary, "node")
    refute Map.has_key?(summary, "path")
    refute inspect(summary) =~ drive

    InProcess.set_drive_up(node, drive)
  end

  @tag :task2_red_endpoint
  test "task2 red: transport normalizes non-envelope wire returns to captured-identity unavailable" do
    alias Maxio.Cluster.Transport

    for {layout, endpoint} <- [
          {%{kind: "fs"}, "local"},
          {%{kind: "shard", index: 4}, "ordinal:4"}
        ] do
      request = %{layout: layout}

      # 完全不具 endpoint wire envelope 的正常返回：旧 tuple、裸原子、裸错误。
      for wire <- [
            :bogus,
            {:ok, :finalized},
            {:ok, :superseded},
            {:error, :unavailable},
            {:error, {:unexpected_epoch_phase, "claimed"}},
            nil
          ] do
        assert {:error,
                {:published_proof_failed, :unavailable,
                 %{
                   "scope" => "endpoint",
                   "mode" => "proof",
                   "status" => "failed",
                   "endpoint" => ^endpoint,
                   "owned" => false
                 } = proof}} = Transport.normalize_mutation_proof(request, wire)

        assert {:error,
                {:published_proof_failed, :unavailable,
                 %{
                   "scope" => "endpoint",
                   "mode" => "finalize",
                   "status" => "failed",
                   "endpoint" => ^endpoint,
                   "owned" => false,
                   "proof_passed" => false,
                   "finalized" => false
                 } = finalize}} = Transport.normalize_mutation_finalize(request, wire)

        # raw term / reason 绝不外泄。
        for summary <- [proof, finalize] do
          refute Map.has_key?(summary, "node")
          refute Map.has_key?(summary, "path")
          refute inspect(summary) =~ "bogus"
          refute inspect(summary) =~ "unexpected_epoch_phase"
        end
      end
    end
  end

  @tag :task2_red_endpoint
  test "task2 red: transport lazy call boundary contains raise, exit, throw and pre-RPC faults" do
    alias Maxio.Cluster.Transport

    for {layout, endpoint} <- [
          {%{kind: "fs"}, "local"},
          {%{kind: "shard", index: 6}, "ordinal:6"}
        ] do
      request = %{layout: layout}

      faults = [
        fn -> raise "boom-secret-/private/drive/path" end,
        fn -> exit({:shutdown, "exit-secret-/private/drive/path"}) end,
        fn -> throw({:thrown, "throw-secret-/private/drive/path"}) end,
        # pre-RPC failure：连 outage 判定本身都在闭包内炸掉。
        fn -> Path.expand(nil) end
      ]

      for fault <- faults do
        assert {:error,
                {:published_proof_failed, :unavailable,
                 %{
                   "scope" => "endpoint",
                   "mode" => "proof",
                   "status" => "failed",
                   "endpoint" => ^endpoint,
                   "owned" => false
                 } = proof}} = Transport.call_mutation_proof(request, fault)

        assert {:error,
                {:published_proof_failed, :unavailable,
                 %{
                   "scope" => "endpoint",
                   "mode" => "finalize",
                   "status" => "failed",
                   "endpoint" => ^endpoint,
                   "owned" => false,
                   "proof_passed" => false,
                   "finalized" => false
                 } = finalize}} = Transport.call_mutation_finalize(request, fault)

        for summary <- [proof, finalize] do
          rendered = inspect(summary)
          refute rendered =~ "secret"
          refute rendered =~ "private"
          refute Map.has_key?(summary, "node")
          refute Map.has_key?(summary, "path")
        end
      end

      # 闭包内的正常 term 仍交既有 outer-envelope normalizer：合法值逐字透传。
      legal = Maxio.Storage.PublishedProof.verified(endpoint, %{})
      assert Transport.call_mutation_proof(request, fn -> legal end) === legal
    end
  end

  @tag :task2_red_endpoint
  test "task2 red: transport passes endpoint-envelope terms through untouched for the classifier" do
    alias Maxio.Cluster.Transport
    alias Maxio.Storage.PublishedProof

    request = %{layout: %{kind: "shard", index: 4}}

    # outer envelope 合法但内部 identity/scope/mode/outcome/status/class/count 伪造，
    # 或 aggregate 重入：Transport 必须原样透传，由公共 classifier 判成 placement_drift。
    forged_identity =
      {:ok,
       {:verified,
        %{
          "scope" => "endpoint",
          "mode" => "proof",
          "endpoint" => "ordinal:9",
          "status" => "verified",
          "owned" => true
        }}}

    forged_counts =
      {:ok,
       {:verified,
        %{
          "scope" => "endpoint",
          "mode" => "proof",
          "endpoint" => "ordinal:4",
          "status" => "verified",
          "owned" => true,
          "verified" => 9
        }}}

    forged_outcome =
      {:ok,
       {:degraded,
        %{
          "scope" => "endpoint",
          "mode" => "proof",
          "endpoint" => "ordinal:4",
          "status" => "verified",
          "owned" => true
        }}}

    forged_class =
      {:error,
       {:published_proof_failed, :mismatch,
        %{
          "scope" => "endpoint",
          "mode" => "proof",
          "endpoint" => "ordinal:4",
          "status" => "failed",
          "owned" => true,
          "class" => "corrupt"
        }}}

    {:ok, {:verified, aggregate}} =
      PublishedProof.classify(1, [{"local", PublishedProof.verified("local", %{})}])

    aggregate_reentry = {:ok, {:verified, aggregate}}

    forged = [forged_identity, forged_counts, forged_outcome, forged_class, aggregate_reentry]

    for wire <- forged do
      assert Transport.normalize_mutation_proof(request, wire) === wire
    end

    # 合法 endpoint 结果同样 term-identical 透传。
    legal = PublishedProof.verified("ordinal:4", %{})
    assert Transport.normalize_mutation_proof(request, legal) === legal

    legal_finalize = PublishedProof.endpoint_finalize_superseded("ordinal:4")
    assert Transport.normalize_mutation_finalize(request, legal_finalize) === legal_finalize

    # 透传后由公共 classifier 收口为 placement_drift，Transport 不复制语义校验。
    for wire <- forged do
      assert {:error, {:published_proof_failed, :placement_drift, _summary}} =
               PublishedProof.classify(1, [{"ordinal:4", wire}])
    end
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
