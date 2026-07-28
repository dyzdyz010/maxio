defmodule Maxio.Ops.ClusterHealthConsole do
  @moduledoc """
  Read-only Console projection for cluster health and topology drift evidence.

  This module reads runtime/deployment topology, cluster node, pressure-cache,
  lock, and cache-invalidation evidence. It never refreshes telemetry, samples
  drives, acquires locks, mutates topology, or starts background work.
  """

  alias Maxio.Cluster
  alias Maxio.Cluster.{DriveDeviceIO, IOPressure, PressureAggregator, Topology, TopologyStore}

  @max_rows 24
  @max_text 480

  @doc "Load the read-only cluster health console projection."
  @spec load(keyword()) :: map()
  def load(opts \\ []) when is_list(opts) do
    runtime = runtime_topology(opts)
    persisted = persisted_topology(opts)
    drift = topology_drift(runtime, persisted)
    nodes = nodes(opts)
    pressure = pressure(opts)
    locks = locks(opts)
    cache_invalidation = cache_invalidation(opts)

    status =
      rollup_status([
        runtime.status,
        persisted.status,
        drift.status,
        nodes.status,
        pressure.status,
        locks.status,
        cache_invalidation.status
      ])

    %{
      status: status,
      readonly_boundary: readonly_boundary(),
      summary_rows:
        summary_rows(
          status,
          runtime,
          persisted,
          drift,
          nodes,
          pressure,
          locks,
          cache_invalidation
        ),
      nodes: nodes,
      runtime_topology: runtime,
      persisted_topology: persisted,
      topology_drift: drift,
      locks: locks,
      cache_invalidation: cache_invalidation,
      pressure: pressure,
      cross_links: cross_links()
    }
  end

  defp runtime_topology(opts) do
    fun = Keyword.get(opts, :runtime_topology_fun, &Topology.runtime_snapshot/0)

    case safe_call0(fun) do
      {:ok, %{} = snapshot} ->
        runtime_topology_from_snapshot(snapshot)

      {:ok, other} ->
        unavailable_section(
          "runtime-topology",
          "blocked",
          {:bad_runtime_topology_snapshot, other}
        )

      {:error, reason} ->
        unavailable_section("runtime-topology", "blocked", reason)
    end
  end

  defp runtime_topology_from_snapshot(snapshot) do
    status = status_text(map_get(snapshot, :runtime_status))
    hash = text(map_get(snapshot, :topology_hash))
    set_ids = list(map_get(snapshot, :set_ids, []))
    pool_ids = list(map_get(snapshot, :pool_ids, []))

    section_status =
      case status do
        "configured" -> "ok"
        "no_topology" -> "empty"
        "" -> "blocked"
        _other -> "attention"
      end

    %{
      status: section_status,
      raw_status: default_text(status, "missing"),
      hash: hash,
      set_ids: set_ids,
      pool_ids: pool_ids,
      rows: [
        row("runtime-node", "node", map_get(snapshot, :node)),
        row("runtime-status", "status", default_text(status, "missing")),
        row("runtime-hash", "topology_hash", hash),
        row("runtime-pools", "pool_ids", pool_ids),
        row("runtime-sets", "set_ids", set_ids)
      ]
    }
  end

  defp persisted_topology(opts) do
    fun = Keyword.get(opts, :persisted_topology_fun, &TopologyStore.active_revision_topology/1)
    persisted_opts = Keyword.get(opts, :persisted_topology_opts, [])

    case safe_call1(fun, persisted_opts) do
      {:ok, {:ok, %{revision: revision, topology: topology}}} ->
        persisted_topology_from_revision(revision, topology)

      {:ok, {:ok, %{topology: topology} = value}} ->
        persisted_topology_from_revision(map_get(value, :revision, %{}), topology)

      {:ok, {:error, :no_active_topology_revision}} ->
        %{
          status: "empty",
          raw_status: "no_active_topology_revision",
          hash: "-",
          set_ids: [],
          pool_ids: [],
          rows: [row("persisted-status", "status", "no_active_topology_revision")]
        }

      {:ok, {:error, reason}} ->
        unavailable_section("persisted-topology", "blocked", reason)

      {:ok, other} ->
        unavailable_section(
          "persisted-topology",
          "blocked",
          {:bad_persisted_topology_result, other}
        )

      {:error, reason} ->
        unavailable_section("persisted-topology", "blocked", reason)
    end
  end

  defp persisted_topology_from_revision(revision, topology) do
    case persisted_topology_hash(revision, topology) do
      {:ok, hash} ->
        set_ids = topology_list(topology, :set_ids)
        pool_ids = topology_list(topology, :pool_ids)

        %{
          status: "ok",
          raw_status: text(map_get(revision, :status, "active")),
          hash: hash,
          set_ids: set_ids,
          pool_ids: pool_ids,
          rows:
            [
              row("persisted-id", "revision_id", map_get(revision, :id)),
              row("persisted-status", "status", map_get(revision, :status, "active")),
              row("persisted-hash", "topology_hash", hash),
              row("persisted-source", "source", map_get(revision, :source)),
              row("persisted-source-job", "source_job_id", map_get(revision, :source_job_id)),
              row("persisted-activated", "activated_at", map_get(revision, :activated_at)),
              row("persisted-pools", "pool_ids", pool_ids),
              row("persisted-sets", "set_ids", set_ids)
            ]
            |> Enum.reject(&empty_row?/1)
        }

      {:error, reason} ->
        unavailable_section("persisted-topology", "blocked", reason)
    end
  end

  defp persisted_topology_hash(revision, topology) do
    revision
    |> map_get(:topology_hash)
    |> case do
      nil -> safe_topology_hash(topology)
      "" -> safe_topology_hash(topology)
      value -> {:ok, text(value)}
    end
  end

  defp topology_drift(runtime, persisted) do
    cond do
      runtime.status == "blocked" or persisted.status == "blocked" ->
        drift_section("blocked", "topology_evidence_unavailable", runtime, persisted)

      runtime.status == "empty" and persisted.status == "empty" ->
        drift_section("empty", "no_runtime_or_persisted_topology", runtime, persisted)

      runtime.status == "ok" and persisted.status == "empty" ->
        drift_section(
          "attention",
          "runtime_topology_without_persisted_revision",
          runtime,
          persisted
        )

      runtime.status == "empty" and persisted.status == "ok" ->
        drift_section("attention", "persisted_topology_without_runtime", runtime, persisted)

      runtime.hash != persisted.hash ->
        drift_section("blocked", "runtime_persisted_topology_hash_mismatch", runtime, persisted)

      true ->
        drift_section("ok", "runtime_persisted_topology_match", runtime, persisted)
    end
  end

  defp drift_section(status, reason, runtime, persisted) do
    %{
      status: status,
      reason: reason,
      rows: [
        row("topology-drift-status", "status", status),
        row("topology-drift-reason", "reason", reason),
        row("topology-drift-runtime-hash", "runtime_hash", runtime.hash),
        row("topology-drift-persisted-hash", "persisted_hash", persisted.hash),
        row("topology-drift-runtime-status", "runtime_status", runtime.raw_status),
        row("topology-drift-persisted-status", "persisted_status", persisted.raw_status)
      ]
    }
  end

  defp nodes(opts) do
    nodes_fun = Keyword.get(opts, :nodes_fun, &Cluster.nodes/0)
    alive_fun = Keyword.get(opts, :alive_fun, &Cluster.alive?/1)

    case safe_call0(nodes_fun) do
      {:ok, nodes} when is_list(nodes) ->
        rows =
          nodes
          |> Enum.take(@max_rows)
          |> Enum.map(fn node ->
            alive? =
              case safe_call1(alive_fun, node) do
                {:ok, value} -> value == true
                {:error, _reason} -> false
              end

            %{
              id: safe_id(node),
              node: text(node),
              status: if(alive?, do: "ok", else: "blocked"),
              role: if(node == Node.self(), do: "local", else: "peer")
            }
          end)

        %{status: node_rows_status(rows), rows: rows}

      {:ok, other} ->
        node_error_section({:bad_nodes_result, other})

      {:error, reason} ->
        node_error_section(reason)
    end
  end

  defp pressure(opts) do
    local = local_pressure(opts)
    peers = peer_pressure(opts)
    device = device_pressure(opts)

    %{
      status: rollup_status([local.status, peers.status, device.status]),
      local: local,
      peers: peers,
      device: device
    }
  end

  defp local_pressure(opts) do
    fun = Keyword.get(opts, :local_pressure_fun, &IOPressure.local_snapshot/0)

    case safe_call0(fun) do
      {:ok, %{} = snapshot} ->
        rows =
          [:s3_in_flight, :storage_ops, :combined, :drive_device_io]
          |> Enum.map(fn source ->
            row("local-pressure-#{source}", Atom.to_string(source), map_get(snapshot, source, 0))
          end)

        %{status: "ok", rows: rows}

      {:ok, other} ->
        rows_error_section("local-pressure", {:bad_local_pressure_result, other})

      {:error, reason} ->
        rows_error_section("local-pressure", reason)
    end
  end

  defp peer_pressure(opts) do
    fun = Keyword.get(opts, :peer_pressure_fun, &PressureAggregator.snapshot/1)
    peer_opts = Keyword.get(opts, :peer_pressure_opts, [])

    case safe_call1(fun, peer_opts) do
      {:ok, peers} when is_map(peers) ->
        rows =
          peers
          |> Enum.take(@max_rows)
          |> Enum.map(fn {node, snapshot} ->
            %{
              id: safe_id(node),
              node: text(node),
              status: "ok",
              s3_in_flight: text(map_get(snapshot, :s3_in_flight, 0)),
              storage_ops: text(map_get(snapshot, :storage_ops, 0)),
              combined: text(map_get(snapshot, :combined, 0)),
              drive_device_io: text(map_get(snapshot, :drive_device_io, 0))
            }
          end)

        %{status: if(rows == [], do: "empty", else: "ok"), rows: rows}

      {:ok, other} ->
        table_error_section("peer-pressure", {:bad_peer_pressure_result, other})

      {:error, reason} ->
        table_error_section("peer-pressure", reason)
    end
  end

  defp device_pressure(opts) do
    fun = Keyword.get(opts, :device_io_fun, &DriveDeviceIO.snapshot/1)
    device_opts = Keyword.get(opts, :device_io_opts, [])

    case safe_call1(fun, device_opts) do
      {:ok, %{} = summary} ->
        status = device_status(map_get(summary, :status))

        %{
          status: status,
          rows: [
            row("device-pressure-status", "status", map_get(summary, :status)),
            row(
              "device-pressure-topology-sets",
              "topology_sets",
              map_get(summary, :topology_sets, 0)
            ),
            row("device-pressure-endpoints", "endpoints", map_get(summary, :endpoints, 0)),
            row("device-pressure-ok", "ok", map_get(summary, :ok, 0)),
            row("device-pressure-errors", "errors", map_get(summary, :errors, 0)),
            row("device-pressure-pressure", "pressure", map_get(summary, :pressure, 0)),
            row("device-pressure-observed", "observed_at_ms", map_get(summary, :observed_at_ms))
          ],
          samples: device_samples(map_get(summary, :samples, []))
        }

      {:ok, other} ->
        rows_error_section("device-pressure", {:bad_device_pressure_result, other})
        |> Map.put(:samples, [])

      {:error, reason} ->
        rows_error_section("device-pressure", reason)
        |> Map.put(:samples, [])
    end
  end

  defp device_samples(samples) when is_list(samples) do
    samples
    |> Enum.take(@max_rows)
    |> Enum.with_index()
    |> Enum.map(fn {sample, index} ->
      %{
        id: safe_id("#{map_get(sample, :set_id, "sample")}-#{index}"),
        status: sample_status(map_get(sample, :status)),
        endpoint: text(map_get(sample, :endpoint)),
        set_id: text(map_get(sample, :set_id)),
        drive: text(map_get(sample, :drive)),
        pressure: text(map_get(sample, :pressure, 0)),
        queue_depth: text(map_get(sample, :queue_depth, 0)),
        busy_percent_x100: text(map_get(sample, :busy_percent_x100, 0)),
        reason: text(map_get(sample, :reason))
      }
    end)
  end

  defp device_samples(_samples), do: []

  defp locks(opts) do
    process_lookup = Keyword.get(opts, :process_lookup_fun, &Process.whereis/1)
    pid = safe_process_lookup(process_lookup, Maxio.Cluster.LockServer)

    %{
      status: if(pid, do: "ok", else: "attention"),
      rows: [
        row("locks-lock-server", "lock_server", process_status(pid)),
        row("locks-facade", "facade", "Maxio.Cluster.Lock"),
        row("locks-boundary", "boundary", "read-only; no acquire/with_lock/force_unlock")
      ]
    }
  end

  defp cache_invalidation(opts) do
    process_lookup = Keyword.get(opts, :process_lookup_fun, &Process.whereis/1)
    invalidator = safe_process_lookup(process_lookup, Maxio.Cluster.CacheInvalidator)
    pubsub = safe_process_lookup(process_lookup, Maxio.PubSub)

    %{
      status: if(invalidator && pubsub, do: "ok", else: "attention"),
      rows: [
        row("cache-invalidation-pubsub", "pubsub", process_status(pubsub)),
        row("cache-invalidation-process", "cache_invalidator", process_status(invalidator)),
        row("cache-invalidation-topic", "topic", Maxio.Cluster.Notify.topic()),
        row("cache-invalidation-boundary", "boundary", "read-only; no broadcast")
      ]
    }
  end

  defp summary_rows(status, runtime, persisted, drift, nodes, pressure, locks, cache_invalidation) do
    [
      row("summary-status", "status", status),
      row("summary-drift", "topology_drift", drift.status),
      row("summary-runtime", "runtime_topology", runtime.raw_status),
      row("summary-persisted", "persisted_topology", persisted.raw_status),
      row("summary-nodes", "nodes", length(nodes.rows)),
      row("summary-peer-pressure", "peer_pressure_rows", length(pressure.peers.rows)),
      row("summary-device-pressure", "device_pressure", pressure.device.status),
      row("summary-locks", "locks", locks.status),
      row("summary-cache-invalidation", "cache_invalidation", cache_invalidation.status)
    ]
  end

  defp readonly_boundary do
    %{
      message:
        "This page only reads cluster health, topology drift, pressure cache, lock, and cache invalidation evidence.",
      forbidden: [
        "Topology.install_runtime!",
        "Topology.install_runtime_if_hash",
        "TopologyStore.activate_topology",
        "Lock.acquire/with_lock/force_unlock",
        "PressureAggregator.refresh_once",
        "DriveDeviceIO.refresh_once/sample_topology",
        "scan/heal/rebalance/scheduler run APIs",
        "System.cmd/Mix.Task.run"
      ]
    }
  end

  defp cross_links do
    [
      %{id: "ops-cluster-link-scan", label: "Ops Scan", path: "/ops/scan"},
      %{id: "ops-cluster-link-rebalance", label: "Ops Rebalance", path: "/ops/rebalance"},
      %{id: "ops-cluster-link-replacement", label: "Ops Replacement", path: "/ops/replacement"},
      %{id: "ops-cluster-link-gate", label: "Ops Gate", path: "/ops/gate"}
    ]
  end

  defp unavailable_section(prefix, status, reason) do
    %{
      status: status,
      raw_status: "unavailable",
      hash: "-",
      set_ids: [],
      pool_ids: [],
      rows: [
        row("#{prefix}-status", "status", "unavailable"),
        row("#{prefix}-reason", "reason", reason)
      ]
    }
  end

  defp node_error_section(reason) do
    %{
      status: "blocked",
      rows: [%{id: "nodes-error", node: "-", status: "blocked", role: text(reason)}]
    }
  end

  defp rows_error_section(prefix, reason) do
    %{status: "blocked", rows: [row("#{prefix}-error", "error", reason)]}
  end

  defp table_error_section(prefix, reason) do
    %{
      status: "blocked",
      rows: [
        %{
          id: "#{prefix}-error",
          node: "-",
          status: "blocked",
          s3_in_flight: "-",
          storage_ops: "-",
          combined: "-",
          drive_device_io: text(reason)
        }
      ]
    }
  end

  defp rollup_status(statuses) do
    statuses = Enum.map(statuses, &section_status/1)

    cond do
      Enum.any?(statuses, &(&1 == "blocked")) -> "blocked"
      Enum.any?(statuses, &(&1 in ["attention", "empty", "missing"])) -> "attention"
      true -> "ok"
    end
  end

  defp node_rows_status([]), do: "empty"

  defp node_rows_status(rows) do
    if Enum.any?(rows, &(&1.status == "blocked")), do: "blocked", else: "ok"
  end

  defp section_status(status) do
    case status_text(status) do
      value when value in ["ok", "ready"] -> "ok"
      value when value in ["blocked", "failed", "error", "unavailable", "missing"] -> "blocked"
      value when value in ["attention", "empty", "no_topology", "unknown"] -> value
      _other -> "attention"
    end
  end

  defp device_status(status) do
    case status_text(status) do
      "ok" -> "ok"
      "partial" -> "attention"
      "no_topology" -> "empty"
      "" -> "missing"
      _other -> "attention"
    end
  end

  defp sample_status(status) do
    case status_text(status) do
      "ok" -> "ok"
      "error" -> "blocked"
      "" -> "missing"
      other -> other
    end
  end

  defp safe_process_lookup(fun, name) do
    case safe_call1(fun, name) do
      {:ok, pid} when is_pid(pid) -> pid
      _other -> nil
    end
  end

  defp process_status(nil), do: "missing"
  defp process_status(pid) when is_pid(pid), do: "alive"

  defp safe_topology_hash(topology) do
    result =
      try do
        {:ok, Topology.fingerprint(topology)}
      rescue
        error -> {:error, {:topology_fingerprint_failed, Exception.message(error)}}
      catch
        kind, reason -> {:error, {:topology_fingerprint_failed, kind, reason}}
      end

    case result do
      {:ok, hash} -> {:ok, hash}
      {:error, reason} -> {:error, reason}
    end
  end

  defp topology_list(topology, :set_ids) do
    try do
      Topology.all_set_ids_from(topology)
    rescue
      _error -> []
    catch
      _kind, _reason -> []
    end
  end

  defp topology_list(topology, :pool_ids) do
    try do
      Topology.pool_ids_from(topology)
    rescue
      _error -> []
    catch
      _kind, _reason -> []
    end
  end

  defp row(id, label, value), do: %{id: id, label: label, value: text(value)}

  defp empty_row?(%{value: value}), do: value in ["", "-"]

  defp safe_call0(fun) when is_function(fun, 0) do
    {:ok, fun.()}
  rescue
    error -> {:error, {:crashed, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:caught, kind, reason}}
  end

  defp safe_call1(fun, arg) when is_function(fun, 1) do
    {:ok, fun.(arg)}
  rescue
    error -> {:error, {:crashed, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:caught, kind, reason}}
  end

  defp map_get(value, key, default \\ nil)

  defp map_get(%{} = map, key, default) do
    Map.get(map, key, Map.get(map, to_string(key), default))
  end

  defp map_get(_value, _key, default), do: default

  defp list(values) when is_list(values), do: values
  defp list(_value), do: []

  defp status_text(nil), do: ""
  defp status_text(value) when is_atom(value), do: Atom.to_string(value)
  defp status_text(value) when is_binary(value), do: value
  defp status_text(value), do: to_string(value)

  defp default_text("", default), do: default
  defp default_text(nil, default), do: default
  defp default_text(value, _default), do: text(value)

  defp text(nil), do: "-"
  defp text(""), do: "-"
  defp text(value) when is_atom(value), do: Atom.to_string(value)
  defp text(value) when is_boolean(value), do: to_string(value)
  defp text(value) when is_number(value), do: to_string(value)
  defp text(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp text(value) when is_binary(value) do
    String.slice(value, 0, @max_text)
  end

  defp text(value) when is_list(value) or is_map(value) or is_tuple(value) do
    value
    |> inspect(limit: 20, printable_limit: @max_text)
    |> String.slice(0, @max_text)
  end

  defp text(value), do: value |> inspect(limit: 10) |> String.slice(0, @max_text)

  defp safe_id(nil), do: "unknown"

  defp safe_id(value) do
    value
    |> to_string()
    |> String.replace(~r/[^A-Za-z0-9_-]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "unknown"
      id -> id
    end
  end
end
