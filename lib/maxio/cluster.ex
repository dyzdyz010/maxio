defmodule Maxio.Cluster do
  @moduledoc """
  集群成员视图门面（M7）。节点发现/连接由 libcluster（Cluster.Supervisor）+ 分布式 Erlang 负责；
  本模块只读出当前 mesh（Node.self/Node.list）。铁律 2：上层只认本门面，不直连 Node/:erpc。
  单节点 dev：Node.list/0 为空，nodes/0 == [Node.self()]，与多节点 prod 同一代码路径。
  """

  @doc "当前节点（含本机）的全部集群节点列表，已排序（确定性）。"
  @spec nodes() :: [node()]
  def nodes, do: [Node.self() | Node.list()] |> Enum.sort()

  @doc "本节点名。"
  @spec this_node() :: node()
  def this_node, do: Node.self()

  @doc "某节点是否在线（在当前 mesh 中，含本机）。"
  @spec alive?(node()) :: boolean()
  def alive?(node), do: node == Node.self() or node in Node.list()
end
