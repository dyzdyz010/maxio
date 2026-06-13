defmodule Maxio.Cluster.RebalanceJobsTest do
  use Maxio.DataCase, async: false

  alias Maxio.{Buckets, Objects}
  alias Maxio.Cluster.{Rebalance.Jobs, Router, Topology}

  @owner "arn:aws:iam:::root"

  test "start_rebalance persists a planned job with a serializable plan snapshot" do
    topology = topology()
    bucket = bucket_name("rebalance-job")
    {:ok, _bucket} = Buckets.create(bucket, @owner)
    key = key_for_set(bucket, topology, 0)

    {:ok, _object} =
      Objects.put_version_with_id(bucket, key, "null", %{
        size: 11,
        etag: "e11",
        placement_set_id: 0,
        placement_topology_hash: "topo-a"
      })

    assert {:ok, job} =
             Jobs.start_rebalance(
               topology: topology,
               include_drive_stats: false,
               requested_by: "test"
             )

    assert job.kind == "rebalance"
    assert job.status == "planned"
    assert job.data_movement_status == "not_started"
    assert job.target_set_id == nil
    assert job.plan_status == "ok"
    assert job.plan_scanned == 1
    assert job.plan_bytes == 11
    assert job.plan_placement_fallbacks == 0
    assert job.progress_scanned == 0
    assert job.plan["per_set"] |> is_list()
  end

  test "start_decommission records target set and refuses a concurrent active job" do
    topology = topology()
    bucket = bucket_name("decommission-job")
    {:ok, _bucket} = Buckets.create(bucket, @owner)
    key = key_for_set(bucket, topology, 1)

    {:ok, _object} =
      Objects.put_version_with_id(bucket, key, "null", %{
        size: 7,
        etag: "e7",
        placement_set_id: 1,
        placement_topology_hash: "topo-a"
      })

    other_key = key_for_set(bucket, topology, 0)

    {:ok, _object} =
      Objects.put_version_with_id(bucket, other_key, "null", %{
        size: 13,
        etag: "e13",
        placement_set_id: 0,
        placement_topology_hash: "topo-a"
      })

    assert {:ok, job} =
             Jobs.start_decommission(1, topology: topology, include_drive_stats: false)

    assert job.kind == "decommission"
    assert job.target_set_id == 1
    assert job.plan_scanned == 1
    assert job.plan_bytes == 7

    assert {:error, {:active_job_exists, active}} =
             Jobs.start_rebalance(topology: topology, include_drive_stats: false)

    assert active.id == job.id
  end

  test "cancel transitions active job to canceled and frees singleton guard" do
    topology = topology()
    bucket = bucket_name("cancel-job")
    {:ok, _bucket} = Buckets.create(bucket, @owner)
    key = key_for_set(bucket, topology, 0)

    {:ok, _object} =
      Objects.put_version_with_id(bucket, key, "null", %{
        size: 3,
        etag: "e3",
        placement_set_id: 0,
        placement_topology_hash: "topo-a"
      })

    assert {:ok, job} = Jobs.start_rebalance(topology: topology, include_drive_stats: false)
    assert {:ok, canceled} = Jobs.cancel(job.id)
    assert canceled.status == "canceled"
    assert canceled.data_movement_status == "canceled"
    assert %DateTime{} = canceled.finished_at

    assert {:ok, next_job} = Jobs.start_rebalance(topology: topology, include_drive_stats: false)
    refute next_job.id == job.id
  end

  test "movement state transitions do not overwrite canceled or terminal jobs" do
    topology = topology()
    bucket = bucket_name("movement-guard-job")
    {:ok, _bucket} = Buckets.create(bucket, @owner)
    key = key_for_set(bucket, topology, 0)

    {:ok, _object} =
      Objects.put_version_with_id(bucket, key, "null", %{
        size: 3,
        etag: "e3",
        placement_set_id: 0,
        placement_topology_hash: "topo-a"
      })

    assert {:ok, job} = Jobs.start_decommission(0, topology: topology, include_drive_stats: false)
    assert Jobs.to_view(job).data_movement == false

    assert {:ok, running} = Jobs.begin_data_movement(job.id, 1)
    assert running.status == "running"
    assert Jobs.to_view(running).data_movement == true

    assert {:ok, canceled} = Jobs.cancel(running.id)
    assert canceled.status == "canceled"

    assert {:error, {:stale_job_status, "canceled"}} =
             Jobs.record_progress(canceled.id, %{scanned: 1, moved: 1, skipped: 0, errors: 0})

    assert {:error, {:stale_job_status, "canceled"}} =
             Jobs.complete_data_movement(canceled.id)

    assert {:error, {:stale_job_status, "canceled"}} =
             Jobs.fail_data_movement(canceled.id, :late_error)

    assert {:ok, unchanged} = Jobs.get(canceled.id)
    assert unchanged.status == "canceled"
    assert unchanged.progress_scanned == 0
    refute is_nil(unchanged.finished_at)

    assert {:ok, terminal_job} =
             Jobs.start_decommission(0, topology: topology, include_drive_stats: false)

    assert {:ok, terminal_running} = Jobs.begin_data_movement(terminal_job.id, 1)
    assert {:ok, complete} = Jobs.complete_data_movement(terminal_running.id)
    assert complete.status == "complete"

    assert {:error, {:stale_job_status, "complete"}} =
             Jobs.begin_data_movement(complete.id, 1)

    assert {:ok, still_complete} = Jobs.get(complete.id)
    assert still_complete.status == "complete"
  end

  test "begin_data_movement cannot rebind destination from a stale job snapshot" do
    topology = topology()
    bucket = bucket_name("movement-destination-guard-job")
    {:ok, _bucket} = Buckets.create(bucket, @owner)
    key = key_for_set(bucket, topology, 0)

    {:ok, _object} =
      Objects.put_version_with_id(bucket, key, "null", %{
        size: 3,
        etag: "e3",
        placement_set_id: 0,
        placement_topology_hash: "topo-a"
      })

    assert {:ok, job} = Jobs.start_decommission(0, topology: topology, include_drive_stats: false)
    stale_snapshot = job

    assert {:ok, running} = Jobs.begin_data_movement(job, 1)
    assert running.destination_set_id == 1

    assert {:error, {:destination_mismatch, 1, 2}} =
             Jobs.begin_data_movement(stale_snapshot, 2)

    assert {:ok, unchanged} = Jobs.get(job.id)
    assert unchanged.status == "running"
    assert unchanged.destination_set_id == 1
  end

  test "start fails loudly when plan has placement fallbacks" do
    topology = topology()
    bucket = bucket_name("fallback-job")
    {:ok, _bucket} = Buckets.create(bucket, @owner)
    key = key_for_set(bucket, topology, 0)
    {:ok, _object} = Objects.put_version_with_id(bucket, key, "null", %{size: 5, etag: "e5"})

    assert {:error, {:placement_fallbacks, 1}} =
             Jobs.start_rebalance(topology: topology, include_drive_stats: false)

    assert [] = Jobs.list()
  end

  test "decommission refuses current-only scope" do
    assert {:error, :decommission_requires_versions} =
             Jobs.start_decommission(1,
               topology: topology(),
               include_drive_stats: false,
               current_only: true
             )

    assert [] = Jobs.list()
  end

  test "decommission fails loudly when target set has placement fallbacks" do
    topology = topology()
    bucket = bucket_name("decommission-fallback-job")
    {:ok, _bucket} = Buckets.create(bucket, @owner)
    key = key_for_set(bucket, topology, 1)
    {:ok, _object} = Objects.put_version_with_id(bucket, key, "null", %{size: 5, etag: "e5"})

    assert {:error, {:placement_fallbacks, 1}} =
             Jobs.start_decommission(1, topology: topology, include_drive_stats: false)

    assert [] = Jobs.list()
  end

  test "decommission validates target set through planner" do
    topology = topology()

    assert {:error, {:unknown_set_id, 99, [0, 1]}} =
             Jobs.start_decommission(99, topology: topology, include_drive_stats: false)
  end

  test "start requires a configured or injected topology" do
    assert {:error, :no_topology} = Jobs.start_rebalance(include_drive_stats: false)
  end

  defp topology do
    base = Path.join(System.tmp_dir!(), "maxio_rebalance_jobs_test")

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
      key = "job-#{set_id}-#{i}.txt"
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
