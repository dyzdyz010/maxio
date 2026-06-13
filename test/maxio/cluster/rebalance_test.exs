defmodule Maxio.Cluster.RebalanceTest do
  use Maxio.DataCase, async: true

  alias Maxio.{Buckets, Objects}
  alias Maxio.Cluster.{Rebalance, Router, Topology}

  @owner "arn:aws:iam:::root"

  test "returns no_topology without scanning object metadata" do
    {:ok, report} = Rebalance.plan(topology: nil, include_drive_stats: false)

    assert report.status == :no_topology
    assert report.topology_sets == 0
    assert report.scanned == 0
    assert report.per_set == []
    assert :no_topology in report.warnings
  end

  test "accounts all versions and delete markers by routed set with pagination" do
    topology = topology()
    bucket = bucket_name("rebalance-all")
    {:ok, _bucket} = Buckets.create(bucket, @owner)

    key0 = key_for_set(bucket, topology, 0, "target")
    key1 = key_for_set(bucket, topology, 1, "other")

    {:ok, _} = Objects.put_version_with_id(bucket, key0, "01", %{size: 10, etag: "e10"})
    {:ok, _} = Objects.put_version_with_id(bucket, key0, "02", %{size: 20, etag: "e20"})
    {:ok, _} = Objects.put_version_with_id(bucket, key1, "01", %{size: 7, etag: "e7"})
    {:ok, _} = Objects.insert_delete_marker_with_id(bucket, key1, "02")

    {:ok, report} =
      Rebalance.plan(
        topology: topology,
        page_size: 1,
        include_drive_stats: false,
        decommission_set: 0
      )

    assert report.status == :ok
    assert report.scope == :versions
    assert report.buckets == 1
    assert report.pages >= 4
    assert report.scanned == 4
    assert report.objects == 3
    assert report.versions == 4
    assert report.delete_markers == 1
    assert report.placement_fallbacks == 4
    assert report.bytes == 37

    per_set = Map.new(report.per_set, &{&1.set_id, &1})

    assert Map.fetch!(per_set[0], :target?)
    assert per_set[0].objects == 2
    assert per_set[0].versions == 2
    assert per_set[0].delete_markers == 0
    assert per_set[0].placement_fallbacks == 2
    assert per_set[0].bytes == 30

    refute Map.fetch!(per_set[1], :target?)
    assert per_set[1].objects == 1
    assert per_set[1].versions == 2
    assert per_set[1].delete_markers == 1
    assert per_set[1].placement_fallbacks == 2
    assert per_set[1].bytes == 7

    assert report.decommission.set_id == 0
    assert report.decommission.objects == 2
    assert report.decommission.versions == 2
    assert report.decommission.bytes == 30
  end

  test "current_only counts only latest non-delete object rows" do
    topology = topology()
    bucket = bucket_name("rebalance-current")
    {:ok, _bucket} = Buckets.create(bucket, @owner)

    key0 = key_for_set(bucket, topology, 0, "live")
    key1 = key_for_set(bucket, topology, 1, "deleted")

    {:ok, _} = Objects.put_version_with_id(bucket, key0, "01", %{size: 10, etag: "e10"})
    {:ok, _} = Objects.put_version_with_id(bucket, key0, "02", %{size: 20, etag: "e20"})
    {:ok, _} = Objects.put_version_with_id(bucket, key1, "01", %{size: 7, etag: "e7"})
    {:ok, _} = Objects.insert_delete_marker_with_id(bucket, key1, "02")

    {:ok, report} =
      Rebalance.plan(topology: topology, current_only: true, include_drive_stats: false)

    assert report.scope == :current_only
    assert report.scanned == 1
    assert report.objects == 1
    assert report.versions == 1
    assert report.delete_markers == 0
    assert report.placement_fallbacks == 1
    assert report.bytes == 20
  end

  test "planner prefers persisted placement before falling back to current router" do
    topology = topology()
    bucket = bucket_name("rebalance-placement")
    {:ok, _bucket} = Buckets.create(bucket, @owner)

    key_hashes_to_zero = key_for_set(bucket, topology, 0, "hash-zero")
    key_hashes_to_one = key_for_set(bucket, topology, 1, "hash-one")

    {:ok, _} =
      Objects.put_version_with_id(bucket, key_hashes_to_zero, "01", %{
        size: 12,
        etag: "e12",
        placement_set_id: 1,
        placement_topology_hash: "historical"
      })

    {:ok, _} =
      Objects.put_version_with_id(bucket, key_hashes_to_one, "01", %{size: 5, etag: "e5"})

    {:ok, report} =
      Rebalance.plan(topology: topology, include_drive_stats: false, decommission_set: 1)

    per_set = Map.new(report.per_set, &{&1.set_id, &1})

    assert report.scanned == 2
    assert report.placement_fallbacks == 1
    assert per_set[0].objects == 0
    assert per_set[0].bytes == 0
    assert per_set[0].placement_fallbacks == 0
    assert per_set[1].objects == 2
    assert per_set[1].bytes == 17
    assert per_set[1].placement_fallbacks == 1
    assert report.decommission.objects == 2
    assert report.decommission.bytes == 17
    assert report.decommission.placement_fallbacks == 1
  end

  test "partial drive stats are surfaced without hiding inventory totals" do
    topology = topology()

    drive_stats = %{
      status: :partial,
      topology_sets: 2,
      endpoints: 4,
      ok: 1,
      errors: 1,
      capacity_bytes: 1_000,
      free_bytes: 250,
      used_bytes: 750,
      min_free_bytes: 250,
      min_free_percent_x100: 2_500,
      samples: [
        %{
          status: :ok,
          set_id: 0,
          capacity_bytes: 1_000,
          free_bytes: 250,
          used_bytes: 750
        },
        %{status: :error, set_id: 1, reason: :unavailable}
      ]
    }

    {:ok, report} =
      Rebalance.plan(
        topology: topology,
        drive_stats_fun: fn _opts -> drive_stats end
      )

    assert report.status == :partial
    assert :drive_stats_partial in report.warnings
    assert report.drive_stats.status == :partial
    assert report.drive_stats.errors == 1

    per_set = Map.new(report.per_set, &{&1.set_id, &1})
    assert per_set[0].drive_ok == 1
    assert per_set[0].drive_errors == 0
    assert per_set[0].drive_free_bytes == 250
    assert per_set[1].drive_ok == 0
    assert per_set[1].drive_errors == 1
  end

  test "unknown decommission set fails loudly when topology is known" do
    topology = topology()

    assert {:error, {:unknown_set_id, 99, [0, 1]}} =
             Rebalance.plan(topology: topology, include_drive_stats: false, decommission_set: 99)
  end

  defp topology do
    base = Path.join(System.tmp_dir!(), "maxio_rebalance_test")

    endpoints0 = for i <- 0..1, do: {Node.self(), Path.join(base, "s0d#{i}")}
    endpoints1 = for i <- 0..1, do: {Node.self(), Path.join(base, "s1d#{i}")}

    Topology.parse_and_validate!(
      data_shards: 1,
      parity_shards: 1,
      block_size: 1024,
      allow_colocated_endpoints: true,
      pools: [%{id: 0, sets: [%{id: 0, endpoints: endpoints0}, %{id: 1, endpoints: endpoints1}]}]
    )
  end

  defp key_for_set(bucket, topology, set_id, prefix) do
    Enum.find_value(0..10_000, fn i ->
      key = "#{prefix}-#{i}.bin"
      if Router.set_for(bucket, key, topology) == set_id, do: key
    end) || flunk("could not find key for set #{inspect(set_id)}")
  end

  defp bucket_name(prefix) do
    suffix =
      System.unique_integer([:positive])
      |> Integer.to_string()
      |> String.replace("-", "")

    "#{prefix}-#{suffix}"
  end
end
