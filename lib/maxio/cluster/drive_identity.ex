defmodule Maxio.Cluster.DriveIdentity do
  @moduledoc """
  Persistent software identity for configured cluster drive endpoints.

  Each drive root gets a small marker file. The local node stores the expected
  marker UUID for each `{node, drive}` endpoint in Postgres. When a later probe
  sees a different UUID at the same endpoint path, the endpoint is treated as a
  replacement and marked for the existing fresh-drive heal workflow.

  This is a software identity signal, not a hardware serial or rebalance system.
  """

  import Ecto.Query

  alias Maxio.Cluster.{DriveIdentity.Record, Transport}
  alias Maxio.Repo

  @marker_file ".maxio-drive-identity.json"
  @marker_version 1

  @type endpoint :: {node(), String.t()}
  @type persisted_endpoint :: {node() | String.t(), String.t()}
  @type marker :: %{
          drive_uuid: String.t(),
          version: pos_integer(),
          created_at: String.t() | nil,
          marker_path: String.t()
        }
  @type status :: %{
          endpoint: persisted_endpoint(),
          drive_uuid: String.t(),
          previous_drive_uuid: String.t() | nil,
          generation: pos_integer(),
          identity_heal_required?: boolean(),
          replacement_detected?: boolean(),
          set_id: integer() | nil,
          endpoint_index: integer() | nil
        }

  @doc "Return the configured marker file name."
  @spec marker_file_name(keyword()) :: String.t()
  def marker_file_name(opts \\ []) do
    opts
    |> Keyword.get(:marker_file, config(:marker_file, @marker_file))
    |> case do
      name when is_binary(name) and name != "" -> name
      _ -> @marker_file
    end
  end

  @doc "Return the marker path for a local drive root."
  @spec marker_path(String.t(), keyword()) :: String.t()
  def marker_path(drive_root, opts \\ []),
    do: Path.join(Path.expand(drive_root), marker_file_name(opts))

  @doc """
  Probe a local drive root marker, creating one when missing and configured.

  This is called on the node that owns `drive_root` through `ShardServer`.
  """
  @spec probe_drive_root(String.t(), keyword()) :: {:ok, marker()} | {:error, term()}
  def probe_drive_root(drive_root, opts \\ []) do
    drive_root = Path.expand(drive_root)

    with :ok <- ensure_directory(drive_root),
         {:ok, marker} <- read_or_create_marker(drive_root, opts) do
      {:ok, marker}
    end
  end

  @doc "Probe one configured endpoint through the cluster transport and persist the observed identity."
  @spec probe_endpoint(endpoint(), keyword()) :: {:ok, status()} | {:error, term()}
  def probe_endpoint(endpoint, opts \\ []) do
    {node, drive} = normalize_endpoint(endpoint)
    transport = Keyword.get(opts, :transport) || Transport.impl(opts)

    with {:ok, marker} <- probe_remote_identity(transport, node, drive, opts),
         {:ok, status} <- register_observation({node, drive}, marker, opts) do
      {:ok, status}
    end
  end

  @doc "Return persisted identity status for one endpoint."
  @spec status(endpoint()) :: {:ok, status()} | {:error, :not_found}
  def status(endpoint) do
    {node, drive} = normalize_endpoint(endpoint)

    case get_record(node, drive) do
      nil -> {:error, :not_found}
      %Record{} = record -> {:ok, to_status(record, {node, drive}, false)}
    end
  end

  @doc "Return all persisted identity statuses, sorted for stable CLI/test output."
  @spec snapshot(keyword()) :: [status()]
  def snapshot(opts \\ []) do
    Record
    |> maybe_filter_heal_required(opts)
    |> order_by([r], asc: r.node_name, asc: r.drive_path)
    |> Repo.all()
    |> Enum.map(fn record ->
      to_status(record, {node_from_record(record.node_name), record.drive_path}, false)
    end)
  end

  @doc "Clear the persistent identity heal marker for an endpoint."
  @spec clear_heal_required(endpoint(), keyword()) ::
          {:ok, status()} | {:error, :not_found | term()}
  def clear_heal_required(endpoint, opts \\ []) do
    {node, drive} = normalize_endpoint(endpoint)

    case get_record(node, drive) do
      nil ->
        {:error, :not_found}

      %Record{} = record ->
        attrs = %{
          identity_heal_required: false,
          healed_at: now(opts)
        }

        update_record(record, attrs, {node, drive}, false)
    end
  end

  @doc false
  @spec register_observation(endpoint(), map(), keyword()) :: {:ok, status()} | {:error, term()}
  def register_observation(endpoint, marker, opts \\ []) do
    {node, drive} = normalize_endpoint(endpoint)

    with {:ok, drive_uuid} <- marker_uuid(marker) do
      case get_record(node, drive) do
        nil -> insert_first_seen({node, drive}, drive_uuid, opts)
        %Record{} = record -> update_seen(record, {node, drive}, drive_uuid, opts)
      end
    end
  end

  defp insert_first_seen({node, drive} = endpoint, drive_uuid, opts) do
    seen_at = now(opts)

    attrs = %{
      node_name: Atom.to_string(node),
      drive_path: drive,
      set_id: Keyword.get(opts, :set_id),
      endpoint_index: Keyword.get(opts, :endpoint_index),
      drive_uuid: drive_uuid,
      generation: 1,
      identity_heal_required: false,
      first_seen_at: seen_at,
      last_seen_at: seen_at
    }

    %Record{}
    |> Record.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, record} -> {:ok, to_status(record, endpoint, false)}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp update_seen(%Record{drive_uuid: drive_uuid} = record, endpoint, drive_uuid, opts) do
    attrs = %{
      set_id: Keyword.get(opts, :set_id, record.set_id),
      endpoint_index: Keyword.get(opts, :endpoint_index, record.endpoint_index),
      last_seen_at: now(opts)
    }

    update_record(record, attrs, endpoint, false)
  end

  defp update_seen(%Record{} = record, endpoint, new_drive_uuid, opts) do
    attrs = %{
      set_id: Keyword.get(opts, :set_id, record.set_id),
      endpoint_index: Keyword.get(opts, :endpoint_index, record.endpoint_index),
      drive_uuid: new_drive_uuid,
      previous_drive_uuid: record.drive_uuid,
      generation: record.generation + 1,
      identity_heal_required: true,
      last_seen_at: now(opts),
      replacement_detected_at: now(opts),
      healed_at: nil
    }

    update_record(record, attrs, endpoint, true)
  end

  defp update_record(%Record{} = record, attrs, endpoint, replacement_detected?) do
    record
    |> Record.changeset(attrs)
    |> Repo.update()
    |> case do
      {:ok, record} -> {:ok, to_status(record, endpoint, replacement_detected?)}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp get_record(node, drive) do
    Repo.get_by(Record, node_name: Atom.to_string(node), drive_path: Path.expand(drive))
  end

  defp probe_remote_identity(transport, node, drive, opts) do
    try do
      transport.probe_drive_identity(node, drive, marker_probe_opts(opts))
    rescue
      e -> {:error, {:exception, Exception.message(e)}}
    catch
      kind, reason -> {:error, {kind, reason}}
    end
  end

  defp marker_probe_opts(opts) do
    Keyword.take(opts, [:create_missing, :marker_file])
  end

  defp read_or_create_marker(drive_root, opts) do
    case read_marker(drive_root, opts) do
      {:error, :enoent} ->
        if create_missing?(opts),
          do: create_marker(drive_root, opts),
          else: {:error, :missing_identity}

      other ->
        other
    end
  end

  defp read_marker(drive_root, opts) do
    path = marker_path(drive_root, opts)

    case File.read(path) do
      {:ok, json} -> decode_marker(json, path)
      {:error, reason} -> {:error, reason}
    end
  end

  defp create_marker(drive_root, opts) do
    path = marker_path(drive_root, opts)

    marker = %{
      "version" => @marker_version,
      "drive_uuid" => new_uuid(),
      "created_at" => utc_now() |> DateTime.to_iso8601(),
      "node_name" => Atom.to_string(Node.self()),
      "drive_path" => Path.expand(drive_root)
    }

    json = Jason.encode!(marker)

    case File.open(path, [:write, :exclusive, :binary], fn io -> IO.binwrite(io, json) end) do
      {:ok, :ok} -> decode_marker(json, path)
      {:error, :eexist} -> read_marker(drive_root, opts)
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_marker(json, path) do
    with {:ok, %{} = marker} <- Jason.decode(json),
         {:ok, drive_uuid} <- marker_uuid(marker),
         {:ok, version} <- marker_version(marker) do
      {:ok,
       %{
         drive_uuid: drive_uuid,
         version: version,
         created_at: Map.get(marker, "created_at"),
         marker_path: path
       }}
    else
      {:error, reason} -> {:error, {:invalid_identity_marker, reason}}
      _ -> {:error, {:invalid_identity_marker, :malformed}}
    end
  end

  defp marker_uuid(%{drive_uuid: uuid}), do: validate_uuid(uuid)
  defp marker_uuid(%{"drive_uuid" => uuid}), do: validate_uuid(uuid)
  defp marker_uuid(_marker), do: {:error, :missing_drive_uuid}

  defp marker_version(%{"version" => @marker_version}), do: {:ok, @marker_version}
  defp marker_version(%{version: @marker_version}), do: {:ok, @marker_version}
  defp marker_version(_marker), do: {:error, :unsupported_version}

  defp validate_uuid(uuid) when is_binary(uuid) do
    if Regex.match?(~r/\A[0-9a-f]{32}\z/, uuid), do: {:ok, uuid}, else: {:error, :bad_drive_uuid}
  end

  defp validate_uuid(_uuid), do: {:error, :bad_drive_uuid}

  defp ensure_directory(drive_root) do
    case File.stat(drive_root) do
      {:ok, %File.Stat{type: :directory}} -> :ok
      {:ok, _stat} -> {:error, :enotdir}
      {:error, :enoent} -> {:error, :unavailable}
      {:error, reason} -> {:error, reason}
    end
  end

  defp to_status(%Record{} = record, endpoint, replacement_detected?) do
    %{
      endpoint: endpoint,
      drive_uuid: record.drive_uuid,
      previous_drive_uuid: record.previous_drive_uuid,
      generation: record.generation,
      identity_heal_required?: record.identity_heal_required,
      replacement_detected?: replacement_detected?,
      set_id: record.set_id,
      endpoint_index: record.endpoint_index
    }
  end

  defp maybe_filter_heal_required(query, opts) do
    if Keyword.get(opts, :heal_required, false) do
      where(query, [r], r.identity_heal_required == true)
    else
      query
    end
  end

  defp normalize_endpoint({node, drive}) when is_atom(node) and is_binary(drive),
    do: {node, Path.expand(drive)}

  defp create_missing?(opts),
    do: Keyword.get(opts, :create_missing, config(:create_missing, true))

  defp config(key, default),
    do: :maxio |> Application.get_env(:drive_identity, []) |> Keyword.get(key, default)

  defp now(opts) do
    cond do
      match?(%DateTime{}, Keyword.get(opts, :now)) ->
        Keyword.fetch!(opts, :now)

      is_function(Keyword.get(opts, :now_fun), 0) ->
        opts |> Keyword.fetch!(:now_fun) |> apply([])

      true ->
        utc_now()
    end
  end

  defp node_from_record(node_name) do
    String.to_existing_atom(node_name)
  rescue
    ArgumentError -> node_name
  end

  defp utc_now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  defp new_uuid, do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
end
