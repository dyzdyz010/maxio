defmodule Maxio.Cluster.DriveHealth do
  @moduledoc """
  Node-local drive health registry for distributed erasure endpoints.

  The registry is observational: it records structured reachability probes and exposes
  suspect/offline/heal-required state for operators and background jobs. It does not
  change S3 request routing, quorum calculations, or read/write acceptance.
  """
  use GenServer

  alias Maxio.Cluster.{Topology, Transport}
  alias Maxio.S3.Log
  alias Maxio.Storage.Erasure.Config

  @default_offline_after_ms 172_800_000
  @statuses [:online, :suspect, :offline]

  @type endpoint :: {node(), String.t()}
  @type status :: :online | :suspect | :offline
  @type drive_status :: %{
          endpoint: endpoint(),
          status: status(),
          failure_count: non_neg_integer(),
          first_failure_ms: integer() | nil,
          last_failure_ms: integer() | nil,
          last_online_ms: integer() | nil,
          last_reason: term() | nil,
          set_id: term() | nil,
          set_write_available_seen?: boolean(),
          set_unavailable_seen?: boolean(),
          heal_required?: boolean(),
          last_offline_duration_ms: integer() | nil,
          last_transition: atom() | nil
        }
  @type probe_summary :: %{
          sets: non_neg_integer(),
          endpoints: non_neg_integer(),
          online: non_neg_integer(),
          suspect: non_neg_integer(),
          offline: non_neg_integer(),
          heal_required: non_neg_integer()
        }

  @doc false
  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @impl true
  def init(_opts), do: {:ok, %{endpoints: %{}}}

  @doc "Record one structured drive reachability probe."
  @spec record_probe(endpoint(), term(), keyword()) :: drive_status()
  def record_probe(endpoint, result, opts \\ []) do
    GenServer.call(__MODULE__, {:record_probe, normalize_endpoint(endpoint), result, opts})
  end

  @doc "Return current status for one endpoint; unknown endpoints are treated as online."
  @spec status(endpoint()) :: drive_status()
  def status(endpoint), do: GenServer.call(__MODULE__, {:status, normalize_endpoint(endpoint)})

  @doc "Return all known endpoint statuses sorted for stable CLI/test output."
  @spec snapshot() :: [drive_status()]
  def snapshot, do: GenServer.call(__MODULE__, :snapshot)

  @doc "Clear all runtime state. Intended for tests and explicit operator tooling."
  @spec reset() :: :ok
  def reset, do: GenServer.call(__MODULE__, :reset)

  @doc "Clear the fresh-drive-heal marker for an endpoint after a heal workflow completes."
  @spec clear_heal_required(endpoint()) :: drive_status()
  def clear_heal_required(endpoint),
    do: GenServer.call(__MODULE__, {:clear_heal_required, normalize_endpoint(endpoint)})

  @spec offline?(endpoint()) :: boolean()
  def offline?(endpoint), do: status(endpoint).status == :offline

  @spec heal_required?(endpoint()) :: boolean()
  def heal_required?(endpoint), do: Map.fetch!(status(endpoint), :heal_required?)

  @doc """
  Probe every endpoint in a topology through `Transport.probe_drive/2`.

  A probe failure marks the drive suspect/offline only after the configured long window.
  The set write-availability observation is stored with the failure so recovery can
  expose a fresh-drive-heal requirement only when the set stayed writable.
  """
  @spec probe_topology(keyword()) :: probe_summary()
  def probe_topology(opts \\ []) do
    case topology_view(opts) do
      :no_topology ->
        zero_probe_summary()

      view ->
        transport = Keyword.get(opts, :transport) || Transport.impl(opts)
        offline_after_ms = offline_after_ms(opts)
        now_ms = now_ms(opts)
        set_ids = all_set_ids(view)
        write_quorum = write_quorum(view)

        statuses =
          Enum.flat_map(set_ids, fn set_id ->
            endpoints = endpoints(view, set_id)
            results = Enum.map(endpoints, &probe_drive(transport, &1))
            online_count = Enum.count(results, fn {_endpoint, result} -> ok_result?(result) end)
            set_write_available? = online_count >= write_quorum

            Enum.map(results, fn {endpoint, result} ->
              record_probe(
                endpoint,
                result,
                offline_after_ms: offline_after_ms,
                now_ms: now_ms,
                set_id: set_id,
                set_write_available?: set_write_available?
              )
            end)
          end)

        summarize_statuses(statuses, length(set_ids))
    end
  end

  @doc "Default long-window threshold used for drive-offline decisions."
  @spec default_offline_after_ms() :: non_neg_integer()
  def default_offline_after_ms do
    :maxio
    |> Application.get_env(:drive_health, [])
    |> Keyword.get(:offline_after_ms, @default_offline_after_ms)
    |> non_negative_int(@default_offline_after_ms)
  end

  @impl true
  def handle_call({:record_probe, endpoint, result, opts}, _from, state) do
    current = Map.get(state.endpoints, endpoint, default_status(endpoint))
    next = apply_probe(current, result, opts)
    maybe_log_transition(current, next)
    {:reply, next, put_in(state.endpoints[endpoint], next)}
  end

  def handle_call({:status, endpoint}, _from, state) do
    {:reply, Map.get(state.endpoints, endpoint, default_status(endpoint)), state}
  end

  def handle_call(:snapshot, _from, state) do
    statuses =
      state.endpoints
      |> Map.values()
      |> Enum.sort_by(fn %{endpoint: {node, drive}} -> {inspect(node), drive} end)

    {:reply, statuses, state}
  end

  def handle_call(:reset, _from, _state), do: {:reply, :ok, %{endpoints: %{}}}

  def handle_call({:clear_heal_required, endpoint}, _from, state) do
    next =
      state.endpoints
      |> Map.get(endpoint, default_status(endpoint))
      |> Map.put(:heal_required?, false)

    {:reply, next, put_in(state.endpoints[endpoint], next)}
  end

  defp apply_probe(current, result, opts) do
    case normalize_result(result) do
      {:ok, _value} -> apply_success(current, opts)
      {:error, reason} -> apply_failure(current, reason, opts)
    end
  end

  defp apply_failure(current, reason, opts) do
    now = now_ms(opts)
    first_failure_ms = current.first_failure_ms || now
    offline_after_ms = offline_after_ms(opts)
    duration = max(now - first_failure_ms, 0)
    status = if duration >= offline_after_ms, do: :offline, else: :suspect

    current
    |> note_set(opts)
    |> Map.merge(%{
      status: status,
      failure_count: current.failure_count + 1,
      first_failure_ms: first_failure_ms,
      last_failure_ms: now,
      last_reason: reason,
      set_id: Keyword.get(opts, :set_id, current.set_id),
      last_transition: transition(current.status, status)
    })
  end

  defp apply_success(current, opts) do
    now = now_ms(opts)
    duration = failure_duration(current, now)
    long_outage? = duration != nil and duration >= offline_after_ms(opts)

    needs_heal? =
      Map.fetch!(current, :heal_required?) or
        (long_outage? and Map.fetch!(current, :set_write_available_seen?) and
           not Map.fetch!(current, :set_unavailable_seen?))

    current
    |> Map.merge(%{
      status: :online,
      failure_count: 0,
      first_failure_ms: nil,
      last_failure_ms: nil,
      last_online_ms: now,
      last_reason: nil,
      set_id: Keyword.get(opts, :set_id, current.set_id),
      set_write_available_seen?: false,
      set_unavailable_seen?: false,
      heal_required?: needs_heal?,
      last_offline_duration_ms: duration || current.last_offline_duration_ms,
      last_transition: transition(current.status, :online)
    })
  end

  defp note_set(current, opts) do
    case Keyword.fetch(opts, :set_write_available?) do
      {:ok, true} ->
        Map.put(current, :set_write_available_seen?, true)

      {:ok, false} ->
        current
        |> Map.put(:set_write_available_seen?, Map.fetch!(current, :set_write_available_seen?))
        |> Map.put(:set_unavailable_seen?, true)

      :error ->
        current
    end
  end

  defp failure_duration(%{first_failure_ms: nil}, _now), do: nil
  defp failure_duration(%{first_failure_ms: first}, now), do: max(now - first, 0)

  defp transition(status, status), do: nil
  defp transition(_from, :online), do: :online
  defp transition(_from, :suspect), do: :suspect
  defp transition(_from, :offline), do: :offline

  defp maybe_log_transition(%{status: status}, %{status: status}), do: :ok

  defp maybe_log_transition(current, next) do
    {node, drive} = next.endpoint
    level = if next.status == :offline, do: :warn, else: :info
    message = "drive health transition"

    fields = [
      action: :drive_health,
      status: next.status,
      reason:
        "node=#{inspect(node)} drive=#{drive} from=#{current.status} to=#{next.status} " <>
          "failure_count=#{next.failure_count} heal_required?=#{Map.fetch!(next, :heal_required?)}"
    ]

    apply(Log, level, [message, fields])
  end

  defp probe_drive(transport, {node, drive} = endpoint) do
    result =
      try do
        transport.probe_drive(node, drive)
      rescue
        e -> {:error, {:exception, Exception.message(e)}}
      catch
        kind, reason -> {:error, {kind, reason}}
      end

    {endpoint, result}
  end

  defp ok_result?({:ok, _}), do: true
  defp ok_result?(:ok), do: true
  defp ok_result?(_), do: false

  defp normalize_result(:ok), do: {:ok, :ok}
  defp normalize_result({:ok, _value} = ok), do: ok
  defp normalize_result({:error, reason}), do: {:error, reason}
  defp normalize_result(other), do: {:error, other}

  defp normalize_endpoint({node, drive}) when is_binary(drive), do: {node, Path.expand(drive)}

  defp default_status(endpoint) do
    %{
      endpoint: endpoint,
      status: :online,
      failure_count: 0,
      first_failure_ms: nil,
      last_failure_ms: nil,
      last_online_ms: nil,
      last_reason: nil,
      set_id: nil,
      set_write_available_seen?: false,
      set_unavailable_seen?: false,
      heal_required?: false,
      last_offline_duration_ms: nil,
      last_transition: nil
    }
  end

  defp topology_view(opts) do
    case Keyword.get(opts, :topology) do
      nil -> if Topology.configured?(), do: {:configured, nil}, else: :no_topology
      topology -> {:injected, topology}
    end
  end

  defp all_set_ids({:configured, nil}), do: Topology.all_set_ids()
  defp all_set_ids({:injected, topology}), do: Topology.all_set_ids_from(topology)

  defp endpoints({:configured, nil}, set_id), do: Topology.endpoints(set_id)
  defp endpoints({:injected, topology}, set_id), do: Topology.endpoints_from(topology, set_id)

  defp ec_params({:configured, nil}), do: Topology.ec_params()
  defp ec_params({:injected, topology}), do: Topology.ec_params_from(topology)

  defp write_quorum(view) do
    params = ec_params(view)
    n = Keyword.fetch!(params, :data_shards) + Keyword.fetch!(params, :parity_shards)
    drives = Enum.map(1..n, &"drive-#{&1}")
    Config.load!(Keyword.put(params, :drives, drives)).write_quorum
  end

  defp summarize_statuses(statuses, set_count) do
    counts = Enum.frequencies_by(statuses, & &1.status)

    %{
      sets: set_count,
      endpoints: length(statuses),
      online: Map.get(counts, :online, 0),
      suspect: Map.get(counts, :suspect, 0),
      offline: Map.get(counts, :offline, 0),
      heal_required: Enum.count(statuses, &Map.fetch!(&1, :heal_required?))
    }
  end

  defp zero_probe_summary do
    %{
      sets: 0,
      endpoints: 0,
      online: 0,
      suspect: 0,
      offline: 0,
      heal_required: 0
    }
  end

  defp offline_after_ms(opts) do
    opts
    |> Keyword.get(:offline_after_ms, default_offline_after_ms())
    |> non_negative_int(default_offline_after_ms())
  end

  defp now_ms(opts) do
    cond do
      is_integer(Keyword.get(opts, :now_ms)) ->
        Keyword.fetch!(opts, :now_ms)

      is_function(Keyword.get(opts, :now_fun), 0) ->
        opts |> Keyword.fetch!(:now_fun) |> apply([])

      true ->
        System.monotonic_time(:millisecond)
    end
  end

  defp non_negative_int(n, _default) when is_integer(n) and n >= 0, do: n
  defp non_negative_int(_n, default), do: default

  def statuses, do: @statuses
end
