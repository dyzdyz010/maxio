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
          allow_colocated_endpoints: boolean(),
          pools: %{pool_id() => %{id: pool_id(), set_ids: [set_id()]}},
          pool_ids: [pool_id()],
          sets: %{set_id() => %{id: set_id(), pool_id: pool_id(), endpoints: [endpoint()]}},
          set_ids: [set_id()]
        }

  @pt_key {__MODULE__, :topology}
  @runtime_mutation_lock_resource {:rebalance_topology_apply_removal, :runtime_topology}

  def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    :persistent_term.erase(@pt_key)

    case topology_source() do
      :config -> init_from_config()
      :db -> init_from_db()
      other -> {:stop, {:invalid_topology_source, other}}
    end
  end

  defp init_from_config do
    case Application.get_env(:maxio, __MODULE__) do
      nil ->
        {:ok, :no_topology}

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

  @doc "Return the parsed current runtime topology, or `{:error, :no_topology}`."
  @spec current() :: {:ok, t()} | {:error, :no_topology}
  def current do
    case :persistent_term.get(@pt_key, :no_topology) do
      :no_topology -> {:error, :no_topology}
      topology -> {:ok, topology}
    end
  end

  defp init_from_db do
    case Maxio.Cluster.TopologyStore.active_topology() do
      {:ok, topology} ->
        :persistent_term.put(@pt_key, topology)
        {:ok, topology}

      {:error, reason} ->
        {:stop, {:db_topology_unavailable, reason}}
    end
  end

  defp topology_source do
    case Application.get_env(:maxio, :topology_source, :config) do
      :config -> :config
      "config" -> :config
      :db -> :db
      "db" -> :db
      other -> other
    end
  end

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

  @doc "是否显式允许同一 set 内 endpoint 位于同一 node。"
  @spec allow_colocated_endpoints?() :: boolean()
  def allow_colocated_endpoints?, do: allow_colocated_endpoints_from(get())

  @doc "本节点在某 set 中负责的本地 drive 列表（端点 node == Node.self()）。"
  @spec local_drives_for_set(set_id()) :: [String.t()]
  def local_drives_for_set(set_id), do: local_drives_from(get(), set_id, Node.self())

  # ── 纯函数（test 注入 parsed；prod 经上面读 pt 调这些）──

  @spec all_set_ids_from(t()) :: [set_id()]
  def all_set_ids_from(%{set_ids: ids}), do: ids

  @doc "Return a read-only snapshot of the current runtime topology on this BEAM node."
  @spec runtime_snapshot() :: map()
  def runtime_snapshot do
    case :persistent_term.get(@pt_key, :no_topology) do
      :no_topology ->
        %{
          node: Node.self(),
          runtime_status: :no_topology,
          topology_hash: nil,
          set_ids: [],
          pool_ids: []
        }

      topology ->
        %{
          node: Node.self(),
          runtime_status: :configured,
          topology_hash: fingerprint(topology),
          set_ids: all_set_ids_from(topology),
          pool_ids: pool_ids_from(topology)
        }
    end
  end

  @doc "Return the current runtime topology hash, or `{:error, :no_topology}`."
  @spec runtime_hash() :: {:ok, String.t()} | {:error, :no_topology}
  def runtime_hash do
    case runtime_snapshot() do
      %{runtime_status: :configured, topology_hash: hash} -> {:ok, hash}
      %{runtime_status: :no_topology} -> {:error, :no_topology}
    end
  end

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

  @spec allow_colocated_endpoints_from(t() | map()) :: boolean()
  def allow_colocated_endpoints_from(%{} = topology) do
    Map.get(topology, :allow_colocated_endpoints, false) or colocated_endpoints?(topology)
  end

  @spec local_drives_from(t(), set_id(), node()) :: [String.t()]
  def local_drives_from(t, set_id, node) do
    for {^node, drive} <- endpoints_from(t, set_id), do: drive
  end

  @doc """
  Build the parsed topology that would result from removing one erasure set.

  This is a pure helper for operator planning. It does not mutate runtime
  topology, deployment config, job state, or storage data.
  """
  @spec remove_set_from(t(), set_id()) :: {:ok, t()} | {:error, term()}
  def remove_set_from(%{} = topology, set_id) when is_integer(set_id) do
    set_ids = all_set_ids_from(topology)

    cond do
      set_id not in set_ids ->
        {:error, {:unknown_set_id, set_id, set_ids}}

      length(set_ids) == 1 ->
        {:error, :would_remove_last_set}

      true ->
        candidate = do_remove_set(topology, set_id)
        validate_topology_shape!(candidate)
        {:ok, candidate}
    end
  end

  def remove_set_from(_topology, set_id), do: {:error, {:invalid_set_id, set_id}}

  @doc """
  Install a parsed topology into the current BEAM runtime.

  This is a runtime-only operation for explicit operator workflows. It does not
  rewrite deployment config and does not persist across process restart unless
  the deployment config is updated separately.
  """
  @spec install_runtime!(t()) :: t()
  def install_runtime!(%{} = topology) do
    validate_topology_shape!(topology)
    :persistent_term.put(@pt_key, topology)
    topology
  end

  @doc """
  Install a parsed topology into runtime only if the current runtime hash matches.

  If the node is already at the proposed hash this returns an idempotent
  `:already_applied` result. This helper is intentionally runtime-only and never
  writes deployment config.
  """
  @spec install_runtime_if_hash(t(), String.t()) :: {:ok, map()} | {:error, term()}
  def install_runtime_if_hash(%{} = topology, expected_current_hash)
      when is_binary(expected_current_hash) do
    validate_topology_shape!(topology)
    proposed_hash = fingerprint(topology)

    case runtime_hash() do
      {:ok, ^proposed_hash} ->
        {:ok, Map.put(runtime_snapshot(), :apply_status, :already_applied)}

      {:ok, ^expected_current_hash} ->
        install_runtime!(topology)
        {:ok, Map.put(runtime_snapshot(), :apply_status, :applied)}

      {:ok, actual_hash} ->
        {:error, {:runtime_topology_hash_mismatch, expected_current_hash, actual_hash}}

      {:error, :no_topology} ->
        {:error, :no_topology}
    end
  end

  @doc """
  Shared quorum-lock resource for runtime topology mutation fences.

  Rebalance/decommission job creation and explicit runtime topology apply must
  share this resource so no job can be planned against a topology while another
  operator workflow removes a set from the current runtime.
  """
  @spec runtime_mutation_lock_resource() :: term()
  def runtime_mutation_lock_resource, do: @runtime_mutation_lock_resource

  @doc """
  Convert a parsed topology to the operator-facing config keyword shape.
  """
  @spec to_config(t()) :: keyword()
  def to_config(%{} = topology) do
    base = [
      data_shards: Map.fetch!(topology, :data_shards),
      parity_shards: Map.fetch!(topology, :parity_shards),
      block_size: Map.fetch!(topology, :block_size)
    ]

    base =
      if allow_colocated_endpoints_from(topology) do
        base ++ [allow_colocated_endpoints: true]
      else
        base
      end

    base ++
      [
        pools:
          Enum.map(pool_ids_from(topology), fn pool_id ->
            %{
              id: pool_id,
              sets:
                Enum.map(set_ids_for_pool_from(topology, pool_id), fn set_id ->
                  %{id: set_id, endpoints: endpoints_from(topology, set_id)}
                end)
            }
          end)
      ]
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
  Stable full-topology fingerprint used for runtime/deployment convergence proofs.

  This intentionally includes the ordered endpoint `{node, drive}` material for
  every set. Placement set IDs alone are not enough to prove that two runtimes
  would address the same shards.
  """
  @spec fingerprint(t() | map()) :: String.t()
  def fingerprint(topology) when is_map(topology) do
    material = [
      {:data_shards, Map.get(topology, :data_shards)},
      {:parity_shards, Map.get(topology, :parity_shards)},
      {:block_size, Map.get(topology, :block_size)},
      {:allow_colocated_endpoints, allow_colocated_endpoints_from(topology)},
      {:pool_ids, pool_ids_from(topology)},
      {:set_ids, all_set_ids_from(topology)},
      {:pools,
       Enum.map(pool_ids_from(topology), fn pool_id ->
         {pool_id,
          Enum.map(set_ids_for_pool_from(topology, pool_id), fn set_id ->
            {set_id, Enum.map(endpoints_from(topology, set_id), &fingerprint_endpoint/1)}
          end)}
       end)}
    ]

    :crypto.hash(:sha256, :erlang.term_to_binary(material))
    |> Base.encode16(case: :lower)
  end

  defp fingerprint_endpoint({node, drive}) when is_atom(node) and is_binary(drive),
    do: {Atom.to_string(node), drive}

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
      allow_colocated_endpoints: allow_colocated,
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

  defp colocated_endpoints?(%{} = topology) do
    Enum.any?(all_set_ids_from(topology), fn set_id ->
      nodes = Enum.map(endpoints_from(topology, set_id), fn {node, _drive} -> node end)
      length(nodes) != length(Enum.uniq(nodes))
    end)
  end

  defp raise_incomplete_pool_metadata! do
    raise ArgumentError,
          "topology: pool metadata incomplete; expected pool_ids+pools+set.pool_id " <>
            "or a legacy topology with none of those fields"
  end

  defp do_remove_set(topology, set_id) do
    pool_id = pool_id_for_set_from(topology, set_id)
    set_ids = Enum.reject(all_set_ids_from(topology), &(&1 == set_id))
    sets = topology |> Map.fetch!(:sets) |> Map.delete(set_id)
    pools = Map.fetch!(topology, :pools)
    pool_ids = pool_ids_from(topology)
    pool = Map.fetch!(pools, pool_id)
    pool_set_ids = Enum.reject(Map.fetch!(pool, :set_ids), &(&1 == set_id))

    {pool_ids, pools} =
      if pool_set_ids == [] do
        {Enum.reject(pool_ids, &(&1 == pool_id)), Map.delete(pools, pool_id)}
      else
        pool = %{pool | set_ids: pool_set_ids}
        {pool_ids, Map.put(pools, pool_id, pool)}
      end

    %{
      topology
      | pool_ids: pool_ids,
        pools: pools,
        set_ids: set_ids,
        sets: sets
    }
  end

  defp validate_topology_shape!(%{} = topology) do
    k = Map.fetch!(topology, :data_shards)
    m = Map.fetch!(topology, :parity_shards)
    n = k + m
    set_ids = all_set_ids_from(topology)
    pool_ids = pool_ids_from(topology)

    cond do
      set_ids == [] ->
        raise ArgumentError, "topology: runtime topology must contain at least one erasure set"

      pool_ids == [] ->
        raise ArgumentError, "topology: runtime topology must contain at least one pool"

      true ->
        :ok
    end

    set_id_set = MapSet.new(set_ids)

    Enum.each(pool_ids, fn pool_id ->
      pool_set_ids = set_ids_for_pool_from(topology, pool_id)

      if pool_set_ids == [] do
        raise ArgumentError, "topology: pool #{pool_id} has no erasure sets"
      end

      Enum.each(pool_set_ids, fn set_id ->
        unless MapSet.member?(set_id_set, set_id) do
          raise ArgumentError, "topology: pool #{pool_id} references unknown set #{set_id}"
        end
      end)
    end)

    Enum.each(set_ids, fn set_id ->
      endpoints = endpoints_from(topology, set_id)

      if length(endpoints) != n do
        raise ArgumentError, "topology: set #{set_id} endpoints != K+M=#{n}"
      end

      pool_id = pool_id_for_set_from(topology, set_id)

      unless pool_id in pool_ids and set_id in set_ids_for_pool_from(topology, pool_id) do
        raise ArgumentError, "topology: set #{set_id} has inconsistent pool metadata"
      end
    end)

    :ok
  end
end
