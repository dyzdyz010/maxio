defmodule Mix.Tasks.Maxio.Rebalance.PlanTest do
  use Maxio.DataCase, async: false

  import ExUnit.CaptureIO

  alias Maxio.{Buckets, Objects}
  alias Maxio.Cluster.{Router, Topology}
  alias Mix.Tasks.Maxio.Rebalance.Plan

  @owner "arn:aws:iam:::root"
  @task "maxio.rebalance.plan"
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

  test "prints text summary and per-set rows" do
    topology = topology()
    :persistent_term.put(@topology_key, topology)

    bucket = bucket_name("rebalance-cli")
    {:ok, _bucket} = Buckets.create(bucket, @owner)
    key = key_for_set(bucket, topology, 0)
    {:ok, _} = Objects.put_version_with_id(bucket, key, "null", %{size: 9, etag: "e9"})

    output = run_task(["--no-drive-stats"])

    assert output =~ "[maxio rebalance.plan] status=ok scope=versions"
    assert output =~ "topology_sets=2"
    assert output =~ "buckets=1"
    assert output =~ "objects=1"
    assert output =~ "versions=1"
    assert output =~ "placement_fallbacks=1"
    assert output =~ "bytes=9"
    assert output =~ "drive_status=disabled"
    assert output =~ "[maxio rebalance.set] set_id=0"
    assert output =~ "[maxio rebalance.set] set_id=1"
  end

  test "prints JSON for automation" do
    topology = topology()
    :persistent_term.put(@topology_key, topology)

    bucket = bucket_name("rebalance-json")
    {:ok, _bucket} = Buckets.create(bucket, @owner)
    key = key_for_set(bucket, topology, 1)
    {:ok, _} = Objects.put_version_with_id(bucket, key, "null", %{size: 5, etag: "e5"})

    report =
      ["--no-drive-stats", "--json", "--current-only"]
      |> run_task()
      |> Jason.decode!()

    assert report["status"] == "ok"
    assert report["scope"] == "current_only"
    assert report["topology_sets"] == 2
    assert report["objects"] == 1
    assert report["versions"] == 1
    assert report["placement_fallbacks"] == 1
    assert report["bytes"] == 5
    assert is_list(report["per_set"])
  end

  test "unknown decommission set raises usage-facing error" do
    topology = topology()
    :persistent_term.put(@topology_key, topology)

    assert_raise Mix.Error, ~r/unknown --decommission-set 99/, fn ->
      Plan.run(["--decommission-set", "99", "--no-drive-stats"])
    end
  end

  defp run_task(args) do
    Mix.Task.reenable(@task)
    capture_io(fn -> Plan.run(args) end)
  end

  defp topology do
    base = Path.join(System.tmp_dir!(), "maxio_rebalance_plan_cli")

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
      key = "cli-#{set_id}-#{i}.txt"
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
