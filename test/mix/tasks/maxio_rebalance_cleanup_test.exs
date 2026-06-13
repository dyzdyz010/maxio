defmodule Mix.Tasks.Maxio.RebalanceCleanupTest do
  use Maxio.DataCase, async: false

  import ExUnit.CaptureIO

  alias Maxio.{Buckets, Objects}
  alias Maxio.Cluster.{Rebalance.Jobs, Topology}
  alias Mix.Tasks.Maxio.Rebalance.Cleanup

  @owner "arn:aws:iam:::root"
  @task "maxio.rebalance.cleanup"
  @topology_key {Maxio.Cluster.Topology, :topology}

  setup do
    previous_topology = :persistent_term.get(@topology_key, :__maxio_no_topology__)
    Mix.Task.reenable(@task)

    on_exit(fn ->
      restore_topology(previous_topology)
      Mix.Task.reenable(@task)
    end)

    :ok
  end

  test "dry-run prints source cleanup report in text and JSON without mutating job" do
    topology = topology()
    :persistent_term.put(@topology_key, topology)

    bucket = bucket_name("rebalance-cleanup-cli")
    {:ok, _bucket} = Buckets.create(bucket, @owner)

    {:ok, job} = Jobs.start_decommission(0, include_drive_stats: false)
    {:ok, _running} = Jobs.begin_data_movement(job.id, 1)
    {:ok, _complete} = Jobs.complete_data_movement(job.id)

    {:ok, _object} =
      Objects.put_version_with_id(bucket, "cleanup-cli.txt", "v1", %{
        size: 5,
        etag: "e5",
        placement_set_id: 1,
        placement_topology_hash: "topo-a"
      })

    text =
      capture_io(fn ->
        Cleanup.run(["--job-id", job.id, "--dry-run"])
      end)

    assert text =~ "[maxio rebalance.cleanup]"
    assert text =~ "status=dry_run"
    assert text =~ "source_cleanup_status=not_started"
    assert text =~ "deleted=1"
    assert text =~ "source_cleanup=true"

    Mix.Task.reenable(@task)

    json =
      capture_io(fn ->
        Cleanup.run(["--job-id", job.id, "--dry-run", "--json"])
      end)
      |> Jason.decode!()

    assert json["status"] == "dry_run"
    assert json["source_cleanup"] == true
    assert json["deleted"] == 1
    assert json["errors"] == 0

    assert {:ok, unchanged} = Jobs.get(job.id)
    assert unchanged.status == "complete"
    assert unchanged.source_cleanup_status == "not_started"
    assert unchanged.source_cleanup_scanned == 0
  end

  defp topology do
    base = Path.join(System.tmp_dir!(), "maxio_rebalance_cleanup_cli")

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

  defp bucket_name(prefix) do
    suffix =
      System.unique_integer([:positive])
      |> Integer.to_string()
      |> String.replace("-", "")

    "#{prefix}-#{suffix}"
  end

  defp restore_topology(:__maxio_no_topology__),
    do: :persistent_term.erase(@topology_key)

  defp restore_topology(topology),
    do: :persistent_term.put(@topology_key, topology)
end
