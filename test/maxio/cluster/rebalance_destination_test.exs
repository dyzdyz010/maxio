defmodule Maxio.Cluster.RebalanceDestinationTest do
  use ExUnit.Case, async: true

  alias Maxio.Cluster.{Rebalance.Destination, Topology}

  test "selects eligible non-target set with the most free bytes" do
    topology = topology(3)

    assert {:ok, selection} =
             Destination.select_decommission_destination(0,
               topology: topology,
               bytes_required: 500,
               drive_stats_fun: fn _opts ->
                 drive_stats(%{
                   0 => [1_000, 1_000],
                   1 => [500, 500],
                   2 => [700, 700]
                 })
               end
             )

    assert selection.set_id == 2
    assert selection.source == :free_space
    assert selection.bytes_required == 500
    assert selection.drive_free_bytes == 1_400
    assert Enum.all?(selection.candidates, &(&1.set_id != 0))
  end

  test "uses min free bytes and set id as deterministic tie breakers" do
    topology = topology(4)

    assert {:ok, selection} =
             Destination.select_decommission_destination(0,
               topology: topology,
               drive_stats_fun: fn _opts ->
                 drive_stats(%{
                   0 => [100, 100],
                   1 => [900, 100],
                   2 => [600, 400],
                   3 => [400, 600]
                 })
               end
             )

    assert selection.set_id == 2
  end

  test "skips candidate sets with endpoint stat errors" do
    topology = topology(3)

    assert {:ok, selection} =
             Destination.select_decommission_destination(0,
               topology: topology,
               bytes_required: 10,
               drive_stats_fun: fn _opts ->
                 drive_stats(%{
                   0 => [100, 100],
                   1 => [1_000, :error],
                   2 => [200, 200]
                 })
               end
             )

    assert selection.set_id == 2
    skipped = Enum.find(selection.candidates, &(&1.set_id == 1))
    refute skipped.eligible?
    assert skipped.drive_errors == 1
  end

  test "fails closed when candidate telemetry omits endpoints" do
    topology = topology(2)

    assert {:error, {:no_healthy_destination_set, 0, 0, candidates}} =
             Destination.select_decommission_destination(0,
               topology: topology,
               drive_stats_fun: fn _opts ->
                 drive_stats(%{0 => [100, 100], 1 => [1_000]})
               end
             )

    assert [
             %{
               set_id: 1,
               drive_expected: 2,
               drive_endpoints: 1,
               drive_missing: 1,
               eligible?: false
             }
           ] = candidates
  end

  test "fails closed when no healthy destination exists" do
    topology = topology(2)

    assert {:error, {:no_healthy_destination_set, 0, 0, candidates}} =
             Destination.select_decommission_destination(0,
               topology: topology,
               drive_stats_fun: fn _opts ->
                 drive_stats(%{0 => [100, 100], 1 => [:error, 100]})
               end
             )

    assert [%{set_id: 1, drive_errors: 1, eligible?: false}] = candidates
  end

  test "fails closed when healthy candidates lack enough free space" do
    topology = topology(2)

    assert {:error, {:insufficient_destination_free_space, 0, 1_000, candidates}} =
             Destination.select_decommission_destination(0,
               topology: topology,
               bytes_required: 1_000,
               drive_stats_fun: fn _opts -> drive_stats(%{0 => [500, 500], 1 => [200, 200]}) end
             )

    assert [%{set_id: 1, drive_free_bytes: 400, eligible?: false}] = candidates
  end

  test "fails loudly for unknown target set" do
    topology = topology(2)

    assert {:error, {:unknown_target_set_id, 9, [0, 1]}} =
             Destination.select_decommission_destination(9,
               topology: topology,
               drive_stats_fun: fn _opts -> drive_stats(%{}) end
             )
  end

  defp topology(set_count) do
    base = Path.join(System.tmp_dir!(), "maxio_rebalance_destination_test")

    sets =
      for set_id <- 0..(set_count - 1) do
        endpoints = for i <- 0..1, do: {Node.self(), Path.join(base, "s#{set_id}d#{i}")}
        %{id: set_id, endpoints: endpoints}
      end

    Topology.parse_and_validate!(
      data_shards: 1,
      parity_shards: 1,
      block_size: 1024,
      allow_colocated_endpoints: true,
      pools: [%{id: 0, sets: sets}]
    )
  end

  defp drive_stats(free_by_set) do
    samples =
      free_by_set
      |> Enum.flat_map(fn {set_id, free_values} ->
        free_values
        |> Enum.with_index()
        |> Enum.map(fn {free, index} -> sample(set_id, index, free) end)
      end)

    ok_samples = Enum.filter(samples, &match?(%{status: :ok}, &1))

    %{
      status: if(length(ok_samples) == length(samples), do: :ok, else: :partial),
      samples: samples
    }
  end

  defp sample(set_id, index, :error) do
    %{
      status: :error,
      set_id: set_id,
      endpoint_index: index,
      reason: :unavailable
    }
  end

  defp sample(set_id, index, free) do
    %{
      status: :ok,
      set_id: set_id,
      endpoint_index: index,
      capacity_bytes: 2_000,
      free_bytes: free,
      used_bytes: 2_000 - free
    }
  end
end
