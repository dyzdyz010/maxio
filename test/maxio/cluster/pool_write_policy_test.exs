defmodule Maxio.Cluster.PoolWritePolicyTest do
  use ExUnit.Case, async: true

  alias Maxio.Cluster.{Placement, Placement.PoolWritePolicy, Topology}

  test "skips when pool free-space policy is not enabled" do
    topology = topology([{0, [0]}, {7, [1]}])

    assert :skip =
             PoolWritePolicy.select("bucket", "key", topology,
               pool_write_policy: :hash,
               drive_stats_fun: fn _opts ->
                 drive_stats(%{0 => [200, 200], 1 => [1_800, 1_800]})
               end
             )
  end

  test "selects pools with probability proportional to free space" do
    topology = topology([{0, [0]}, {7, [1]}])

    counts =
      1..2_000
      |> Enum.reduce(%{}, fn i, acc ->
        {:ok, selection} =
          PoolWritePolicy.select("weighted", "obj-#{i}", topology,
            pool_write_policy: :weighted_free_space,
            drive_stats_fun: fn _opts -> drive_stats(%{0 => [200, 200], 1 => [1_800, 1_800]}) end
          )

        Map.update(acc, selection.pool_id, 1, &(&1 + 1))
      end)

    assert counts[0] > 0
    assert counts[7] > counts[0] * 5
  end

  test "fails closed when a candidate pool has missing endpoint telemetry" do
    topology = topology([{0, [0]}, {7, [1]}])

    assert {:error, {:pool_telemetry_incomplete, candidates}} =
             PoolWritePolicy.select("bucket", "key", topology,
               pool_write_policy: :weighted_free_space,
               drive_stats_fun: fn _opts -> drive_stats(%{0 => [1_000, 1_000], 1 => []}) end
             )

    assert [
             %{pool_id: 0, drive_missing: 0, eligible?: true},
             %{pool_id: 7, drive_missing: 2, eligible?: false}
           ] = candidates
  end

  test "does not write to pools whose drive usage is at the high-water mark" do
    topology = topology([{0, [0]}, {7, [1]}])

    assert {:ok, selection} =
             PoolWritePolicy.select("bucket", "key", topology,
               pool_write_policy: :weighted_free_space,
               drive_stats_fun: fn _opts ->
                 drive_stats(%{
                   0 => [
                     %{capacity_bytes: 10_000, free_bytes: 100},
                     %{capacity_bytes: 10_000, free_bytes: 100}
                   ],
                   1 => [
                     %{capacity_bytes: 10_000, free_bytes: 2_000},
                     %{capacity_bytes: 10_000, free_bytes: 2_000}
                   ]
                 })
               end
             )

    assert selection.pool_id == 7
  end

  test "Placement.resolve_write excludes decommission source sets before weighted selection" do
    topology = topology([{0, [0]}, {7, [1]}])

    assert {:ok, placement} =
             Placement.resolve_write("bucket", "key",
               topology: topology,
               pool_write_policy: :weighted_free_space,
               drive_stats_fun: fn _opts -> drive_stats(%{0 => [], 1 => [1_000, 1_000]}) end,
               decommission_write_routes: %{0 => 1}
             )

    assert placement.set_id == 1
    assert placement.pool_id == 7
    assert placement.source == :pool_free_space
  end

  test "PoolWritePolicy keeps healthy sets in a pool after excluding decommission source sets" do
    topology = topology([{0, [0, 1]}])

    assert {:ok, selection} =
             PoolWritePolicy.select("bucket", "key", topology,
               pool_write_policy: :weighted_free_space,
               pool_write_exclude_set_ids: [0],
               drive_stats_fun: fn _opts -> drive_stats(%{0 => [], 1 => [1_000, 1_000]}) end
             )

    assert selection.pool_id == 0
    assert selection.set_id == 1

    assert [%{pool_id: 0, set_ids: [1], drive_missing: 0, eligible?: true}] =
             selection.candidates
  end

  defp topology(pool_sets) do
    base = Path.join(System.tmp_dir!(), "maxio_pool_write_policy_test")

    pools =
      Enum.map(pool_sets, fn {pool_id, set_ids} ->
        sets =
          Enum.map(set_ids, fn set_id ->
            %{
              id: set_id,
              endpoints: [
                {Node.self(), Path.join(base, "pool#{pool_id}-set#{set_id}-d0")},
                {Node.self(), Path.join(base, "pool#{pool_id}-set#{set_id}-d1")}
              ]
            }
          end)

        %{id: pool_id, sets: sets}
      end)

    Topology.parse_and_validate!(
      data_shards: 1,
      parity_shards: 1,
      block_size: 1024,
      allow_colocated_endpoints: true,
      pools: pools
    )
  end

  defp drive_stats(free_by_set) do
    samples =
      free_by_set
      |> Enum.flat_map(fn {set_id, free_values} ->
        free_values
        |> List.wrap()
        |> Enum.with_index()
        |> Enum.map(fn {free, index} -> sample(set_id, index, free) end)
      end)

    ok_samples = Enum.filter(samples, &match?(%{status: :ok}, &1))

    %{
      status: if(length(ok_samples) == length(samples), do: :ok, else: :partial),
      samples: samples
    }
  end

  defp sample(set_id, endpoint_index, %{capacity_bytes: capacity, free_bytes: free}) do
    %{
      status: :ok,
      set_id: set_id,
      endpoint_index: endpoint_index,
      capacity_bytes: capacity,
      free_bytes: free,
      used_bytes: capacity - free,
      used_percent_x100: div((capacity - free) * 10_000, capacity)
    }
  end

  defp sample(set_id, endpoint_index, free) do
    sample(set_id, endpoint_index, %{capacity_bytes: 10_000, free_bytes: free})
  end
end
