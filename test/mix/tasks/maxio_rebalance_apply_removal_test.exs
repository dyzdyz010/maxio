defmodule Mix.Tasks.MaxioRebalanceApplyRemovalTest do
  use Maxio.DataCase, async: false

  import ExUnit.CaptureIO

  alias Maxio.Buckets
  alias Maxio.Cluster.{Placement, Rebalance.Jobs, Topology}
  alias Maxio.Storage.Distributed
  alias Mix.Tasks.Maxio.Rebalance.ApplyRemoval

  @owner "arn:aws:iam:::root"
  @task "maxio.rebalance.apply_removal"
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

  test "requires explicit confirmation before mutating runtime topology" do
    assert_raise Mix.Error, ~r/requires --yes/, fn ->
      ApplyRemoval.run(["--job-id", "job-id"])
    end
  end

  test "prints runtime topology removal apply report and records job audit" do
    {topology, base} = topology()
    on_exit(fn -> File.rm_rf(base) end)
    :persistent_term.put(@topology_key, topology)
    complete = completed_empty_decommission!("apply-removal-cli-ready")
    expected_hash = Placement.topology_hash(topology)

    output =
      capture_io(fn ->
        ApplyRemoval.run([
          "--job-id",
          complete.id,
          "--expected-current-topology-hash",
          expected_hash,
          "--yes"
        ])
      end)

    assert output =~ "[maxio rebalance.apply_removal]"
    assert output =~ "status=applied"
    assert output =~ "apply_scope=runtime_local"
    assert output =~ "removed_set_id=0"
    assert output =~ "topology_mutation=runtime_local"
    assert output =~ "deployment_config_mutation=false"
    assert output =~ "[maxio rebalance.apply_removal.config]"
    assert Topology.all_set_ids() == [1]

    assert {:ok, updated} = Jobs.get(complete.id)
    assert updated.topology_removal_status == "runtime_local_applied"
    assert updated.topology_removal_scope == "runtime_local"
    assert updated.topology_removal_current_hash == expected_hash
    assert updated.topology_removal_proposed_hash
  end

  test "json output includes runtime scope, proposed config, and audit view" do
    {topology, base} = topology()
    on_exit(fn -> File.rm_rf(base) end)
    :persistent_term.put(@topology_key, topology)
    complete = completed_empty_decommission!("apply-removal-cli-json")

    output =
      capture_io(fn ->
        ApplyRemoval.run(["--job-id", complete.id, "--yes", "--json"])
      end)

    decoded = Jason.decode!(output)
    assert decoded["status"] == "applied"
    assert decoded["apply_scope"] == "runtime_local"
    assert decoded["topology_mutation"] == "runtime_local"
    assert decoded["deployment_config_mutation"] == false
    assert decoded["removed_set_id"] == 0
    assert decoded["proposed_set_ids"] == [1]
    assert decoded["job"]["topology_removal_status"] == "runtime_local_applied"
    assert decoded["job"]["topology_removal_scope"] == "runtime_local"

    assert [%{"id" => 0, "sets" => [%{"id" => 1, "endpoints" => endpoints}]}] =
             decoded["proposed_config"]["pools"]

    assert Enum.map(endpoints, & &1["drive"]) == [
             Path.join(base, "s1d0"),
             Path.join(base, "s1d1")
           ]
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
        "maxio_rebalance_apply_removal_cli_#{System.unique_integer([:positive])}"
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
