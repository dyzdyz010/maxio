defmodule Maxio.Cluster.Rebalance do
  @moduledoc """
  Read-only rebalance/decommission planning telemetry.

  This module does not move data and does not change routing. It accounts object
  metadata against the currently configured topology so operators can see the
  logical bytes and version rows that a future rebalance/decommission workflow
  would need to reason about.
  """

  alias Maxio.{Buckets, Objects}
  alias Maxio.Cluster.{DriveStats, Placement, Topology}
  alias Maxio.S3.Log

  @default_page_size 500

  @type set_summary :: %{
          set_id: Topology.set_id(),
          target?: boolean(),
          endpoints: non_neg_integer(),
          objects: non_neg_integer(),
          versions: non_neg_integer(),
          delete_markers: non_neg_integer(),
          placement_fallbacks: non_neg_integer(),
          bytes: non_neg_integer(),
          drive_endpoints: non_neg_integer(),
          drive_ok: non_neg_integer(),
          drive_errors: non_neg_integer(),
          drive_capacity_bytes: non_neg_integer(),
          drive_free_bytes: non_neg_integer(),
          drive_min_free_bytes: non_neg_integer()
        }

  @type report :: %{
          status: :ok | :partial | :no_topology,
          scope: :versions | :current_only,
          current_only: boolean(),
          topology_sets: non_neg_integer(),
          endpoints: non_neg_integer(),
          buckets: non_neg_integer(),
          pages: non_neg_integer(),
          scanned: non_neg_integer(),
          objects: non_neg_integer(),
          versions: non_neg_integer(),
          delete_markers: non_neg_integer(),
          placement_fallbacks: non_neg_integer(),
          bytes: non_neg_integer(),
          decommission_set: Topology.set_id() | nil,
          decommission: map(),
          drive_stats: map(),
          per_set: [set_summary()],
          warnings: [atom()]
        }

  @doc """
  Build a read-only placement/accounting plan for the current topology.

  Options:

    * `:topology` - injected topology; explicit `nil` forces `:no_topology`.
    * `:current_only` - restricts to ListObjectsV2 current, non-delete rows.
      Defaults to false because decommission must account version history.
    * `:decommission_set` - marks one set and returns its impacted totals.
    * `:page_size` - object inventory page size, default #{@default_page_size}.
    * `:include_drive_stats` - defaults true; false skips capacity telemetry.
    * `:drive_stats_fun` - test seam, called as `fun.(opts)`.
  """
  @spec plan(keyword()) :: {:ok, report()} | {:error, term()}
  def plan(opts \\ []) do
    case topology_view(opts) do
      :no_topology ->
        {:ok, no_topology_report(opts)}

      view ->
        set_ids = all_set_ids(view)
        decommission_set = Keyword.get(opts, :decommission_set)

        with :ok <- validate_decommission_set(decommission_set, set_ids) do
          cfg = config(opts, view, set_ids)

          report =
            cfg
            |> zero_report()
            |> scan_buckets(cfg)
            |> attach_drive_stats(cfg)
            |> finalize_report()

          Log.info("rebalance plan complete",
            action: :rebalance_plan,
            reason:
              "status=#{report.status} topology_sets=#{report.topology_sets} " <>
                "buckets=#{report.buckets} scanned=#{report.scanned} " <>
                "versions=#{report.versions} delete_markers=#{report.delete_markers} " <>
                "bytes=#{report.bytes} decommission_set=#{inspect(report.decommission_set)}"
          )

          {:ok, report}
        end
    end
  end

  @doc "Build a read-only impact plan for a single erasure set."
  @spec decommission_impact(Topology.set_id(), keyword()) :: {:ok, report()} | {:error, term()}
  def decommission_impact(set_id, opts \\ []),
    do: plan(Keyword.put(opts, :decommission_set, set_id))

  defp config(opts, view, set_ids) do
    current_only = Keyword.get(opts, :current_only, false)

    [
      view: view,
      placement_opts: placement_opts(view),
      set_ids: set_ids,
      current_only: current_only,
      scope: if(current_only, do: :current_only, else: :versions),
      page_size: positive_int(Keyword.get(opts, :page_size), @default_page_size),
      decommission_set: Keyword.get(opts, :decommission_set),
      include_drive_stats: Keyword.get(opts, :include_drive_stats, true),
      drive_stats_fun: Keyword.get(opts, :drive_stats_fun, &DriveStats.sample_topology/1)
    ]
  end

  defp zero_report(cfg) do
    set_ids = Keyword.fetch!(cfg, :set_ids)
    view = Keyword.fetch!(cfg, :view)

    per_set =
      Map.new(set_ids, fn set_id ->
        {set_id,
         %{
           set_id: set_id,
           target?: Keyword.get(cfg, :decommission_set) == set_id,
           endpoints: length(endpoints(view, set_id)),
           objects: 0,
           versions: 0,
           delete_markers: 0,
           placement_fallbacks: 0,
           bytes: 0,
           drive_endpoints: 0,
           drive_ok: 0,
           drive_errors: 0,
           drive_capacity_bytes: 0,
           drive_free_bytes: 0,
           drive_min_free_bytes: 0
         }}
      end)

    %{
      status: :ok,
      scope: Keyword.fetch!(cfg, :scope),
      current_only: Keyword.fetch!(cfg, :current_only),
      topology_sets: length(set_ids),
      endpoints:
        Enum.reduce(set_ids, 0, fn set_id, acc -> acc + length(endpoints(view, set_id)) end),
      buckets: 0,
      pages: 0,
      scanned: 0,
      objects: 0,
      versions: 0,
      delete_markers: 0,
      placement_fallbacks: 0,
      bytes: 0,
      decommission_set: Keyword.get(cfg, :decommission_set),
      decommission: empty_decommission(Keyword.get(cfg, :decommission_set)),
      drive_stats: disabled_drive_stats(),
      per_set: per_set,
      warnings: []
    }
  end

  defp scan_buckets(report, cfg) do
    buckets = Buckets.list() |> Enum.map(& &1.name)
    report = %{report | buckets: length(buckets)}

    Enum.reduce(buckets, report, fn bucket, acc ->
      scan_bucket(bucket, cfg, acc)
    end)
  end

  defp scan_bucket(bucket, cfg, report) do
    if cfg[:current_only] do
      reduce_current_pages(bucket, cfg, report, nil)
    else
      reduce_version_pages(bucket, cfg, report, nil, nil)
    end
  end

  defp reduce_current_pages(bucket, cfg, report, cursor) do
    page =
      Objects.list_objects_v2(bucket, %{
        max_keys: cfg[:page_size],
        continuation_token: cursor
      })

    report =
      page.objects
      |> Enum.reduce(%{report | pages: report.pages + 1}, fn object, acc ->
        account_object(bucket, object, cfg, acc)
      end)

    if page.is_truncated do
      reduce_current_pages(bucket, cfg, report, page.next_continuation_token)
    else
      report
    end
  end

  defp reduce_version_pages(bucket, cfg, report, key_marker, version_marker) do
    page =
      Objects.list_object_versions(bucket, %{
        max_keys: cfg[:page_size],
        key_marker: key_marker,
        version_id_marker: version_marker
      })

    report =
      page.versions
      |> Enum.reduce(%{report | pages: report.pages + 1}, fn object, acc ->
        account_object(bucket, object, cfg, acc)
      end)

    if page.is_truncated do
      reduce_version_pages(bucket, cfg, report, page.next_key_marker, page.next_version_id_marker)
    else
      report
    end
  end

  defp account_object(bucket, object, cfg, report) do
    placement = placement_for(bucket, object, cfg)
    set_id = placement.set_id
    placement_fallbacks = if placement.source == :persisted, do: 0, else: 1
    delete_marker? = object.is_delete_marker
    bytes = if delete_marker?, do: 0, else: non_negative_int(object.size)
    objects = if delete_marker?, do: 0, else: 1
    delete_markers = if delete_marker?, do: 1, else: 0

    delta = %{
      scanned: 1,
      objects: objects,
      versions: 1,
      delete_markers: delete_markers,
      placement_fallbacks: placement_fallbacks,
      bytes: bytes
    }

    report
    |> add_totals(delta)
    |> update_set(set_id, delta)
    |> maybe_add_decommission(set_id, cfg[:decommission_set], delta)
  end

  defp placement_for(bucket, object, cfg) do
    case Placement.resolve_object(bucket, object, cfg[:placement_opts]) do
      {:ok, placement} ->
        placement

      {:error, {:unknown_set_id, _set_id, _set_ids}} ->
        {:ok, placement} = Placement.resolve(bucket, object.key, cfg[:placement_opts])
        %{placement | source: :router}
    end
  end

  defp attach_drive_stats(report, cfg) do
    if cfg[:include_drive_stats] do
      drive_stats = sample_drive_stats(cfg)
      by_set = drive_stats_by_set(drive_stats)

      report =
        Enum.reduce(by_set, report, fn {set_id, stats}, acc ->
          update_set_drive_stats(acc, set_id, stats)
        end)

      warnings =
        if drive_stats.status == :partial,
          do: [:drive_stats_partial | report.warnings],
          else: report.warnings

      %{
        report
        | status: if(drive_stats.status == :partial, do: :partial, else: report.status),
          drive_stats: Map.delete(drive_stats, :samples),
          warnings: Enum.uniq(warnings)
      }
    else
      report
    end
  end

  defp sample_drive_stats(cfg) do
    opts =
      case cfg[:view] do
        {:injected, topology} -> [topology: topology]
        {:configured, nil} -> []
      end

    cfg[:drive_stats_fun].(opts)
  end

  defp drive_stats_by_set(%{samples: samples}) do
    samples
    |> Enum.group_by(& &1.set_id)
    |> Map.new(fn {set_id, set_samples} -> {set_id, summarize_drive_samples(set_samples)} end)
  end

  defp summarize_drive_samples(samples) do
    ok_samples = Enum.filter(samples, &(&1.status == :ok))
    errors = length(samples) - length(ok_samples)

    %{
      drive_endpoints: length(samples),
      drive_ok: length(ok_samples),
      drive_errors: errors,
      drive_capacity_bytes: sum(ok_samples, :capacity_bytes),
      drive_free_bytes: sum(ok_samples, :free_bytes),
      drive_min_free_bytes: min_field(ok_samples, :free_bytes)
    }
  end

  defp finalize_report(report) do
    per_set =
      report.per_set
      |> Map.values()
      |> Enum.sort_by(& &1.set_id)

    decommission =
      case report.decommission_set do
        nil -> empty_decommission(nil)
        set_id -> Enum.find(per_set, &(&1.set_id == set_id)) || empty_decommission(set_id)
      end

    %{report | per_set: per_set, decommission: decommission}
  end

  defp add_totals(report, delta) do
    %{
      report
      | scanned: report.scanned + delta.scanned,
        objects: report.objects + delta.objects,
        versions: report.versions + delta.versions,
        delete_markers: report.delete_markers + delta.delete_markers,
        placement_fallbacks: report.placement_fallbacks + delta.placement_fallbacks,
        bytes: report.bytes + delta.bytes
    }
  end

  defp update_set(report, set_id, delta) do
    update_in(report.per_set[set_id], fn set ->
      %{
        set
        | objects: set.objects + delta.objects,
          versions: set.versions + delta.versions,
          delete_markers: set.delete_markers + delta.delete_markers,
          placement_fallbacks: set.placement_fallbacks + delta.placement_fallbacks,
          bytes: set.bytes + delta.bytes
      }
    end)
  end

  defp update_set_drive_stats(report, nil, _stats), do: report

  defp update_set_drive_stats(report, set_id, stats) do
    update_in(report.per_set[set_id], fn
      nil -> nil
      set -> Map.merge(set, stats)
    end)
  end

  defp maybe_add_decommission(report, set_id, target_set, delta)
       when not is_nil(target_set) and set_id == target_set do
    update_in(report.decommission, fn decommission ->
      %{
        decommission
        | objects: decommission.objects + delta.objects,
          versions: decommission.versions + delta.versions,
          delete_markers: decommission.delete_markers + delta.delete_markers,
          placement_fallbacks: decommission.placement_fallbacks + delta.placement_fallbacks,
          bytes: decommission.bytes + delta.bytes
      }
    end)
  end

  defp maybe_add_decommission(report, _set_id, _target_set, _delta), do: report

  defp no_topology_report(opts) do
    current_only = Keyword.get(opts, :current_only, false)

    %{
      status: :no_topology,
      scope: if(current_only, do: :current_only, else: :versions),
      current_only: current_only,
      topology_sets: 0,
      endpoints: 0,
      buckets: 0,
      pages: 0,
      scanned: 0,
      objects: 0,
      versions: 0,
      delete_markers: 0,
      placement_fallbacks: 0,
      bytes: 0,
      decommission_set: Keyword.get(opts, :decommission_set),
      decommission: empty_decommission(Keyword.get(opts, :decommission_set)),
      drive_stats: disabled_drive_stats(),
      per_set: [],
      warnings: [:no_topology]
    }
  end

  defp empty_decommission(set_id) do
    %{
      set_id: set_id,
      objects: 0,
      versions: 0,
      delete_markers: 0,
      placement_fallbacks: 0,
      bytes: 0
    }
  end

  defp disabled_drive_stats do
    %{
      status: :disabled,
      topology_sets: 0,
      endpoints: 0,
      ok: 0,
      errors: 0,
      capacity_bytes: 0,
      free_bytes: 0,
      used_bytes: 0,
      min_free_bytes: 0,
      min_free_percent_x100: 0
    }
  end

  defp validate_decommission_set(nil, _set_ids), do: :ok

  defp validate_decommission_set(set_id, set_ids) do
    if Enum.member?(set_ids, set_id) do
      :ok
    else
      {:error, {:unknown_set_id, set_id, set_ids}}
    end
  end

  defp topology_view(opts) do
    case Keyword.fetch(opts, :topology) do
      {:ok, nil} -> :no_topology
      {:ok, topology} -> {:injected, topology}
      :error -> if Topology.configured?(), do: {:configured, nil}, else: :no_topology
    end
  end

  defp placement_opts({:configured, nil}), do: []
  defp placement_opts({:injected, topology}), do: [topology: topology]

  defp all_set_ids({:configured, nil}), do: Topology.all_set_ids()
  defp all_set_ids({:injected, topology}), do: Topology.all_set_ids_from(topology)

  defp endpoints({:configured, nil}, set_id), do: Topology.endpoints(set_id)
  defp endpoints({:injected, topology}, set_id), do: Topology.endpoints_from(topology, set_id)

  defp positive_int(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_int(_value, default), do: default

  defp non_negative_int(value) when is_integer(value) and value >= 0, do: value
  defp non_negative_int(_value), do: 0

  defp sum(samples, key),
    do: Enum.reduce(samples, 0, fn sample, acc -> acc + Map.fetch!(sample, key) end)

  defp min_field([], _key), do: 0
  defp min_field(samples, key), do: samples |> Enum.map(&Map.fetch!(&1, key)) |> Enum.min()
end
