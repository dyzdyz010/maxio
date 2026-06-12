defmodule Maxio.Cluster.PeerLockTest do
  @moduledoc """
  M8 peer evidence for the quorum lease lock.

  These tests are tagged `:distributed` and excluded from the default suite. They
  start true `:peer` BEAM nodes and exercise `Maxio.Cluster.Lock` through real
  `:erpc` calls to per-node `Maxio.Cluster.LockServer` processes.
  """
  use ExUnit.Case, async: false
  @moduletag :distributed

  if System.get_env("MAXIO_RUN_PEER_LOCK") != "1" do
    @moduletag skip:
                 "set MAXIO_RUN_PEER_LOCK=1 and run with --include distributed to collect true peer lock evidence"
  end

  alias Maxio.Cluster.{Lock, Paths, Scrubber, Topology, Transport.Erpc}
  alias Maxio.Cluster.Scrubber.Usage
  alias Maxio.{Buckets, Objects}
  alias Maxio.Storage.Distributed

  @owner "arn:aws:iam:::root"

  setup do
    case ensure_distribution() do
      :ok ->
        :ok = :net_kernel.monitor_nodes(true)

        case start_peers() do
          {:ok, peers} ->
            peer_nodes = Enum.map(peers, fn {_pid, node} -> node end)
            nodes = [Node.self() | peer_nodes]

            base =
              Path.join(
                System.tmp_dir!(),
                "maxio_peer_lock_#{System.unique_integer([:positive])}"
              )

            for node <- peer_nodes do
              :ok = :erpc.call(node, :code, :add_paths, [:code.get_path()])
              {:ok, _pid} = :erpc.call(node, Maxio.Cluster.LockServer, :start_link, [[]])
              {:ok, _pid} = :erpc.call(node, Maxio.Cluster.ShardServer, :start_link, [[]])
            end

            endpoints =
              for i <- 0..5 do
                node = Enum.at(nodes, div(i, 2))
                {node, Path.join(base, "#{node}_d#{rem(i, 2)}")}
              end

            topology =
              Topology.parse_and_validate!(
                data_shards: 4,
                parity_shards: 2,
                block_size: 1024,
                allow_colocated_endpoints: true,
                pools: [%{id: 0, sets: [%{id: 0, endpoints: endpoints}]}]
              )

            on_exit(fn ->
              Usage.clear()
              Enum.each(peers, fn {pid, _node} -> :peer.stop(pid) end)
              File.rm_rf(base)
            end)

            Usage.clear()

            {:ok,
             skip: false, nodes: nodes, peers: peers, endpoints: endpoints, topology: topology}

          {:error, reason} ->
            {:ok, skip: {:no_peer, reason}}
        end

      {:error, reason} ->
        {:ok, skip: {:no_distribution, reason}}
    end
  end

  defp ensure_distribution do
    start_result =
      case Node.start(:"maxio_primary@127.0.0.1", :longnames) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
        {:error, reason} -> {:error, reason}
      end

    if start_result == :ok and Node.alive?() do
      Node.set_cookie(:maxio_test_cookie)
      :ok
    else
      {:error, {start_result, Node.self(), Node.alive?()}}
    end
  end

  test "quorum write lock excludes competitors across true peer LockServers", ctx do
    cond do
      match?({:no_distribution, _reason}, ctx.skip) ->
        {:no_distribution, reason} = ctx.skip

        flunk(
          "distributed Erlang is unavailable; peer lock evidence was not collected: #{inspect(reason)}"
        )

      match?({:no_peer, _reason}, ctx.skip) ->
        {:no_peer, reason} = ctx.skip
        flunk(":peer startup failed; peer lock evidence was not collected: #{inspect(reason)}")

      true ->
        resource = {:peer_lock, System.unique_integer([:positive])}
        lock_opts = [nodes: ctx.nodes, refresh: false, timeout: 1_000]

        {:ok, lease} = Lock.acquire(resource, lock_opts)

        try do
          assert {:error, :no_quorum} = Lock.acquire(resource, lock_opts)
        after
          :ok = Lock.release(lease)
        end

        assert {:ok, lease2} = Lock.acquire(resource, lock_opts)
        assert :ok = Lock.release(lease2)
    end
  end

  test "one peer loss still leaves a three-node lock quorum available", ctx do
    cond do
      match?({:no_distribution, _reason}, ctx.skip) ->
        {:no_distribution, reason} = ctx.skip

        flunk(
          "distributed Erlang is unavailable; peer lock evidence was not collected: #{inspect(reason)}"
        )

      match?({:no_peer, _reason}, ctx.skip) ->
        {:no_peer, reason} = ctx.skip
        flunk(":peer startup failed; peer lock evidence was not collected: #{inspect(reason)}")

      true ->
        [{dead_peer, dead_node}, {_live_peer, _live_node}] = ctx.peers
        :ok = :peer.stop(dead_peer)
        assert_receive {:nodedown, ^dead_node}, 5_000

        resource = {:peer_lock_after_down, System.unique_integer([:positive])}

        assert {:ok, lease} =
                 Lock.acquire(resource,
                   nodes: ctx.nodes,
                   refresh: false,
                   timeout: 1_000
                 )

        assert :ok = Lock.release(lease)
    end
  end

  test "scrubber uses set-derived peer LockServers before distributed heal", ctx do
    cond do
      match?({:no_distribution, _reason}, ctx.skip) ->
        {:no_distribution, reason} = ctx.skip

        flunk(
          "distributed Erlang is unavailable; peer scrubber evidence was not collected: #{inspect(reason)}"
        )

      match?({:no_peer, _reason}, ctx.skip) ->
        {:no_peer, reason} = ctx.skip

        flunk(
          ":peer startup failed; peer scrubber evidence was not collected: #{inspect(reason)}"
        )

      true ->
        bucket = bucket_name("m8-peer")
        key = "peer-heal.bin"
        body = :crypto.strong_rand_bytes(3072)
        opts = [topology: ctx.topology, transport: Erpc]
        sandbox = Ecto.Adapters.SQL.Sandbox.start_owner!(Maxio.Repo, shared: true)
        on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(sandbox) end)

        {:ok, _bucket} = Buckets.create(bucket, @owner)
        :ok = Distributed.put_bucket(bucket, opts)
        {:ok, %{size: size, etag: etag}} = Distributed.put(bucket, key, "null", [body], opts)
        put_index!(bucket, key, size, etag)

        missing_part = remove_first_shard!(ctx, bucket, key)
        refute File.exists?(missing_part)

        resource = {:scrubber_set, {:distributed, 0}}
        lock_opts = [nodes: ctx.nodes, refresh: false, timeout: 1_000]
        {:ok, lease} = Lock.acquire(resource, lock_opts)

        try do
          assert {:ok, skipped} =
                   Scrubber.scan_now(
                     bucket: bucket,
                     backend: Distributed,
                     topology: ctx.topology,
                     transport: Erpc,
                     no_throttle: true
                   )

          assert skipped.scanned == 0
          assert skipped.skipped == 1
          assert skipped.healed == 0
          refute File.exists?(missing_part)
        after
          :ok = Lock.release(lease)
        end

        assert {:ok, healed} =
                 Scrubber.scan_now(
                   bucket: bucket,
                   backend: Distributed,
                   topology: ctx.topology,
                   transport: Erpc,
                   no_throttle: true
                 )

        assert healed.scanned == 1
        assert healed.healed == 1
        assert File.exists?(missing_part)

        {:ok, stream} = Distributed.get(bucket, key, "null", nil, opts)
        assert IO.iodata_to_binary(Enum.to_list(stream)) == body
    end
  end

  defp start_peers do
    try do
      {:ok, p1, n1} = start_peer(:maxio_lock_peer1)
      {:ok, p2, n2} = start_peer(:maxio_lock_peer2)
      {:ok, [{p1, n1}, {p2, n2}]}
    rescue
      e -> {:error, {:exception, e, Node.self(), Node.alive?()}}
    catch
      kind, reason -> {:error, {kind, reason, Node.self(), Node.alive?()}}
    end
  end

  defp start_peer(name) do
    {:ok, pid, node} =
      :peer.start_link(%{
        name: name,
        host: ~c"127.0.0.1",
        longnames: true,
        args: [~c"-setcookie", ~c"maxio_test_cookie"]
      })

    {:ok, pid, node}
  end

  defp remove_first_shard!(ctx, bucket, key) do
    {:ok, rel} = Paths.object_rel(bucket, key, "null")
    {_node, first_drive} = hd(ctx.endpoints)
    object_dir = Path.join(first_drive, rel)
    part = Path.join(object_dir, "part.0")
    File.rm_rf!(object_dir)
    part
  end

  defp put_index!(bucket, key, size, etag) do
    {:ok, object} =
      Objects.put_version_with_id(bucket, key, "null", %{
        size: size,
        etag: etag,
        content_type: "application/octet-stream"
      })

    object
  end

  defp bucket_name(prefix) do
    suffix =
      System.unique_integer([:positive])
      |> Integer.to_string()
      |> String.replace("-", "")

    "#{prefix}-#{suffix}"
  end
end
