defmodule Maxio.Cluster.PeerClusterTest do
  @moduledoc """
  :peer 真节点集成测试（M7-5）。起真实额外 BEAM 节点，跑真 :erpc 的 Maxio.Cluster.Transport.Erpc，
  验证真宕机（:erpc :noconnection）-> nil 分片 -> EC 重建（K 存活）。

  @moduletag :distributed —— 默认 mix test 排除（见 test_helper.exs 的 ExUnit.configure(exclude:)）；
  单独跑：mix test --include distributed。需 epmd（:net_kernel.start 会按需拉起）+ :peer（OTP 25+）。
  本机 Windows 上 :peer/epmd 可能受防火墙/127.0.0.1 限制——若起不来，setup 探测失败即 skip 整个文件
  （主回归不受影响；确定性主力覆盖在 InProcess 的 cluster_e2e_test/heal_test）。
  """
  use ExUnit.Case, async: false
  @moduletag :distributed

  alias Maxio.Storage.Distributed
  alias Maxio.Cluster.{Topology, Transport.Erpc}

  setup_all do
    # 需分布式：若本节点未起 distribution，起一个具名节点（epmd 须可用）。
    distributed_ok =
      case :net_kernel.start([:"maxio_primary@127.0.0.1", :longnames]) do
        {:ok, _} -> true
        {:error, {:already_started, _}} -> true
        {:error, _} -> false
      end

    if distributed_ok do
      Node.set_cookie(:maxio_test_cookie)
      {:ok, distributed: true}
    else
      # epmd 不可用 / 起 distribution 失败 -> 整个文件 skip。
      {:ok, distributed: false}
    end
  end

  setup %{distributed: distributed} do
    if not distributed do
      {:ok, skip: :no_distribution}
    else
      :ok = :net_kernel.monitor_nodes(true)
      base = Path.join(System.tmp_dir!(), "maxio_peer_#{System.unique_integer([:positive])}")

      # 起 2 个 :peer 节点（OTP 25+ :peer 替代 :slave）。本机 + 2 peer = 3 node，N=6 端点每 node 2 drive。
      case start_peers() do
        {:ok, [{p1, n1}, {p2, n2}]} ->
          nodes = [Node.self(), n1, n2]

          # 各 peer 节点加载本节点代码路径 + 起 ShardServer（被 :erpc 寻址的本机分片 IO 服务）。
          for n <- [n1, n2] do
            :ok = :erpc.call(n, :code, :add_paths, [:code.get_path()])
            {:ok, _} = :erpc.call(n, Maxio.Cluster.ShardServer, :start_link, [[]])
          end

          {:ok, _} = ensure_local_shard_server()

          # N=6 端点：3 node 各 2 drive。索引 i -> 第 div(i,2) 个 node 的第 rem(i,2) 个 drive。
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
              # 3 node × 2 drive 同 node 名复用，放行 distinct-node 校验（B1-3）。
              allow_colocated_endpoints: true,
              pools: [%{id: 0, sets: [%{id: 0, endpoints: endpoints}]}]
            )

          on_exit(fn ->
            :peer.stop(p1)
            :peer.stop(p2)
            File.rm_rf(base)
          end)

          {:ok,
           base: base, topology: topology, peers: [p1, p2], nodes: nodes, peer_nodes: [n1, n2]}

        :error ->
          {:ok, skip: :no_peer}
      end
    end
  end

  defp opts(ctx), do: [topology: ctx.topology, transport: Erpc]

  # 起 2 个 peer；任何一步失败（含 ArgumentError/ErlangError）-> :error（触发 skip）。
  defp start_peers do
    try do
      {:ok, p1, n1} = start_peer(:maxio_peer1)
      {:ok, p2, n2} = start_peer(:maxio_peer2)
      {:ok, [{p1, n1}, {p2, n2}]}
    rescue
      _ -> :error
    catch
      _, _ -> :error
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

  defp ensure_local_shard_server do
    case Process.whereis(Maxio.Cluster.ShardServer) do
      nil -> Maxio.Cluster.ShardServer.start_link([])
      pid -> {:ok, pid}
    end
  end

  test "PUT/GET 跨真 peer，杀一个 peer，GET 仍重建（K 存活）", ctx do
    cond do
      Map.get(ctx, :skip) == :no_distribution ->
        # epmd/distribution 不可用：跳过（主力覆盖在 InProcess）。
        assert true

      Map.get(ctx, :skip) == :no_peer ->
        # 本机起 :peer 失败（Windows 防火墙/127.0.0.1 限制）：跳过。
        assert true

      true ->
        o = opts(ctx)
        body = :crypto.strong_rand_bytes(3000)
        {:ok, _} = Distributed.put("b", "k", "null", [body], o)

        [n1, _n2] = ctx.peer_nodes
        [p1, _] = ctx.peers

        # 真宕机：杀 peer1 -> 其 2 个端点 :erpc :noconnection -> nil 分片。
        # N=6, 杀 1 node = 丢 2 分片 = M，仍 >= K，GET 经 RS 重建仍正确。
        :ok = :peer.stop(p1)
        assert_receive {:nodedown, ^n1}, 5_000

        {:ok, s} = Distributed.get("b", "k", "null", nil, o)
        assert IO.iodata_to_binary(Enum.to_list(s)) == body
    end
  end
end
