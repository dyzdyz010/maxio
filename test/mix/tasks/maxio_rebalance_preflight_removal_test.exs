defmodule Mix.Tasks.MaxioRebalancePreflightRemovalTest do
  use Maxio.DataCase, async: false

  import ExUnit.CaptureIO

  alias Maxio.Buckets
  alias Maxio.Cluster.{Rebalance.Jobs, Topology}
  alias Maxio.Storage.Distributed
  alias Mix.Tasks.Maxio.Rebalance.PreflightRemoval

  @owner "arn:aws:iam:::root"
  @task "maxio.rebalance.preflight_removal"
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

  test "prints ready removal preflight for a completed decommission job" do
    topology = topology()
    :persistent_term.put(@topology_key, topology)
    bucket = bucket_name("preflight-cli-ready")
    {:ok, _bucket} = Buckets.create(bucket, @owner)
    :ok = Distributed.put_bucket(bucket)
    {:ok, job} = Jobs.start_decommission(0, include_drive_stats: false)
    {:ok, _running} = Jobs.begin_data_movement(job.id, 1)
    {:ok, complete} = Jobs.complete_data_movement(job.id)
    {:ok, cleaning} = Jobs.begin_source_cleanup(complete.id)
    {:ok, complete} = Jobs.complete_source_cleanup(cleaning.id)

    output =
      capture_io(fn ->
        PreflightRemoval.run(["--job-id", complete.id])
      end)

    assert output =~ "[maxio rebalance.preflight_removal]"
    assert output =~ "status=ready"
    assert output =~ "removable=true"
    assert output =~ "topology_mutation=false"
  end

  test "json output reports blocked preflight without raising" do
    topology = topology()
    :persistent_term.put(@topology_key, topology)
    bucket = bucket_name("preflight-cli-blocked")
    {:ok, _bucket} = Buckets.create(bucket, @owner)
    :ok = Distributed.put_bucket(bucket)
    {:ok, job} = Jobs.start_decommission(0, include_drive_stats: false)

    output =
      capture_io(fn ->
        PreflightRemoval.run(["--job-id", job.id, "--json"])
      end)

    decoded = Jason.decode!(output)
    assert decoded["status"] == "blocked"
    assert decoded["removable"] == false
    assert "job_not_complete" in decoded["blockers"]
    assert decoded["topology_mutation"] == false
  end

  defp topology do
    base =
      Path.join(
        System.tmp_dir!(),
        "maxio_rebalance_preflight_cli_#{System.unique_integer([:positive])}"
      )

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
