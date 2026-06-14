defmodule Maxio.Cluster.TopologyStoreTest do
  use Maxio.DataCase, async: false

  alias Maxio.Cluster.{Topology, TopologyRevision, TopologyStore}
  alias Maxio.Repo

  @topology_key {Maxio.Cluster.Topology, :topology}

  setup do
    previous_source = Application.get_env(:maxio, :topology_source, :__maxio_no_topology_source__)
    previous_topology = :persistent_term.get(@topology_key, :__maxio_no_topology__)

    on_exit(fn ->
      restore_topology_source(previous_source)
      restore_topology(previous_topology)
    end)

    :ok
  end

  test "encodes and decodes a topology revision config without changing the hash" do
    topology = topology("codec")
    hash = Topology.fingerprint(topology)

    assert {:ok, config} = TopologyStore.encode_config(topology)
    assert [%{"sets" => [%{"endpoints" => [%{"node" => node_name} | _]} | _]}] = config["pools"]
    assert node_name == Atom.to_string(Node.self())

    assert {:ok, decoded} = TopologyStore.decode_config(config)
    assert Topology.fingerprint(decoded) == hash
    assert Topology.to_config(decoded) == Topology.to_config(topology)
  end

  test "activates one topology revision and supersedes the previous active revision" do
    topology1 = topology("active-1")
    topology2 = topology("active-2")

    assert {:ok, revision1} =
             TopologyStore.activate_topology(topology1,
               expected_topology_hash: Topology.fingerprint(topology1),
               source: "operator"
             )

    assert revision1.status == "active"

    assert {:ok, revision2} =
             TopologyStore.activate_topology(topology2,
               expected_topology_hash: Topology.fingerprint(topology2),
               source: "operator"
             )

    assert revision2.status == "active"
    assert revision2.id != revision1.id

    assert {:ok, active} = TopologyStore.active_topology()
    assert Topology.fingerprint(active) == Topology.fingerprint(topology2)

    assert %TopologyRevision{status: "superseded"} = Repo.get!(TopologyRevision, revision1.id)
    assert %TopologyRevision{status: "active"} = Repo.get!(TopologyRevision, revision2.id)
  end

  test "activation refuses a stale expected topology hash" do
    topology = topology("stale")

    assert {:error, {:topology_revision_expected_hash_mismatch, "stale", actual}} =
             TopologyStore.activate_topology(topology,
               expected_topology_hash: "stale",
               source: "operator"
             )

    assert actual == Topology.fingerprint(topology)
    assert {:error, :no_active_topology_revision} = TopologyStore.active_revision()
  end

  test "active topology load fails when stored hash does not match config" do
    topology = topology("hash-mismatch")
    {:ok, config} = TopologyStore.encode_config(topology)
    stored = String.duplicate("0", 64)

    %TopologyRevision{}
    |> TopologyRevision.changeset(%{
      status: "active",
      topology_hash: stored,
      config: config,
      source: "operator",
      activated_at: DateTime.utc_now()
    })
    |> Repo.insert!()

    assert {:error, {:topology_revision_hash_mismatch, ^stored, actual}} =
             TopologyStore.active_topology()

    assert actual == Topology.fingerprint(topology)
  end

  test "idempotent activation validates an existing active row with the same hash" do
    topology = topology("idempotent-corrupt")
    stored = Topology.fingerprint(topology)

    %TopologyRevision{}
    |> TopologyRevision.changeset(%{
      status: "active",
      topology_hash: stored,
      config: %{"bad" => true},
      source: "operator",
      activated_at: DateTime.utc_now()
    })
    |> Repo.insert!()

    assert {:error, {:invalid_topology_revision_config, _reason}} =
             TopologyStore.activate_topology(topology,
               expected_topology_hash: stored,
               source: "operator"
             )
  end

  test "Topology init loads the active revision when DB source is configured" do
    topology = topology("db-init")
    Application.put_env(:maxio, :topology_source, :db)

    assert {:ok, _revision} =
             TopologyStore.activate_topology(topology,
               expected_topology_hash: Topology.fingerprint(topology),
               source: "operator"
             )

    assert {:ok, loaded} = Topology.init(:ok)
    assert Topology.fingerprint(loaded) == Topology.fingerprint(topology)
    assert {:ok, runtime_topology} = Topology.current()
    assert Topology.fingerprint(runtime_topology) == Topology.fingerprint(topology)
  end

  test "Topology init fails closed when DB source has no active revision" do
    :persistent_term.put(@topology_key, topology("stale-runtime"))
    Application.put_env(:maxio, :topology_source, :db)

    assert {:stop, {:db_topology_unavailable, :no_active_topology_revision}} = Topology.init(:ok)
    assert {:error, :no_topology} = Topology.current()
  end

  defp topology(prefix) do
    base =
      Path.join(
        System.tmp_dir!(),
        "maxio_topology_store_#{prefix}_#{System.unique_integer([:positive])}"
      )

    endpoints0 = for i <- 0..1, do: {Node.self(), Path.join(base, "s0d#{i}")}
    endpoints1 = for i <- 0..1, do: {Node.self(), Path.join(base, "s1d#{i}")}

    Topology.parse_and_validate!(
      data_shards: 1,
      parity_shards: 1,
      block_size: 1024,
      allow_colocated_endpoints: true,
      pools: [
        %{id: 0, sets: [%{id: 0, endpoints: endpoints0}, %{id: 1, endpoints: endpoints1}]}
      ]
    )
  end

  defp restore_topology_source(:__maxio_no_topology_source__),
    do: Application.delete_env(:maxio, :topology_source)

  defp restore_topology_source(source),
    do: Application.put_env(:maxio, :topology_source, source)

  defp restore_topology(:__maxio_no_topology__), do: :persistent_term.erase(@topology_key)
  defp restore_topology(topology), do: :persistent_term.put(@topology_key, topology)
end
