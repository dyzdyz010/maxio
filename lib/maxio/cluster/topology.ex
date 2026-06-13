defmodule Maxio.Cluster.Topology do
  @moduledoc """
  静态部署拓扑（M7）：pools -> erasure sets -> 有序 N 个 {node, drive} 端点。索引 i = 分片 i 归属。
  启动期解析+校验 config（每 set endpoints 数 == K+M；M <= N/2），存 :persistent_term 供 O(1) 读。
  铁律 3：非法拓扑 raise，绝不带病启动。

  test 注入：parse_and_validate!/1 直接喂 config map 得 parsed struct；后端 callback 接受
  opts[:topology] 覆盖 :persistent_term，故无需真集群即可在 ExUnit 注入任意拓扑。
  """
  use GenServer

  @type set_id :: non_neg_integer()
  @type pool_id :: non_neg_integer()
  @type endpoint :: {node(), String.t()}
  @type t :: %{
          data_shards: pos_integer(),
          parity_shards: pos_integer(),
          block_size: pos_integer(),
          pools: %{pool_id() => %{id: pool_id(), set_ids: [set_id()]}},
          pool_ids: [pool_id()],
          sets: %{set_id() => %{id: set_id(), pool_id: pool_id(), endpoints: [endpoint()]}},
          set_ids: [set_id()]
        }

  @pt_key {__MODULE__, :topology}

  def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    case Application.get_env(:maxio, __MODULE__) do
      nil ->
        # 无拓扑配置（单节点 dev / FS 后端 / test）—— 不解析、不存 pt，门面读时回 :no_topology。
        {:ok, :no_topology}

      cfg ->
        parsed = parse_and_validate!(cfg)
        :persistent_term.put(@pt_key, parsed)
        {:ok, parsed}
    end
  end

  # ── 读 API（prod 走 :persistent_term；test 经 *_from/*_with 注入 parsed）──

  @doc """
  是否已配置分布式拓扑（:persistent_term 已存 parsed）。门面（如 ObjectMeta dual-read shadow）据此
  判断「当前部署是否真有 sidecar-backed 分布式拓扑」——无拓扑（单机 FS / dev / test）时短路，绝不调用
  会 raise 的 `get/0`。与 `get/0` 读同一 :persistent_term，是「拓扑是否存在」的单一事实来源。
  """
  @spec configured?() :: boolean()
  def configured?, do: :persistent_term.get(@pt_key, :no_topology) != :no_topology

  @doc "所有 set_id（按 pool 顺序 + set 顺序展平）的全局有序列表。路由 mod 用其长度。"
  @spec all_set_ids() :: [set_id()]
  def all_set_ids, do: get().set_ids

  @doc "所有 pool_id（按部署配置顺序）。"
  @spec pool_ids() :: [pool_id()]
  def pool_ids, do: pool_ids_from(get())

  @doc "某 pool 下的 set_id 列表（按部署配置顺序）。"
  @spec set_ids_for_pool(pool_id()) :: [set_id()]
  def set_ids_for_pool(pool_id), do: set_ids_for_pool_from(get(), pool_id)

  @doc "某 set 所属 pool_id。"
  @spec pool_id_for_set(set_id()) :: pool_id()
  def pool_id_for_set(set_id), do: pool_id_for_set_from(get(), set_id)

  @doc "某 set 的 N 个有序 {node,drive} 端点（索引 i = 分片 i）。"
  @spec endpoints(set_id()) :: [endpoint()]
  def endpoints(set_id), do: endpoints_from(get(), set_id)

  @doc "EC 参数（K/M/block_size），喂给 Maxio.Storage.Erasure.Config.load!/1。"
  @spec ec_params() :: keyword()
  def ec_params, do: ec_params_from(get())

  @doc "本节点在某 set 中负责的本地 drive 列表（端点 node == Node.self()）。"
  @spec local_drives_for_set(set_id()) :: [String.t()]
  def local_drives_for_set(set_id), do: local_drives_from(get(), set_id, Node.self())

  # ── 纯函数（test 注入 parsed；prod 经上面读 pt 调这些）──

  @spec all_set_ids_from(t()) :: [set_id()]
  def all_set_ids_from(%{set_ids: ids}), do: ids

  @spec pool_ids_from(t() | map()) :: [pool_id()]
  def pool_ids_from(%{} = topology) do
    cond do
      complete_pool_metadata?(topology) -> Map.fetch!(topology, :pool_ids)
      legacy_pool_metadata?(topology) -> legacy_pool_ids(topology)
      true -> raise_incomplete_pool_metadata!()
    end
  end

  @spec set_ids_for_pool_from(t() | map(), pool_id()) :: [set_id()]
  def set_ids_for_pool_from(%{} = topology, pool_id) do
    cond do
      complete_pool_metadata?(topology) ->
        topology |> Map.fetch!(:pools) |> Map.fetch!(pool_id) |> Map.fetch!(:set_ids)

      legacy_pool_metadata?(topology) and pool_id == 0 ->
        Map.fetch!(topology, :set_ids)

      legacy_pool_metadata?(topology) ->
        raise KeyError,
          key: pool_id,
          term: %{0 => %{id: 0, set_ids: Map.fetch!(topology, :set_ids)}}

      true ->
        raise_incomplete_pool_metadata!()
    end
  end

  @spec pool_id_for_set_from(t() | map(), set_id()) :: pool_id()
  def pool_id_for_set_from(%{} = topology, set_id) do
    set = topology |> Map.fetch!(:sets) |> Map.fetch!(set_id)

    cond do
      complete_pool_metadata?(topology) -> Map.fetch!(set, :pool_id)
      legacy_pool_metadata?(topology) -> 0
      true -> raise_incomplete_pool_metadata!()
    end
  end

  @spec endpoints_from(t(), set_id()) :: [endpoint()]
  def endpoints_from(%{sets: sets}, set_id), do: Map.fetch!(sets, set_id).endpoints

  @spec ec_params_from(t()) :: keyword()
  def ec_params_from(%{data_shards: k, parity_shards: m, block_size: bs}),
    do: [data_shards: k, parity_shards: m, block_size: bs]

  @spec local_drives_from(t(), set_id(), node()) :: [String.t()]
  def local_drives_from(t, set_id, node) do
    for {^node, drive} <- endpoints_from(t, set_id), do: drive
  end

  defp get do
    case :persistent_term.get(@pt_key, :no_topology) do
      :no_topology ->
        raise ArgumentError,
              "Maxio.Cluster.Topology 未配置（config :maxio, Maxio.Cluster.Topology）。" <>
                "分布式后端需要拓扑；单机请用 FS / ErasureCoded 后端。"

      parsed ->
        parsed
    end
  end

  @doc """
  解析+校验拓扑 config。返回 parsed struct。非法 raise ArgumentError（铁律 3）。
  校验：每 set endpoints 数 == K+M；M >= 1；M <= N/2；K >= 1；set id 不重复；至少一个 set；
  每 set 的 N 端点落在 distinct 节点（failure domain）—— 同一节点上多端点会把真实容错降到 M 以下
  （quorum 谎言）。单机部署/测试经 `allow_colocated_endpoints: true` 显式放行 distinct-node 校验。
  """
  @spec parse_and_validate!(keyword()) :: t()
  def parse_and_validate!(cfg) do
    k = Keyword.fetch!(cfg, :data_shards)
    m = Keyword.fetch!(cfg, :parity_shards)
    bs = Keyword.get(cfg, :block_size, 1_048_576)
    allow_colocated = Keyword.get(cfg, :allow_colocated_endpoints, false)
    n = k + m

    cond do
      not (is_integer(k) and k > 0) ->
        raise ArgumentError, "topology: data_shards 须正整数（got #{inspect(k)}）"

      not (is_integer(m) and m >= 1) ->
        raise ArgumentError, "topology: parity_shards 须 >= 1（got #{inspect(m)}）"

      m > div(n, 2) ->
        raise ArgumentError, "topology: M=#{m} > N/2（N=#{n}）；parity 不得超过 set 的一半"

      true ->
        :ok
    end

    {sets, set_ids, pools, pool_ids} =
      cfg
      |> Keyword.fetch!(:pools)
      |> Enum.reduce({%{}, [], %{}, []}, fn pool,
                                            {sets_acc, set_ids_acc, pools_acc, pool_ids_acc} ->
        pool_id = pool.id

        if Map.has_key?(pools_acc, pool_id) do
          raise ArgumentError, "topology: 重复 pool id #{pool_id}"
        end

        {sets_acc, pool_set_ids, set_ids_acc} =
          Enum.reduce(pool.sets, {sets_acc, [], set_ids_acc}, fn s,
                                                                 {set_acc, pool_set_ids, ids_acc} ->
            if length(s.endpoints) != n do
              raise ArgumentError,
                    "topology: set #{s.id} 有 #{length(s.endpoints)} 个 endpoints != K+M=#{n}"
            end

            if Map.has_key?(set_acc, s.id) do
              raise ArgumentError, "topology: 重复 set id #{s.id}"
            end

            validate_distinct_nodes!(s, allow_colocated)

            set = %{id: s.id, pool_id: pool_id, endpoints: s.endpoints}

            {Map.put(set_acc, s.id, set), [s.id | pool_set_ids], [s.id | ids_acc]}
          end)

        pool_set_ids = Enum.reverse(pool_set_ids)
        pool = %{id: pool_id, set_ids: pool_set_ids}

        {sets_acc, set_ids_acc, Map.put(pools_acc, pool_id, pool), [pool_id | pool_ids_acc]}
      end)

    if set_ids == [] do
      raise ArgumentError, "topology: 至少需一个 erasure set"
    end

    %{
      data_shards: k,
      parity_shards: m,
      block_size: bs,
      pools: pools,
      pool_ids: Enum.reverse(pool_ids),
      sets: sets,
      set_ids: Enum.reverse(set_ids)
    }
  end

  # distinct-node failure-domain 校验：一个 set 的 N 端点须落在 distinct 节点，否则同一节点宕机会
  # 一次性带走 >1 个分片，把真实容错降到 M 以下（write/read quorum 成谎言）。allow_colocated 为真
  # 时跳过（单机部署/测试同机模拟多节点）。
  defp validate_distinct_nodes!(_s, true), do: :ok

  defp validate_distinct_nodes!(s, false) do
    ep_nodes = Enum.map(s.endpoints, fn {node, _drive} -> node end)

    if length(Enum.uniq(ep_nodes)) != length(ep_nodes) do
      raise ArgumentError,
            "topology: set #{s.id} 的端点未落在 distinct 节点（failure domain）；" <>
              "同一节点上多端点会把真实容错降到 M 以下（quorum 谎言）。" <>
              "单机部署/测试请显式设 allow_colocated_endpoints: true。"
    end

    :ok
  end

  defp complete_pool_metadata?(%{} = topology) do
    Map.has_key?(topology, :pool_ids) and Map.has_key?(topology, :pools) and
      topology
      |> Map.get(:sets, %{})
      |> Enum.all?(fn {_set_id, set} -> is_map(set) and Map.has_key?(set, :pool_id) end)
  end

  defp legacy_pool_metadata?(%{} = topology) do
    not Map.has_key?(topology, :pool_ids) and not Map.has_key?(topology, :pools) and
      topology
      |> Map.get(:sets, %{})
      |> Enum.all?(fn {_set_id, set} -> is_map(set) and not Map.has_key?(set, :pool_id) end)
  end

  defp legacy_pool_ids(%{set_ids: []}), do: []
  defp legacy_pool_ids(%{set_ids: _ids}), do: [0]

  defp raise_incomplete_pool_metadata! do
    raise ArgumentError,
          "topology: pool metadata incomplete; expected pool_ids+pools+set.pool_id " <>
            "or a legacy topology with none of those fields"
  end
end
