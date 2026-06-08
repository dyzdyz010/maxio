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
  @type endpoint :: {node(), String.t()}
  @type t :: %{
          data_shards: pos_integer(),
          parity_shards: pos_integer(),
          block_size: pos_integer(),
          sets: %{set_id() => %{id: set_id(), endpoints: [endpoint()]}},
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

  @doc "所有 set_id（按 pool 顺序 + set 顺序展平）的全局有序列表。路由 mod 用其长度。"
  @spec all_set_ids() :: [set_id()]
  def all_set_ids, do: get().set_ids

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
  校验：每 set endpoints 数 == K+M；M >= 1；M <= N/2；K >= 1；set id 不重复；至少一个 set。
  """
  @spec parse_and_validate!(keyword()) :: t()
  def parse_and_validate!(cfg) do
    k = Keyword.fetch!(cfg, :data_shards)
    m = Keyword.fetch!(cfg, :parity_shards)
    bs = Keyword.get(cfg, :block_size, 1_048_576)
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

    {sets, ids} =
      cfg
      |> Keyword.fetch!(:pools)
      |> Enum.flat_map(& &1.sets)
      |> Enum.reduce({%{}, []}, fn s, {acc, ids} ->
        if length(s.endpoints) != n do
          raise ArgumentError,
                "topology: set #{s.id} 有 #{length(s.endpoints)} 个 endpoints != K+M=#{n}"
        end

        if Map.has_key?(acc, s.id) do
          raise ArgumentError, "topology: 重复 set id #{s.id}"
        end

        {Map.put(acc, s.id, %{id: s.id, endpoints: s.endpoints}), [s.id | ids]}
      end)

    if ids == [] do
      raise ArgumentError, "topology: 至少需一个 erasure set"
    end

    %{
      data_shards: k,
      parity_shards: m,
      block_size: bs,
      sets: sets,
      set_ids: Enum.sort(ids)
    }
  end
end
