defmodule Maxio.Cluster.TopologyStore do
  @moduledoc """
  DB-backed deployment topology revision store.

  Runtime topology changes remain explicit operator workflows. This store only
  persists the deployment topology revision that future boots and verification
  steps may trust after all rebalance/decommission gates have passed.
  """

  import Ecto.Query

  alias Maxio.Cluster.{Topology, TopologyRevision}
  alias Maxio.Repo

  @active "active"
  @superseded "superseded"

  @type active_revision_topology :: %{
          revision: TopologyRevision.t(),
          topology: Topology.t()
        }

  @doc "Fetch the active topology revision row."
  @spec active_revision(keyword()) ::
          {:ok, TopologyRevision.t()} | {:error, :no_active_topology_revision}
  def active_revision(opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    case repo.one(active_query()) do
      nil -> {:error, :no_active_topology_revision}
      %TopologyRevision{} = revision -> {:ok, revision}
    end
  end

  @doc "Fetch and validate the active deployment topology."
  @spec active_topology(keyword()) ::
          {:ok, Topology.t()} | {:error, term()}
  def active_topology(opts \\ []) do
    with {:ok, %{topology: topology}} <- active_revision_topology(opts) do
      {:ok, topology}
    end
  end

  @doc "Fetch the active revision and its validated parsed topology."
  @spec active_revision_topology(keyword()) ::
          {:ok, active_revision_topology()} | {:error, term()}
  def active_revision_topology(opts \\ []) do
    with {:ok, revision} <- active_revision(opts),
         {:ok, topology} <- decode_revision(revision) do
      {:ok, %{revision: revision, topology: topology}}
    end
  end

  @doc """
  Activate a parsed topology or config keyword as the current deployment revision.

  A new active revision supersedes the previous active row in one transaction.
  If the active row already has the same topology hash this is idempotent and
  returns the existing revision.
  """
  @spec activate_topology(Topology.t() | keyword(), keyword()) ::
          {:ok, TopologyRevision.t()} | {:error, term()}
  def activate_topology(topology_or_config, opts \\ []) do
    with {:ok, topology} <- normalize_topology(topology_or_config),
         :ok <- ensure_expected_hash(topology, Keyword.get(opts, :expected_topology_hash)) do
      do_activate_topology(topology, opts)
    end
  end

  @doc "Encode a topology into the JSON-safe DB config shape."
  @spec encode_config(Topology.t() | keyword()) :: {:ok, map()} | {:error, term()}
  def encode_config(topology_or_config) do
    with {:ok, topology} <- normalize_topology(topology_or_config) do
      {:ok, encode_topology(topology)}
    end
  end

  @doc "Decode a JSON-safe DB config shape into a validated parsed topology."
  @spec decode_config(map() | keyword()) :: {:ok, Topology.t()} | {:error, term()}
  def decode_config(config) when is_list(config), do: normalize_topology(config)

  def decode_config(%{} = config) do
    try do
      topology_config = [
        data_shards: fetch_required(config, :data_shards),
        parity_shards: fetch_required(config, :parity_shards),
        block_size: fetch_required(config, :block_size)
      ]

      topology_config =
        if fetch_optional(config, :allow_colocated_endpoints, false) do
          topology_config ++ [allow_colocated_endpoints: true]
        else
          topology_config
        end

      topology_config =
        topology_config ++
          [
            pools:
              config
              |> fetch_required(:pools)
              |> Enum.map(&decode_pool/1)
          ]

      {:ok, Topology.parse_and_validate!(topology_config)}
    rescue
      error ->
        {:error, {:invalid_topology_revision_config, Exception.message(error)}}
    end
  end

  def decode_config(value),
    do: {:error, {:invalid_topology_revision_config, inspect(value)}}

  defp do_activate_topology(topology, opts) do
    repo = Keyword.get(opts, :repo, Repo)
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    hash = Topology.fingerprint(topology)
    source = Keyword.get(opts, :source, "operator")
    source_job_id = Keyword.get(opts, :source_job_id)
    config = encode_topology(topology)

    repo.transaction(fn ->
      case repo.one(from(r in active_query(), lock: "FOR UPDATE")) do
        %TopologyRevision{topology_hash: ^hash} = active ->
          case decode_revision(active) do
            {:ok, _topology} -> active
            {:error, reason} -> repo.rollback(reason)
          end

        _active_or_nil ->
          repo.update_all(active_query(), set: [status: @superseded, updated_at: now])

          attrs = %{
            status: @active,
            topology_hash: hash,
            config: config,
            source: source,
            source_job_id: source_job_id,
            activated_at: now
          }

          case repo.insert(TopologyRevision.changeset(%TopologyRevision{}, attrs)) do
            {:ok, revision} -> revision
            {:error, changeset} -> repo.rollback(changeset)
          end
      end
    end)
  end

  defp decode_revision(%TopologyRevision{} = revision) do
    with {:ok, topology} <- decode_config(revision.config),
         :ok <- ensure_revision_hash(revision, topology) do
      {:ok, topology}
    end
  end

  defp ensure_revision_hash(%TopologyRevision{topology_hash: stored}, topology) do
    actual = Topology.fingerprint(topology)

    if actual == stored do
      :ok
    else
      {:error, {:topology_revision_hash_mismatch, stored, actual}}
    end
  end

  defp ensure_expected_hash(_topology, nil), do: :ok

  defp ensure_expected_hash(topology, expected) when is_binary(expected) do
    actual = Topology.fingerprint(topology)

    if actual == expected do
      :ok
    else
      {:error, {:topology_revision_expected_hash_mismatch, expected, actual}}
    end
  end

  defp ensure_expected_hash(_topology, expected),
    do: {:error, {:invalid_topology_revision_expected_hash, expected}}

  defp normalize_topology(%{set_ids: _set_ids, sets: _sets} = topology), do: {:ok, topology}

  defp normalize_topology(config) when is_list(config) do
    {:ok, Topology.parse_and_validate!(config)}
  rescue
    error -> {:error, {:invalid_topology_revision_config, Exception.message(error)}}
  end

  defp normalize_topology(value),
    do: {:error, {:invalid_topology_revision_config, inspect(value)}}

  defp encode_topology(topology) do
    %{
      "data_shards" => Map.fetch!(topology, :data_shards),
      "parity_shards" => Map.fetch!(topology, :parity_shards),
      "block_size" => Map.fetch!(topology, :block_size),
      "allow_colocated_endpoints" => Topology.allow_colocated_endpoints_from(topology),
      "pools" =>
        Enum.map(Topology.pool_ids_from(topology), fn pool_id ->
          %{
            "id" => pool_id,
            "sets" =>
              topology
              |> Topology.set_ids_for_pool_from(pool_id)
              |> Enum.map(fn set_id ->
                %{
                  "id" => set_id,
                  "endpoints" =>
                    topology
                    |> Topology.endpoints_from(set_id)
                    |> Enum.map(fn {node, drive} ->
                      %{"node" => Atom.to_string(node), "drive" => drive}
                    end)
                }
              end)
          }
        end)
    }
  end

  defp decode_pool(pool) do
    %{
      id: fetch_required(pool, :id),
      sets:
        pool
        |> fetch_required(:sets)
        |> Enum.map(&decode_set/1)
    }
  end

  defp decode_set(set) do
    %{
      id: fetch_required(set, :id),
      endpoints:
        set
        |> fetch_required(:endpoints)
        |> Enum.map(&decode_endpoint/1)
    }
  end

  defp decode_endpoint(endpoint) do
    node =
      endpoint
      |> fetch_required(:node)
      |> existing_node_atom()

    drive = fetch_required(endpoint, :drive)

    unless is_binary(drive) do
      raise ArgumentError, "topology revision endpoint drive must be a string"
    end

    {node, drive}
  end

  defp existing_node_atom(node) when is_atom(node), do: node
  defp existing_node_atom(node) when is_binary(node), do: String.to_existing_atom(node)

  defp existing_node_atom(node) do
    raise ArgumentError,
          "topology revision endpoint node must be a string or atom, got #{inspect(node)}"
  end

  defp fetch_required(map, key) when is_map(map) do
    string_key = Atom.to_string(key)

    cond do
      Map.has_key?(map, key) -> Map.fetch!(map, key)
      Map.has_key?(map, string_key) -> Map.fetch!(map, string_key)
      true -> raise KeyError, key: key, term: map
    end
  end

  defp fetch_required(value, key),
    do: raise(KeyError, key: key, term: value)

  defp fetch_optional(map, key, default) when is_map(map) do
    string_key = Atom.to_string(key)

    cond do
      Map.has_key?(map, key) -> Map.fetch!(map, key)
      Map.has_key?(map, string_key) -> Map.fetch!(map, string_key)
      true -> default
    end
  end

  defp active_query do
    from(r in TopologyRevision, where: r.status == @active)
  end
end
