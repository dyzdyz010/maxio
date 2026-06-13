defmodule Maxio.Cluster.RebalanceSchedulerTest do
  use Maxio.DataCase, async: false

  import ExUnit.CaptureLog

  alias Maxio.{Buckets, Objects}

  alias Maxio.Cluster.{
    Lock,
    Placement,
    Rebalance.Jobs,
    Rebalance.Scheduler,
    Router,
    Topology
  }

  alias Maxio.Cluster.Transport.InProcess
  alias Maxio.Storage.Distributed

  @owner "arn:aws:iam:::root"
  @scheduler_lock {:rebalance_scheduler, :run}

  setup do
    InProcess.setup!()
    previous_backend = Application.get_env(:maxio, :storage_backend)
    Application.put_env(:maxio, :storage_backend, Distributed)

    base =
      Path.join(
        System.tmp_dir!(),
        "maxio_rebalance_scheduler_#{System.unique_integer([:positive])}"
      )

    endpoints0 = for i <- 0..1, do: {Node.self(), Path.join(base, "s0d#{i}")}
    endpoints1 = for i <- 0..1, do: {Node.self(), Path.join(base, "s1d#{i}")}

    topology =
      Topology.parse_and_validate!(
        data_shards: 1,
        parity_shards: 1,
        block_size: 1024,
        allow_colocated_endpoints: true,
        pools: [
          %{id: 0, sets: [%{id: 0, endpoints: endpoints0}, %{id: 1, endpoints: endpoints1}]}
        ]
      )

    on_exit(fn ->
      Application.put_env(:maxio, :storage_backend, previous_backend)
      File.rm_rf(base)
    end)

    {:ok, topology: topology}
  end

  test "disabled scheduler starts without a timer" do
    pid = start_scheduler!(enabled: false)

    assert %{
             enabled: false,
             scheduled?: false,
             last_result: nil,
             last_skip_reason: nil
           } = Scheduler.status(pid)
  end

  test "run_now reports no runnable decommission job" do
    pid = start_scheduler!(enabled: false)

    assert {:error, :no_runnable_job} = Scheduler.run_now(pid, [])
    assert %{last_skip_reason: :no_runnable_job} = Scheduler.status(pid)
  end

  test "missing destination fails closed and is logged", ctx do
    {:ok, job} = Jobs.start_decommission(0, topology: ctx.topology, include_drive_stats: false)

    pid = start_scheduler!(enabled: false, topology: ctx.topology, auto_destination: false)

    log =
      capture_log(fn ->
        assert {:error, :missing_destination_set_id} = Scheduler.run_now(pid, [])
      end)

    assert log =~ "rebalance scheduler pass skipped"
    assert log =~ "missing_destination_set_id"

    assert {:ok, unchanged} = Jobs.get(job.id)
    assert unchanged.status == "planned"
    assert unchanged.data_movement_status == "not_started"
    assert is_nil(unchanged.destination_set_id)
    assert unchanged.progress_scanned == 0
  end

  test "run_now selects a planned decommission job and injects mapped destination", ctx do
    parent = self()
    {:ok, job} = Jobs.start_decommission(0, topology: ctx.topology, include_drive_stats: false)
    job_id = job.id

    pid =
      start_scheduler!(
        enabled: false,
        topology: ctx.topology,
        destination_sets: %{0 => 1},
        copy_runner: fn job_id, opts ->
          send(parent, {:copy_runner, job_id, opts})
          {:ok, %{status: :partial, job_id: job_id}}
        end
      )

    assert {:ok, %{phase: :copy, scheduler: true, status: :partial}} = Scheduler.run_now(pid, [])
    assert_receive {:copy_runner, ^job_id, opts}
    assert Keyword.fetch!(opts, :destination_set_id) == 1
    assert Keyword.fetch!(opts, :topology) == ctx.topology
  end

  test "run_now asks runner for auto destination when no explicit mapping exists", ctx do
    parent = self()
    {:ok, job} = Jobs.start_decommission(0, topology: ctx.topology, include_drive_stats: false)
    job_id = job.id

    pid =
      start_scheduler!(
        enabled: false,
        topology: ctx.topology,
        copy_runner: fn job_id, opts ->
          send(parent, {:copy_runner, job_id, opts})
          {:ok, %{status: :partial, job_id: job_id}}
        end
      )

    assert {:ok, %{phase: :copy, scheduler: true, status: :partial}} = Scheduler.run_now(pid, [])
    assert_receive {:copy_runner, ^job_id, opts}
    assert Keyword.fetch!(opts, :auto_destination)
    assert Keyword.fetch!(opts, :topology) == ctx.topology
  end

  test "later failure clears last successful result", ctx do
    {:ok, _job} = Jobs.start_decommission(0, topology: ctx.topology, include_drive_stats: false)

    pid =
      start_scheduler!(
        enabled: false,
        topology: ctx.topology,
        destination_set_id: 1,
        copy_runner: fn job_id, _opts -> {:ok, %{status: :partial, job_id: job_id}} end
      )

    assert {:ok, %{phase: :copy}} = Scheduler.run_now(pid, [])
    assert %{last_result: %{phase: :copy}, last_skip_reason: nil} = Scheduler.status(pid)

    assert {:error, :boom} = Scheduler.run_now(pid, job_selector: fn _opts -> {:error, :boom} end)
    assert %{last_result: nil, last_skip_reason: :boom} = Scheduler.status(pid)
  end

  test "enabled scheduler runs once and reschedules", ctx do
    parent = self()
    {:ok, _job} = Jobs.start_decommission(0, topology: ctx.topology, include_drive_stats: false)

    pid =
      start_scheduler!(
        enabled: true,
        initial_delay_ms: 0,
        interval_ms: 60_000,
        topology: ctx.topology,
        destination_set_id: 1,
        copy_runner: fn job_id, opts ->
          send(parent, {:scheduled_copy_runner, job_id, opts})
          {:ok, %{status: :partial, job_id: job_id}}
        end
      )

    assert_receive {:scheduled_copy_runner, _job_id, opts}, 1_000
    assert Keyword.fetch!(opts, :destination_set_id) == 1
    _ = :sys.get_state(pid)

    assert %{scheduled?: true, last_result: %{phase: :copy, status: :partial}} =
             Scheduler.status(pid)
  end

  test "held singleton lock skips scheduler run before invoking runner", ctx do
    parent = self()
    {:ok, _job} = Jobs.start_decommission(0, topology: ctx.topology, include_drive_stats: false)

    pid =
      start_scheduler!(
        enabled: false,
        topology: ctx.topology,
        destination_set_id: 1,
        copy_runner: fn _job_id, _opts ->
          send(parent, :runner_called)
          {:ok, %{status: :ok}}
        end
      )

    {:ok, lease} = Lock.acquire(@scheduler_lock, nodes: [Node.self()], refresh: false)

    try do
      assert {:error, :lock_unavailable} = Scheduler.run_now(pid, [])
      refute_receive :runner_called, 20
      assert %{last_skip_reason: :lock_unavailable} = Scheduler.status(pid)
    after
      Lock.release(lease)
    end
  end

  test "scheduler does not start cleanup while another active job exists", ctx do
    {:ok, decommission} =
      Jobs.start_decommission(0, topology: ctx.topology, include_drive_stats: false)

    {:ok, _running} = Jobs.begin_data_movement(decommission.id, 1)
    {:ok, _complete} = Jobs.complete_data_movement(decommission.id)
    {:ok, _rebalance} = Jobs.start_rebalance(topology: ctx.topology, include_drive_stats: false)

    pid =
      start_scheduler!(
        enabled: false,
        topology: ctx.topology,
        transport: InProcess,
        auto_destination: false,
        destination_sets: %{0 => 1}
      )

    assert {:error, :no_runnable_job} = Scheduler.run_now(pid, [])
    assert {:ok, unchanged} = Jobs.get(decommission.id)
    assert unchanged.source_cleanup_status == "not_started"
  end

  test "auto_source_cleanup false does not start cleanup", ctx do
    {:ok, job} = Jobs.start_decommission(0, topology: ctx.topology, include_drive_stats: false)
    {:ok, _running} = Jobs.begin_data_movement(job.id, 1)
    {:ok, _complete} = Jobs.complete_data_movement(job.id)

    pid =
      start_scheduler!(
        enabled: false,
        topology: ctx.topology,
        transport: InProcess,
        auto_source_cleanup: false,
        auto_destination: false,
        destination_sets: %{0 => 1}
      )

    assert {:error, :source_cleanup_disabled} = Scheduler.run_now(pid, [])
    assert %{last_result: nil, last_skip_reason: :source_cleanup_disabled} = Scheduler.status(pid)

    assert {:ok, unchanged} = Jobs.get(job.id)
    assert unchanged.status == "complete"
    assert unchanged.source_cleanup_status == "not_started"
    assert unchanged.source_cleanup_scanned == 0
  end

  test "scheduler advances real decommission copy and then source cleanup", ctx do
    bucket = bucket_name("rebalance-scheduler")
    key = key_for_set(bucket, ctx.topology, 0)
    body = "scheduler-copy-cleanup"
    opts = dist_opts(ctx)
    source_opts = Keyword.put(opts, :placement_set_id, 0)
    destination_opts = Keyword.put(opts, :placement_set_id, 1)

    {:ok, _bucket} = Buckets.create(bucket, @owner)
    :ok = Distributed.put_bucket(bucket, opts)
    {:ok, _object} = put_object_version!(bucket, key, "v1", body, source_opts)
    {:ok, job} = Jobs.start_decommission(0, topology: ctx.topology, include_drive_stats: false)

    pid =
      start_scheduler!(
        enabled: false,
        topology: ctx.topology,
        transport: InProcess
      )

    assert {:ok, copy} = Scheduler.run_now(pid, [])
    assert copy.phase == :copy
    assert copy.status == :ok
    assert copy.moved == 1

    assert {:ok, copied_job} = Jobs.get(job.id)
    assert copied_job.status == "complete"
    assert copied_job.data_movement_status == "complete"
    assert copied_job.source_cleanup_status == "not_started"

    assert {:ok, source_stream} = Distributed.get(bucket, key, "v1", nil, source_opts)
    assert IO.iodata_to_binary(Enum.to_list(source_stream)) == body

    assert {:ok, cleanup} = Scheduler.run_now(pid, [])
    assert cleanup.phase == :source_cleanup
    assert cleanup.status == :ok
    assert cleanup.deleted == 1
    assert cleanup.source_cleanup_status == "complete"

    assert {:ok, destination_stream} = Distributed.get(bucket, key, "v1", nil, destination_opts)
    assert IO.iodata_to_binary(Enum.to_list(destination_stream)) == body
    assert {:error, :enoent} = Distributed.get(bucket, key, "v1", nil, source_opts)

    assert {:ok, finished} = Jobs.get(job.id)
    assert finished.status == "complete"
    assert finished.data_movement_status == "complete"
    assert finished.source_cleanup_status == "complete"
  end

  defp start_scheduler!(opts) do
    start_supervised!({Scheduler, Keyword.merge([name: nil, lock_nodes: [Node.self()]], opts)})
  end

  defp put_object_version!(bucket, key, version_id, body, opts) do
    {:ok, write_result} = Distributed.put(bucket, key, version_id, [body], opts)

    Objects.put_version_with_id(
      bucket,
      key,
      version_id,
      %{size: byte_size(body), etag: write_result.etag}
      |> Map.merge(Placement.attrs_from_result(write_result))
    )
  end

  defp dist_opts(ctx), do: [topology: ctx.topology, transport: InProcess]

  defp key_for_set(bucket, topology, set_id) do
    Enum.find_value(0..10_000, fn i ->
      key = "obj-#{set_id}-#{i}.txt"
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
