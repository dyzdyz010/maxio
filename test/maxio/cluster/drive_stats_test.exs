defmodule Maxio.Cluster.DriveStatsTest do
  use ExUnit.Case, async: false

  alias Maxio.Cluster.{DriveStats, Topology, Transport.InProcess}

  setup do
    :ok = InProcess.setup!()
    base = Path.join(System.tmp_dir!(), "maxio_drive_stats_#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf(base) end)

    {:ok, base: base}
  end

  test "local stats normalize provider capacity fields", %{base: base} do
    drive = Path.join(base, "d0")
    expanded_drive = Path.expand(drive)

    assert {:ok,
            %{
              status: :ok,
              drive: ^expanded_drive,
              mount_root: "test-mount",
              capacity_bytes: 1_000,
              free_bytes: 250,
              used_bytes: 750,
              used_percent_x100: 7_500,
              source: :test,
              precision: :exact,
              observed_at_ms: 123
            }} =
             DriveStats.local(drive,
               provider: fn _drive ->
                 {:ok,
                  %{
                    mount_root: "test-mount",
                    capacity_bytes: 1_000,
                    free_bytes: 250,
                    source: :test,
                    precision: :exact
                  }}
               end,
               now_ms: 123
             )
  end

  test "default provider reports filesystem stats for the current workspace" do
    assert {:ok,
            %{
              status: :ok,
              capacity_bytes: capacity_bytes,
              free_bytes: free_bytes,
              used_bytes: used_bytes,
              mount_root: mount_root
            }} = DriveStats.local(File.cwd!())

    assert capacity_bytes > 0
    assert free_bytes >= 0
    assert used_bytes >= 0
    assert is_binary(mount_root)
  end

  test "invalid provider config returns a structured error instead of raising", %{base: base} do
    drive = Path.join(base, "bad-provider")

    assert {:error, {:invalid_provider, :bad_provider}} =
             DriveStats.local(drive, provider: :bad_provider)
  end

  test "topology stats summarize endpoint capacity and per-drive errors", %{base: base} do
    endpoints = for i <- 0..2, do: {Node.self(), Path.join(base, "d#{i}")}
    Enum.each(endpoints, fn {_node, drive} -> File.mkdir_p!(drive) end)

    topology =
      Topology.parse_and_validate!(
        data_shards: 2,
        parity_shards: 1,
        block_size: 1_024,
        allow_colocated_endpoints: true,
        pools: [%{id: 0, sets: [%{id: 0, endpoints: endpoints}]}]
      )

    {node, failed_drive} = List.last(endpoints)
    InProcess.set_drive_down(node, failed_drive)

    assert %{
             status: :partial,
             topology_sets: 1,
             endpoints: 3,
             ok: 2,
             errors: 1,
             capacity_bytes: 3_000,
             free_bytes: 1_000,
             used_bytes: 2_000,
             min_free_bytes: 400,
             min_free_percent_x100: 3_000,
             samples: samples
           } =
             DriveStats.sample_topology(
               topology: topology,
               transport: InProcess,
               provider: provider(base),
               now_ms: 456
             )

    assert Enum.count(samples, &match?(%{status: :ok}, &1)) == 2
    assert Enum.any?(samples, &match?(%{status: :error, reason: :unavailable}, &1))
  end

  test "sample_topology reports no_topology without configured topology" do
    assert %{
             status: :no_topology,
             topology_sets: 0,
             endpoints: 0,
             ok: 0,
             errors: 0,
             samples: []
           } = DriveStats.sample_topology(topology: nil)
  end

  defp provider(base) do
    fn drive ->
      case Path.relative_to(drive, base) do
        "d0" ->
          {:ok,
           %{
             mount_root: "mount-a",
             capacity_bytes: 1_000,
             free_bytes: 400,
             source: :test,
             precision: :exact
           }}

        "d1" ->
          {:ok,
           %{
             mount_root: "mount-b",
             capacity_bytes: 2_000,
             free_bytes: 600,
             source: :test,
             precision: :exact
           }}

        _other ->
          {:error, :unexpected_drive}
      end
    end
  end
end
