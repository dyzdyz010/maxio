defmodule Maxio.Cluster.Placement do
  @moduledoc """
  Object placement contract for distributed erasure sets.

  New writes persist the chosen set into object metadata. Reads, deletes and
  planning can then use the persisted set instead of re-hashing under a later
  topology. Rows written before this contract fall back to the current router.
  """

  alias Maxio.Cluster.{Router, Topology}
  alias Maxio.Cluster.Placement.PoolWritePolicy
  alias Maxio.Cluster.Rebalance.WriteRouting
  alias Maxio.Objects.Object

  @type source ::
          :persisted
          | :override
          | :router
          | :pool_free_space
          | :decommission_redirect
          | :no_topology
  @type resolution :: %{
          set_id: Topology.set_id() | nil,
          pool_id: non_neg_integer() | nil,
          topology_hash: String.t() | nil,
          source: source()
        }

  @doc "Resolve the set for a request, preferring an explicit placement override."
  @spec resolve(String.t(), String.t(), keyword()) :: {:ok, resolution()} | {:error, term()}
  def resolve(bucket, key, opts \\ []) do
    with {:ok, view} <- topology_view(opts) do
      case normalize_set_id(Keyword.get(opts, :placement_set_id)) do
        nil ->
          resolve_routed(bucket, key, view)

        set_id ->
          with {:ok, topology} <- validate_set_id(set_id, view) do
            {:ok,
             %{
               set_id: set_id,
               pool_id:
                 Keyword.get(opts, :placement_pool_id) ||
                   Topology.pool_id_for_set_from(topology, set_id),
               topology_hash: topology_hash(view),
               source: :override
             }}
          end
      end
    end
  end

  @doc """
  Resolve placement for a new write.

  This keeps explicit placement overrides authoritative for internal movement
  tools, but reroutes ordinary hash-based writes away from decommission targets.
  """
  @spec resolve_write(String.t(), String.t(), keyword()) :: {:ok, resolution()} | {:error, term()}
  def resolve_write(bucket, key, opts \\ []) do
    with {:ok, view} <- topology_view(opts) do
      case normalize_set_id(Keyword.get(opts, :placement_set_id)) do
        nil -> resolve_routed_write(bucket, key, view, opts)
        _set_id -> resolve(bucket, key, opts)
      end
    end
  end

  @doc "Resolve placement for an object row, preferring persisted placement."
  @spec resolve_object(String.t(), Object.t(), keyword()) ::
          {:ok, resolution()} | {:error, term()}
  def resolve_object(bucket, %Object{} = object, opts \\ []) do
    persisted_opts = storage_opts(object)

    opts =
      opts
      |> Keyword.merge(persisted_opts)

    case persisted_opts do
      [] ->
        with {:ok, placement} <- resolve(bucket, object.key, opts) do
          {:ok, %{placement | source: fallback_source(placement.source)}}
        end

      _persisted ->
        with {:ok, placement} <- resolve(bucket, object.key, opts) do
          {:ok, %{placement | source: :persisted}}
        end
    end
  end

  @doc "Opts to pass into Storage calls for an already resolved object row."
  @spec storage_opts(map() | nil) :: keyword()
  def storage_opts(%{placement_set_id: set_id} = object) when is_integer(set_id) do
    [
      placement_set_id: set_id,
      placement_pool_id: Map.get(object, :placement_pool_id),
      placement_topology_hash: Map.get(object, :placement_topology_hash)
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  def storage_opts(%{set_id: set_id} = placement) when is_integer(set_id) do
    [
      placement_set_id: set_id,
      placement_pool_id: Map.get(placement, :pool_id),
      placement_topology_hash: Map.get(placement, :topology_hash)
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  def storage_opts(_object), do: []

  @doc "Opts to pass into Storage calls for an upload's temporary part placement."
  @spec upload_storage_opts(map() | nil) :: keyword()
  def upload_storage_opts(%{placement_set_id: set_id} = upload) when is_integer(set_id) do
    [
      upload_placement_set_id: set_id,
      upload_placement_pool_id: Map.get(upload, :placement_pool_id),
      upload_placement_topology_hash: Map.get(upload, :placement_topology_hash)
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  def upload_storage_opts(_upload), do: []

  @doc "Persistable placement attrs returned from a storage write result."
  @spec attrs_from_result(map() | term()) :: map()
  def attrs_from_result(%{set_id: set_id} = result) do
    %{}
    |> maybe_put(:placement_set_id, set_id)
    |> maybe_put(:placement_pool_id, Map.get(result, :pool_id))
    |> maybe_put(:placement_topology_hash, Map.get(result, :topology_hash))
  end

  def attrs_from_result(%{} = result) do
    %{}
    |> maybe_put(:placement_set_id, Map.get(result, :placement_set_id))
    |> maybe_put(:placement_pool_id, Map.get(result, :placement_pool_id))
    |> maybe_put(:placement_topology_hash, Map.get(result, :placement_topology_hash))
  end

  def attrs_from_result(_result), do: %{}

  @doc "Persistable attrs when the caller only has bucket/key and backend opts."
  @spec attrs_for_write(String.t(), String.t(), keyword()) :: map()
  def attrs_for_write(bucket, key, opts \\ []) do
    case resolve_write(bucket, key, opts) do
      {:ok, %{set_id: nil}} -> %{}
      {:ok, placement} -> attrs_from_result(placement)
      {:error, _reason} -> %{}
    end
  end

  @doc "Stable fingerprint for a topology view, suitable for telemetry and stale-risk checks."
  @spec topology_hash(nil | Topology.t() | {:configured, nil} | {:injected, Topology.t()}) ::
          String.t() | nil
  def topology_hash({:configured, nil}), do: topology_hash(nil)
  def topology_hash({:injected, topology}), do: topology_hash(topology)
  def topology_hash(nil), do: nil

  def topology_hash(topology) when is_map(topology) do
    Topology.fingerprint(topology)
  end

  @doc "Return the topology hash implied by placement options."
  @spec topology_hash_for_opts(keyword()) :: String.t() | nil
  def topology_hash_for_opts(opts \\ []) do
    with {:ok, view} <- topology_view(opts) do
      topology_hash(view)
    end
  end

  defp resolve_routed(_bucket, _key, {:configured, nil}), do: {:ok, no_topology()}

  defp resolve_routed(bucket, key, {:injected, topology} = view) do
    set_id = Router.set_for(bucket, key, topology)

    {:ok,
     %{
       set_id: set_id,
       pool_id: Topology.pool_id_for_set_from(topology, set_id),
       topology_hash: topology_hash(view),
       source: :router
     }}
  end

  defp resolve_routed_write(_bucket, _key, {:configured, nil}, _opts),
    do: {:ok, no_topology()}

  defp resolve_routed_write(bucket, key, {:injected, topology} = view, opts) do
    with {:ok, routes} <- WriteRouting.active_routes(opts) do
      opts = write_routing_opts(opts, routes)

      with {:ok, placement} <- resolve_write_candidate(bucket, key, topology, view, opts),
           {:ok, set_id} <- WriteRouting.reroute_set(placement.set_id, opts),
           {:ok, validated_topology} <- validate_set_id(set_id, view) do
        source =
          if set_id == placement.set_id do
            placement.source
          else
            :decommission_redirect
          end

        {:ok,
         %{
           placement
           | set_id: set_id,
             pool_id: Topology.pool_id_for_set_from(validated_topology, set_id),
             source: source
         }}
      end
    end
  end

  defp write_routing_opts(opts, routes) do
    excluded_set_ids =
      routes
      |> Map.keys()
      |> Enum.concat(List.wrap(Keyword.get(opts, :pool_write_exclude_set_ids, [])))

    opts
    |> Keyword.put(:decommission_write_routes, routes)
    |> Keyword.put(:pool_write_exclude_set_ids, excluded_set_ids)
  end

  defp resolve_write_candidate(bucket, key, topology, view, opts) do
    case PoolWritePolicy.select(bucket, key, topology, opts) do
      :skip ->
        resolve_routed(bucket, key, view)

      {:ok, selection} ->
        {:ok,
         %{
           set_id: selection.set_id,
           pool_id: selection.pool_id,
           topology_hash: topology_hash(view),
           source: :pool_free_space
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp topology_view(opts) do
    cond do
      Keyword.has_key?(opts, :topology) and is_nil(Keyword.get(opts, :topology)) ->
        {:ok, {:configured, nil}}

      topology = Keyword.get(opts, :topology) ->
        {:ok, {:injected, topology}}

      Topology.configured?() ->
        {:ok, {:injected, current_topology!()}}

      true ->
        {:ok, {:configured, nil}}
    end
  end

  defp current_topology! do
    set_ids = Topology.all_set_ids()
    pool_ids = Topology.pool_ids()

    %{
      data_shards: Keyword.fetch!(Topology.ec_params(), :data_shards),
      parity_shards: Keyword.fetch!(Topology.ec_params(), :parity_shards),
      block_size: Keyword.fetch!(Topology.ec_params(), :block_size),
      pool_ids: pool_ids,
      pools:
        Map.new(pool_ids, fn pool_id ->
          {pool_id, %{id: pool_id, set_ids: Topology.set_ids_for_pool(pool_id)}}
        end),
      set_ids: set_ids,
      sets:
        Map.new(set_ids, fn set_id ->
          {set_id,
           %{
             id: set_id,
             pool_id: Topology.pool_id_for_set(set_id),
             endpoints: Topology.endpoints(set_id)
           }}
        end)
    }
  end

  # 校验通过时把 topology 一并交回调用方：pool_id 只有在 set_id 已被这道关卡确认后
  # 才有意义。原先另有一个 `pool_id_for_set/2` 对同样的 view 形态再分派一次，
  # 其中 `{:configured, nil} -> nil` 这支永远轮不到 —— 因为无拓扑时本函数早已返回
  # `{:error, {:unknown_set_id, ...}}`（比返回 nil pool_id 更严格）。合并成一层后
  # 无拓扑仍被结构化拒绝，重复分派消失。
  defp validate_set_id(set_id, {:configured, nil}), do: {:error, {:unknown_set_id, set_id, []}}

  defp validate_set_id(set_id, {:injected, topology}) do
    set_ids = Topology.all_set_ids_from(topology)

    if set_id in set_ids do
      {:ok, topology}
    else
      {:error, {:unknown_set_id, set_id, set_ids}}
    end
  end

  defp normalize_set_id(nil), do: nil
  defp normalize_set_id(set_id) when is_integer(set_id), do: set_id

  defp normalize_set_id(set_id) when is_binary(set_id) do
    case Integer.parse(set_id) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp normalize_set_id(_value), do: nil

  defp no_topology,
    do: %{set_id: nil, pool_id: nil, topology_hash: nil, source: :no_topology}

  defp fallback_source(:no_topology), do: :no_topology
  defp fallback_source(_source), do: :router

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
