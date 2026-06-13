defmodule Mix.Tasks.Maxio.RebalanceJobTest do
  use Maxio.DataCase, async: false

  import ExUnit.CaptureIO

  alias Maxio.{Buckets, Objects}
  alias Maxio.Cluster.{Rebalance.Jobs, Router, Topology}
  alias Mix.Tasks.Maxio.Rebalance.{Cancel, Start, Status}

  @owner "arn:aws:iam:::root"
  @topology_key {Maxio.Cluster.Topology, :topology}
  @tasks ["maxio.rebalance.start", "maxio.rebalance.status", "maxio.rebalance.cancel"]

  setup do
    previous_topology = :persistent_term.get(@topology_key, :__maxio_no_topology__)
    Enum.each(@tasks, &Mix.Task.reenable/1)

    on_exit(fn ->
      restore_topology(previous_topology)
      Enum.each(@tasks, &Mix.Task.reenable/1)
    end)

    :ok
  end

  test "start prints a planned control-plane job" do
    topology = put_topology()
    bucket = bucket_name("rebalance-start")
    {:ok, _bucket} = Buckets.create(bucket, @owner)
    key = key_for_set(bucket, topology, 0)

    {:ok, _object} =
      Objects.put_version_with_id(bucket, key, "null", %{
        size: 9,
        etag: "e9",
        placement_set_id: 0,
        placement_topology_hash: "topo-a"
      })

    output = run_start(["--no-drive-stats"])

    assert output =~ "[maxio rebalance.start]"
    assert output =~ "kind=rebalance"
    assert output =~ "status=planned"
    assert output =~ "data_movement=false"
    assert output =~ "data_movement_status=not_started"
    assert output =~ "bytes=9"
    assert output =~ "placement_fallbacks=0"
  end

  test "start refuses unsafe placement fallback inventory" do
    topology = put_topology()
    bucket = bucket_name("rebalance-start-fallback")
    {:ok, _bucket} = Buckets.create(bucket, @owner)
    key = key_for_set(bucket, topology, 0)
    {:ok, _object} = Objects.put_version_with_id(bucket, key, "null", %{size: 9, etag: "e9"})

    assert_raise Mix.Error, ~r/placement_fallbacks=1/, fn ->
      Start.run(["--no-drive-stats"])
    end
  end

  test "decommission start via --decommission-set stores target set" do
    topology = put_topology()
    bucket = bucket_name("decommission-start")
    {:ok, _bucket} = Buckets.create(bucket, @owner)
    key = key_for_set(bucket, topology, 1)

    {:ok, _object} =
      Objects.put_version_with_id(bucket, key, "null", %{
        size: 4,
        etag: "e4",
        placement_set_id: 1,
        placement_topology_hash: "topo-a"
      })

    other_key = key_for_set(bucket, topology, 0)

    {:ok, _object} =
      Objects.put_version_with_id(bucket, other_key, "null", %{
        size: 12,
        etag: "e12",
        placement_set_id: 0,
        placement_topology_hash: "topo-a"
      })

    output = run_start(["--decommission-set", "1", "--no-drive-stats"])

    assert output =~ "kind=decommission"
    assert output =~ "target_set_id=1"
    assert output =~ "bytes=4"
  end

  test "decommission start refuses --current-only" do
    _topology = put_topology()

    assert_raise Mix.Error, ~r/decommission jobs must scan all versions/, fn ->
      Start.run(["--decommission-set", "1", "--current-only", "--no-drive-stats"])
    end
  end

  test "status prints latest and JSON" do
    topology = put_topology()
    {:ok, job} = seed_job(topology, 0)

    output = run_status([])
    assert output =~ "[maxio rebalance.status]"
    assert output =~ "job_id=#{job.id}"
    assert output =~ "status=planned"
    assert output =~ "data_movement=false"

    json = run_status(["--json"]) |> Jason.decode!()
    assert json["id"] == job.id
    assert json["data_movement"] == false
    assert json["data_movement_status"] == "not_started"
  end

  test "cancel by positional job id transitions job" do
    topology = put_topology()
    {:ok, job} = seed_job(topology, 0)

    output = run_cancel([job.id])
    assert output =~ "[maxio rebalance.cancel]"
    assert output =~ "job_id=#{job.id}"
    assert output =~ "status=canceled"
    assert output =~ "data_movement=false"

    assert {:ok, canceled} = Jobs.get(job.id)
    assert canceled.status == "canceled"
  end

  test "status reports not_started when no job exists" do
    output = run_status([])
    assert output =~ "status=not_started"
    assert output =~ "jobs=0"
  end

  defp seed_job(topology, set_id) do
    bucket = bucket_name("rebalance-status")
    {:ok, _bucket} = Buckets.create(bucket, @owner)
    key = key_for_set(bucket, topology, set_id)

    {:ok, _object} =
      Objects.put_version_with_id(bucket, key, "null", %{
        size: 6,
        etag: "e6",
        placement_set_id: set_id,
        placement_topology_hash: "topo-a"
      })

    Jobs.start_rebalance(include_drive_stats: false)
  end

  defp run_start(args), do: run_task("maxio.rebalance.start", fn -> Start.run(args) end)
  defp run_status(args), do: run_task("maxio.rebalance.status", fn -> Status.run(args) end)
  defp run_cancel(args), do: run_task("maxio.rebalance.cancel", fn -> Cancel.run(args) end)

  defp run_task(task, fun) do
    Mix.Task.reenable(task)
    capture_io(fun)
  end

  defp put_topology do
    topology = topology()
    :persistent_term.put(@topology_key, topology)
    topology
  end

  defp topology do
    base = Path.join(System.tmp_dir!(), "maxio_rebalance_job_cli")

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
      key = "cli-job-#{set_id}-#{i}.txt"
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

  defp restore_topology(:__maxio_no_topology__),
    do: :persistent_term.erase(@topology_key)

  defp restore_topology(topology),
    do: :persistent_term.put(@topology_key, topology)
end
