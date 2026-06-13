defmodule Mix.Tasks.Maxio.RebalanceRunTest do
  use Maxio.DataCase, async: false

  import ExUnit.CaptureIO

  alias Maxio.{Buckets, Objects}
  alias Maxio.Cluster.{Lock, Rebalance.Jobs, Router, Topology}
  alias Mix.Tasks.Maxio.Rebalance.Run

  @owner "arn:aws:iam:::root"
  @task "maxio.rebalance.run"
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

  test "dry-run prints decommission copy-pass report without mutating job" do
    topology = topology()
    :persistent_term.put(@topology_key, topology)

    bucket = bucket_name("rebalance-run-cli")
    {:ok, _bucket} = Buckets.create(bucket, @owner)
    key = key_for_set(bucket, topology, 0)

    {:ok, _object} =
      Objects.put_version_with_id(bucket, key, "v1", %{
        size: 5,
        etag: "e5",
        placement_set_id: 0,
        placement_topology_hash: "topo-a"
      })

    {:ok, job} = Jobs.start_decommission(0, include_drive_stats: false)

    output =
      capture_io(fn ->
        Run.run(["--job-id", job.id, "--destination-set", "1", "--dry-run"])
      end)

    assert output =~ "[maxio rebalance.run]"
    assert output =~ "status=dry_run"
    assert output =~ "destination_set_id=1"
    assert output =~ "source_cleanup=false"
    assert {:ok, unchanged} = Jobs.get(job.id)
    assert unchanged.status == "planned"
    assert unchanged.progress_scanned == 0
    assert unchanged.progress_moved == 0
    assert is_nil(unchanged.destination_set_id)
  end

  test "dry-run can choose destination from free space telemetry" do
    topology = topology()
    :persistent_term.put(@topology_key, topology)

    bucket = bucket_name("rebalance-run-cli-auto")
    {:ok, _bucket} = Buckets.create(bucket, @owner)
    key = key_for_set(bucket, topology, 0)

    {:ok, _object} =
      Objects.put_version_with_id(bucket, key, "v1", %{
        size: 5,
        etag: "e5",
        placement_set_id: 0,
        placement_topology_hash: "topo-a"
      })

    {:ok, job} = Jobs.start_decommission(0, include_drive_stats: false)

    output =
      capture_io(fn ->
        Run.run(["--job-id", job.id, "--auto-destination", "--dry-run"])
      end)

    assert output =~ "[maxio rebalance.run]"
    assert output =~ "status=dry_run"
    assert output =~ "destination_set_id=1"
    assert output =~ "free_space_placement=true"

    assert {:ok, unchanged} = Jobs.get(job.id)
    assert unchanged.status == "planned"
    assert is_nil(unchanged.destination_set_id)
  end

  test "locked foreground runner fails loudly" do
    topology = topology()
    :persistent_term.put(@topology_key, topology)

    bucket = bucket_name("rebalance-run-cli-lock")
    {:ok, _bucket} = Buckets.create(bucket, @owner)
    key = key_for_set(bucket, topology, 0)

    {:ok, _object} =
      Objects.put_version_with_id(bucket, key, "v1", %{
        size: 5,
        etag: "e5",
        placement_set_id: 0,
        placement_topology_hash: "topo-a"
      })

    {:ok, job} = Jobs.start_decommission(0, include_drive_stats: false)
    lock_holder = hold_lock({:rebalance_job_runner, job.id})

    try do
      assert_raise Mix.Error, ~r/runner is already active/, fn ->
        Run.run(["--job-id", job.id, "--destination-set", "1"])
      end
    after
      release_lock(lock_holder)
    end
  end

  defp topology do
    base = Path.join(System.tmp_dir!(), "maxio_rebalance_run_cli")

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
      key = "cli-run-#{set_id}-#{i}.txt"
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

  defp hold_lock(resource) do
    parent = self()

    pid =
      spawn(fn ->
        {:ok, lease} = Lock.acquire(resource, refresh: false)
        send(parent, {:lock_held, self()})

        receive do
          :release_lock -> :ok = Lock.release(lease)
        end
      end)

    ref = Process.monitor(pid)
    assert_receive {:lock_held, ^pid}
    {pid, ref}
  end

  defp release_lock({pid, ref}) do
    send(pid, :release_lock)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
  end
end
