defmodule Maxio.S3.PoolWritePolicyErrorTest do
  use Maxio.DataCase, async: false

  alias Maxio.Cluster.Topology
  alias Maxio.Cluster.Transport.InProcess
  alias Maxio.S3.Endpoint
  alias Maxio.Test.SigV4Request

  @topology_key {Maxio.Cluster.Topology, :topology}

  defmodule WriteRoutingErrorBackend do
    def put(_bucket, _key, _version_id, _chunks, _opts),
      do: {:error, {:decommission_write_route_cycle, 0, 1}}
  end

  setup do
    InProcess.setup!()

    base =
      Path.join(
        System.tmp_dir!(),
        "maxio_s3_pool_write_policy_#{System.unique_integer([:positive])}"
      )

    topology = topology(base)

    previous_topology = :persistent_term.get(@topology_key, :__maxio_no_topology__)
    previous_backend = Application.get_env(:maxio, :storage_backend)
    previous_transport = Application.get_env(:maxio, :shard_transport)
    previous_policy = Application.get_env(:maxio, :pool_write_policy)
    previous_drive_stats = Application.get_env(:maxio, :drive_stats)

    :persistent_term.put(@topology_key, topology)
    Application.put_env(:maxio, :storage_backend, Maxio.Storage.Distributed)
    Application.put_env(:maxio, :shard_transport, InProcess)
    Application.put_env(:maxio, :pool_write_policy, mode: :weighted_free_space)

    Application.put_env(:maxio, :drive_stats,
      provider: fn drive ->
        if String.contains?(drive, "pool7") do
          {:error, :drive_unavailable}
        else
          {:ok,
           %{
             capacity_bytes: 10_000,
             free_bytes: 8_000,
             source: :test,
             precision: :exact
           }}
        end
      end
    )

    on_exit(fn ->
      restore_topology(previous_topology)
      restore_env(:storage_backend, previous_backend)
      restore_env(:shard_transport, previous_transport)
      restore_env(:pool_write_policy, previous_policy)
      restore_env(:drive_stats, previous_drive_stats)
      File.rm_rf(base)
    end)

    :ok
  end

  test "PutObject maps incomplete pool telemetry to SlowDownWrite without leaking placement internals" do
    {:ok, _bucket} = Maxio.Buckets.create("poolputerr", "arn:aws:iam:::root")

    response =
      SigV4Request.signed_conn(:put, "/poolputerr/object.txt", body: "payload")
      |> Endpoint.call(Endpoint.init([]))

    assert response.status == 503
    assert response.resp_body =~ "<Code>SlowDownWrite</Code>"
    refute response.resp_body =~ "pool_telemetry_incomplete"
    refute response.resp_body =~ "drive_free_bytes"
    refute response.resp_body =~ "eligible?"
  end

  test "PutObject maps write-routing structural failures without leaking route internals" do
    Application.put_env(:maxio, :storage_backend, WriteRoutingErrorBackend)
    {:ok, _bucket} = Maxio.Buckets.create("routeerr", "arn:aws:iam:::root")

    response =
      SigV4Request.signed_conn(:put, "/routeerr/object.txt", body: "payload")
      |> Endpoint.call(Endpoint.init([]))

    assert response.status == 500
    assert response.resp_body =~ "<Code>InternalError</Code>"
    refute response.resp_body =~ "decommission_write_route_cycle"
    refute response.resp_body =~ "{0, 1}"
  end

  defp topology(base) do
    Topology.parse_and_validate!(
      data_shards: 1,
      parity_shards: 1,
      block_size: 1024,
      allow_colocated_endpoints: true,
      pools: [
        %{id: 0, sets: [set(0, base, "pool0")]},
        %{id: 7, sets: [set(1, base, "pool7")]}
      ]
    )
  end

  defp set(set_id, base, pool_name) do
    %{
      id: set_id,
      endpoints: [
        {Node.self(), Path.join([base, pool_name, "d0"])},
        {Node.self(), Path.join([base, pool_name, "d1"])}
      ]
    }
  end

  defp restore_topology(:__maxio_no_topology__), do: :persistent_term.erase(@topology_key)
  defp restore_topology(topology), do: :persistent_term.put(@topology_key, topology)

  defp restore_env(key, nil), do: Application.delete_env(:maxio, key)
  defp restore_env(key, value), do: Application.put_env(:maxio, key, value)
end
