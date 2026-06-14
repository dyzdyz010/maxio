defmodule Mix.Tasks.MaxioRebalancePlanRemovalTest do
  use Maxio.DataCase, async: false

  import ExUnit.CaptureIO

  alias Maxio.Buckets
  alias Maxio.Cluster.{Rebalance.Jobs, Topology}
  alias Maxio.Storage.Distributed
  alias Mix.Tasks.Maxio.Rebalance.PlanRemoval

  @owner "arn:aws:iam:::root"
  @task "maxio.rebalance.plan_removal"
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

  test "prints proposed topology removal artifact for a completed decommission job" do
    {topology, base} = topology()
    on_exit(fn -> File.rm_rf(base) end)
    :persistent_term.put(@topology_key, topology)
    complete = completed_empty_decommission!("plan-removal-cli-ready")

    output =
      capture_io(fn ->
        PlanRemoval.run(["--job-id", complete.id])
      end)

    assert output =~ "[maxio rebalance.plan_removal]"
    assert output =~ "status=ready"
    assert output =~ "removed_set_id=0"
    assert output =~ "current_topology_hash="
    assert output =~ "proposed_topology_hash="
    assert output =~ "topology_mutation=false"
    assert output =~ "[maxio rebalance.plan_removal.config]"
    assert output =~ "sets: [%{id: 1, endpoints:"
  end

  test "json output includes proposed topology and hashes" do
    {topology, base} = topology()
    on_exit(fn -> File.rm_rf(base) end)
    :persistent_term.put(@topology_key, topology)
    complete = completed_empty_decommission!("plan-removal-cli-json")

    output =
      capture_io(fn ->
        PlanRemoval.run(["--job-id", complete.id, "--json"])
      end)

    decoded = Jason.decode!(output)
    assert decoded["status"] == "ready"
    assert decoded["removed_set_id"] == 0
    assert decoded["current_topology_hash"] != decoded["proposed_topology_hash"]
    assert decoded["current_set_ids"] == [0, 1]
    assert decoded["proposed_set_ids"] == [1]
    assert decoded["topology_mutation"] == false
    assert decoded["proposed_config"]["allow_colocated_endpoints"] == true

    assert [%{"id" => 0, "sets" => [%{"id" => 1, "endpoints" => endpoints}]}] =
             decoded["proposed_config"]["pools"]

    assert Enum.map(endpoints, & &1["node"]) == [
             Atom.to_string(Node.self()),
             Atom.to_string(Node.self())
           ]

    assert Enum.map(endpoints, & &1["drive"]) == [
             Path.join(base, "s1d0"),
             Path.join(base, "s1d1")
           ]
  end

  test "raises when preflight is blocked" do
    {topology, base} = topology()
    on_exit(fn -> File.rm_rf(base) end)
    :persistent_term.put(@topology_key, topology)
    bucket = bucket_name("plan-removal-cli-blocked")
    {:ok, _bucket} = Buckets.create(bucket, @owner)
    :ok = Distributed.put_bucket(bucket)
    {:ok, job} = Jobs.start_decommission(0, include_drive_stats: false)

    assert_raise Mix.Error, ~r/topology removal preflight is blocked/, fn ->
      PlanRemoval.run(["--job-id", job.id])
    end
  end

  defp completed_empty_decommission!(prefix) do
    bucket = bucket_name(prefix)
    {:ok, _bucket} = Buckets.create(bucket, @owner)
    :ok = Distributed.put_bucket(bucket)
    {:ok, job} = Jobs.start_decommission(0, include_drive_stats: false)
    {:ok, _running} = Jobs.begin_data_movement(job.id, 1)
    {:ok, complete} = Jobs.complete_data_movement(job.id)
    {:ok, cleaning} = Jobs.begin_source_cleanup(complete.id)
    {:ok, complete} = Jobs.complete_source_cleanup(cleaning.id)
    complete
  end

  defp topology do
    base =
      Path.join(
        System.tmp_dir!(),
        "maxio_rebalance_plan_removal_cli_#{System.unique_integer([:positive])}"
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

    {topology, base}
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
