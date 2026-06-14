defmodule Mix.Tasks.Maxio.RebalanceCleanupTest do
  use Maxio.DataCase, async: false

  import ExUnit.CaptureIO

  alias Maxio.{Buckets, Objects}
  alias Maxio.Cluster.{Placement, Rebalance.Jobs, Topology}
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

  test "dry-run prints rebalance source cleanup report without destination fields" do
    topology = topology()
    :persistent_term.put(@topology_key, topology)

    bucket = bucket_name("rebalance-cleanup-cli-dynamic")
    {:ok, _bucket} = Buckets.create(bucket, @owner)
    key = key_for_set(bucket, topology, 1)

    {:ok, _object} =
      Objects.put_version_with_id(
        bucket,
        key,
        "v1",
        %{
          size: 5,
          etag: "e5"
        }
        |> Map.merge(Placement.attrs_for_write(bucket, key, topology: topology))
      )

    {:ok, job} = Jobs.start_rebalance(include_drive_stats: false)
    {:ok, _running} = Jobs.begin_rebalance_data_movement(job.id)
    {:ok, _complete} = Jobs.complete_data_movement(job.id)

    text =
      capture_io(fn ->
        Cleanup.run(["--job-id", job.id, "--dry-run"])
      end)

    assert text =~ "[maxio rebalance.cleanup]"
    assert text =~ "kind=rebalance"
    assert text =~ "status=dry_run"
    assert text =~ "target_set_id= destination_set_id="
    assert text =~ "deleted=1"

    Mix.Task.reenable(@task)

    json =
      capture_io(fn ->
        Cleanup.run(["--job-id", job.id, "--dry-run", "--json"])
      end)
      |> Jason.decode!()

    assert json["status"] == "dry_run"
    assert json["job_kind"] == "rebalance"
    assert json["target_set_id"] == nil
    assert json["destination_set_id"] == nil
    assert json["deleted"] == 1

    assert {:ok, unchanged} = Jobs.get(job.id)
    assert unchanged.source_cleanup_status == "not_started"
    assert unchanged.source_cleanup_scanned == 0
  end

  test "no-arg dry-run selects the oldest cleanup-ready job instead of latest job" do
    topology = topology()
    :persistent_term.put(@topology_key, topology)

    {:ok, older} = Jobs.start_rebalance(include_drive_stats: false)
    {:ok, older_running} = Jobs.begin_rebalance_data_movement(older.id)
    {:ok, older_complete} = Jobs.complete_data_movement(older_running.id)

    {:ok, newer} = Jobs.start_rebalance(include_drive_stats: false)
    {:ok, newer_running} = Jobs.begin_rebalance_data_movement(newer.id)
    {:ok, newer_complete} = Jobs.complete_data_movement(newer_running.id)
    {:ok, newer_cleaning} = Jobs.begin_source_cleanup(newer_complete.id)
    {:ok, newer_cleaned} = Jobs.complete_source_cleanup(newer_cleaning.id)

    assert newer_cleaned.source_cleanup_status == "complete"

    text =
      capture_io(fn ->
        Cleanup.run(["--dry-run"])
      end)

    assert text =~ "[maxio rebalance.cleanup]"
    assert text =~ "job_id=#{older_complete.id}"
    refute text =~ "job_id=#{newer_cleaned.id}"

    assert {:ok, unchanged} = Jobs.get(older_complete.id)
    assert unchanged.source_cleanup_status == "not_started"
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

  defp key_for_set(bucket, topology, set_id) do
    Enum.find_value(0..10_000, fn i ->
      key = "cleanup-cli-#{set_id}-#{i}.txt"
      if Maxio.Cluster.Router.set_for(bucket, key, topology) == set_id, do: key
    end) || flunk("could not find key for set #{inspect(set_id)}")
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
