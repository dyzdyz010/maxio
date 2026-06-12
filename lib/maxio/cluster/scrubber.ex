defmodule Maxio.Cluster.Scrubber do
  @moduledoc """
  Periodic operational scrubber for usage accounting and metadata-driven auto-heal.

  This is separate from `Maxio.Storage.Scanner`, which reconciles disk sidecars into
  the PG derived index. Scrubber reads the PG object index as the object inventory,
  refreshes bucket usage snapshots, and invokes the existing heal engines only for
  erasure-coded backends.
  """
  use GenServer

  alias Maxio.{Buckets, Objects}
  alias Maxio.Cluster.{DriveHealth, Lock, Router, Topology}
  alias Maxio.Cluster.Scrubber.{Throttle, Usage}
  alias Maxio.S3.Log
  alias Maxio.Storage.{Distributed, ErasureCoded, Scanner}
  alias Maxio.Storage.Erasure.Heal, as: LocalHeal
  alias Maxio.Cluster.Heal, as: ClusterHeal

  @count_keys [:scanned, :damaged, :healed, :unrecoverable, :missing, :skipped, :sampled_out]
  @usage_keys [:object_count, :total_size]

  @type summary :: %{
          status: :ok,
          backend: atom(),
          buckets: non_neg_integer(),
          scanned: non_neg_integer(),
          damaged: non_neg_integer(),
          healed: non_neg_integer(),
          unrecoverable: non_neg_integer(),
          missing: non_neg_integer(),
          skipped: non_neg_integer(),
          sampled_out: non_neg_integer(),
          index_status: atom(),
          index_scanned: non_neg_integer(),
          index_upserted: non_neg_integer(),
          index_gc: non_neg_integer(),
          index_skipped: non_neg_integer(),
          index_divergent: non_neg_integer(),
          index_orphan_shards: non_neg_integer(),
          index_orphan_bytes: non_neg_integer(),
          index_orphan_cleaned: non_neg_integer(),
          index_orphan_cleaned_bytes: non_neg_integer(),
          drive_sets: non_neg_integer(),
          drive_endpoints: non_neg_integer(),
          drive_online: non_neg_integer(),
          drive_suspect: non_neg_integer(),
          drive_offline: non_neg_integer(),
          drive_heal_required: non_neg_integer(),
          object_count: non_neg_integer(),
          total_size: non_neg_integer()
        }

  @doc false
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    cfg = config(opts)

    if cfg[:enabled] do
      Log.info(
        "scrubber enabled: periodic usage/auto-heal scan scheduled",
        action: :scrubber,
        reason:
          "interval_ms=#{cfg[:interval_ms]} page_size=#{cfg[:page_size]} scan_versions=#{cfg[:scan_versions]}"
      )

      schedule(cfg[:initial_delay_ms])
      {:ok, %{enabled: true, interval_ms: cfg[:interval_ms], opts: opts, cycle: 0}}
    else
      Log.info(
        "scrubber disabled: periodic usage/auto-heal scan NOT scheduled",
        action: :scrubber,
        reason: "enable via config :maxio, :scrubber, enabled: true"
      )

      {:ok, %{enabled: false}}
    end
  end

  @impl true
  def handle_info(
        :scrub,
        %{enabled: true, interval_ms: interval, opts: opts, cycle: cycle} = state
      ) do
    safe_run(Keyword.merge(opts, sample: :configured, sample_cycle: cycle))
    schedule(interval)
    {:noreply, %{state | cycle: cycle + 1}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @doc "Trigger one scan through the supervised process when it is running."
  @spec scan_now(keyword()) :: {:ok, summary()}
  def scan_now(opts \\ []), do: GenServer.call(__MODULE__, {:scan_now, opts}, :infinity)

  @impl true
  def handle_call({:scan_now, opts}, _from, state) do
    {:reply, run_once(opts), state}
  end

  @doc """
  Run one metadata-driven scrub round.

  Options:

    * `:bucket` - restrict to one bucket name;
    * `:backend` - override configured storage backend;
    * `:page_size` - metadata page size, default from `config :maxio, :scrubber`;
    * `:scan_versions` - scan every version instead of only current non-delete rows;
    * `:no_throttle` - skip sleeps, intended for tests and one-shot CI checks.
  """
  @spec run_once(keyword()) :: {:ok, summary()}
  def run_once(opts \\ []) do
    cfg = config(opts)
    backend = backend(cfg)
    cfg = Keyword.put(cfg, :resolved_backend, backend)
    cfg = Keyword.put(cfg, :throttle, Throttle.new(cfg))
    buckets = bucket_names(cfg[:bucket])
    index_report = maybe_reconcile_index(cfg)
    drive_report = maybe_probe_drive_health(backend, cfg)

    {summary, _throttle} =
      buckets
      |> Enum.reduce(
        {zero_summary(backend)
         |> merge_index_report(index_report)
         |> merge_drive_report(drive_report), cfg[:throttle]},
        fn bucket, {acc, throttle} ->
          {bucket_summary, throttle} =
            scan_bucket(bucket, backend, Keyword.put(cfg, :throttle, throttle))

          {merge_summary(acc, bucket_summary), throttle}
        end
      )

    summary = Map.put(summary, :buckets, length(buckets))

    Log.info(
      "scrubber round complete",
      action: :scrubber,
      reason:
        "backend=#{inspect(backend)} buckets=#{summary.buckets} scanned=#{summary.scanned} " <>
          "damaged=#{summary.damaged} healed=#{summary.healed} unrecoverable=#{summary.unrecoverable} " <>
          "missing=#{summary.missing} skipped=#{summary.skipped} sampled_out=#{summary.sampled_out} " <>
          "index_status=#{summary.index_status} index_scanned=#{summary.index_scanned} " <>
          "index_upserted=#{summary.index_upserted} index_gc=#{summary.index_gc} " <>
          "index_skipped=#{summary.index_skipped} index_divergent=#{summary.index_divergent} " <>
          "index_orphan_shards=#{summary.index_orphan_shards} " <>
          "index_orphan_bytes=#{summary.index_orphan_bytes} " <>
          "index_orphan_cleaned=#{summary.index_orphan_cleaned} " <>
          "index_orphan_cleaned_bytes=#{summary.index_orphan_cleaned_bytes} " <>
          "drive_sets=#{summary.drive_sets} drive_endpoints=#{summary.drive_endpoints} " <>
          "drive_online=#{summary.drive_online} drive_suspect=#{summary.drive_suspect} " <>
          "drive_offline=#{summary.drive_offline} " <>
          "drive_heal_required=#{summary.drive_heal_required} " <>
          "objects=#{summary.object_count} bytes=#{summary.total_size}"
    )

    {:ok, summary}
  end

  defp maybe_reconcile_index(cfg) do
    if cfg[:reconcile_index] do
      scanner_opts = scanner_opts(cfg)

      case Scanner.run_once(scanner_opts) do
        {:ok, report} -> report
      end
    else
      zero_index_report(:not_run)
    end
  rescue
    e ->
      Log.error("scrubber index reconcile pre-pass crashed",
        action: :scrubber,
        reason: Exception.message(e)
      )

      zero_index_report(:error)
  catch
    kind, reason ->
      Log.error("scrubber index reconcile pre-pass caught",
        action: :scrubber,
        reason: inspect({kind, reason})
      )

      zero_index_report(:error)
  end

  defp maybe_probe_drive_health(Distributed, cfg) do
    if cfg[:drive_health_enabled] do
      [
        topology: cfg[:topology],
        transport: cfg[:transport],
        offline_after_ms: cfg[:drive_offline_after_ms],
        now_fun: cfg[:drive_health_now_fun]
      ]
      |> Keyword.reject(fn {_key, value} -> is_nil(value) end)
      |> DriveHealth.probe_topology()
    else
      zero_drive_report()
    end
  rescue
    e ->
      Log.error("scrubber drive health probe crashed",
        action: :drive_health,
        reason: Exception.message(e)
      )

      zero_drive_report()
  catch
    kind, reason ->
      Log.error("scrubber drive health probe caught",
        action: :drive_health,
        reason: inspect({kind, reason})
      )

      zero_drive_report()
  end

  defp maybe_probe_drive_health(_backend, _cfg), do: zero_drive_report()

  defp scanner_opts(cfg) do
    [
      bucket: cfg[:bucket],
      force: cfg[:force_reconcile_index],
      dry_run: cfg[:reconcile_index_dry_run],
      batch_size: cfg[:reconcile_batch_size],
      cleanup_orphan_shards: cfg[:cleanup_orphan_shards],
      orphan_cleanup_dry_run: cfg[:orphan_cleanup_dry_run],
      orphan_cleanup_min_age_ms: cfg[:orphan_cleanup_min_age_ms],
      orphan_cleanup_max_deletes: cfg[:orphan_cleanup_max_deletes],
      drive_offline_after_ms: cfg[:drive_offline_after_ms],
      transport: cfg[:transport],
      authoritative_source: cfg[:authoritative_source]
    ]
    |> Keyword.reject(fn {_key, value} -> is_nil(value) end)
    |> maybe_put_scanner_topology(cfg)
  end

  defp maybe_put_scanner_topology(opts, cfg) do
    topology = cfg[:topology] || local_fs_topology(cfg)

    if topology, do: Keyword.put(opts, :topology, topology), else: opts
  end

  defp local_fs_topology(cfg) do
    if cfg[:resolved_backend] == Maxio.Storage.FS do
      Maxio.Storage.FS.local_topology(cfg[:healer_opts])
    end
  end

  defp safe_run(opts) do
    _ = run_once(opts)
    :ok
  rescue
    e -> Log.error("scrubber round crashed", action: :scrubber, reason: Exception.message(e))
  catch
    kind, reason ->
      Log.error("scrubber round caught", action: :scrubber, reason: inspect({kind, reason}))
  end

  defp schedule(ms), do: Process.send_after(self(), :scrub, max(ms, 0))

  defp scan_bucket(bucket, backend, cfg) do
    {usage_counts, scan_counts, throttle} =
      if cfg[:scan_versions] do
        {scan_counts, throttle} =
          reduce_version_pages(
            bucket,
            cfg,
            {zero_counts(), cfg[:throttle]},
            &scan_object(bucket, backend, cfg, &1, &2)
          )

        {
          current_usage(bucket, cfg),
          scan_counts,
          throttle
        }
      else
        reduce_current_pages(
          bucket,
          cfg,
          {zero_usage(), zero_counts(), cfg[:throttle]},
          fn object, {usage, counts, throttle} ->
            {counts, throttle} = scan_object(bucket, backend, cfg, object, {counts, throttle})
            {add_usage(usage, object), counts, throttle}
          end
        )
      end

    Usage.put(bucket, %{
      object_count: usage_counts.object_count,
      total_size: usage_counts.total_size,
      scanned_at: DateTime.utc_now()
    })

    summary =
      zero_summary(backend)
      |> merge_counts(scan_counts)
      |> merge_usage(usage_counts)

    {summary, throttle}
  rescue
    e ->
      Log.error("scrubber bucket scan failed",
        bucket: bucket,
        action: :scrubber,
        reason: Exception.message(e)
      )

      {zero_summary(backend), Keyword.get(cfg, :throttle, Throttle.new(no_throttle: true))}
  catch
    kind, reason ->
      Log.error("scrubber bucket scan caught",
        bucket: bucket,
        action: :scrubber,
        reason: inspect({kind, reason})
      )

      {zero_summary(backend), Keyword.get(cfg, :throttle, Throttle.new(no_throttle: true))}
  end

  defp scan_object(bucket, backend, cfg, object, {counts, throttle}) do
    counts =
      case healer_for(backend) do
        :none ->
          bump(counts, :scanned)

        {healer, backend_kind} ->
          if sampled?(bucket, object, cfg) do
            set_id = scrub_set(backend_kind, bucket, object.key, cfg)
            resource = {:scrubber_set, set_id}

            case Lock.quorum_with_lock(
                   resource,
                   fn -> heal_object(healer, bucket, object, cfg, counts) end,
                   lock_opts(backend_kind, set_id, cfg)
                 ) do
              {:ok, counts} ->
                counts

              {:error, :no_quorum} ->
                Log.warn("scrubber skipped object because set lock is held",
                  bucket: bucket,
                  key: object.key,
                  action: :scrubber,
                  reason: "version_id=#{object.version_id}"
                )

                bump(counts, :skipped)
            end
          else
            bump(counts, :sampled_out)
          end
      end

    {counts, Throttle.maybe_wait(throttle)}
  end

  defp heal_object(healer, bucket, object, cfg, counts) do
    counts = bump(counts, :scanned)

    case healer.heal_object(bucket, object.key, object.version_id, cfg[:healer_opts]) do
      {:ok, %{healed: healed}} when healed > 0 ->
        counts
        |> bump(:damaged)
        |> bump(:healed)

      {:ok, _} ->
        counts

      {:error, :unrecoverable} ->
        Log.error("scrubber found unrecoverable object",
          bucket: bucket,
          key: object.key,
          action: :scrubber,
          reason: "version_id=#{object.version_id}"
        )

        counts
        |> bump(:damaged)
        |> bump(:unrecoverable)

      {:error, :enoent} ->
        Log.warn("scrubber metadata row has no storage sidecar",
          bucket: bucket,
          key: object.key,
          action: :scrubber,
          reason: "version_id=#{object.version_id}"
        )

        bump(counts, :missing)
    end
  end

  defp current_usage(bucket, cfg) do
    reduce_current_pages(bucket, cfg, zero_usage(), &add_usage(&2, &1))
  end

  defp reduce_current_pages(bucket, cfg, acc, reducer) do
    do_reduce_current(bucket, cfg, nil, acc, reducer)
  end

  defp do_reduce_current(bucket, cfg, cursor, acc, reducer) do
    page =
      Objects.list_objects_v2(bucket, %{
        max_keys: cfg[:page_size],
        continuation_token: cursor
      })

    acc = Enum.reduce(page.objects, acc, reducer)

    if page.is_truncated do
      Throttle.maybe_wait_between_batches(cfg)
      do_reduce_current(bucket, cfg, page.next_continuation_token, acc, reducer)
    else
      acc
    end
  end

  defp reduce_version_pages(bucket, cfg, acc, reducer) do
    do_reduce_versions(bucket, cfg, nil, nil, acc, reducer)
  end

  defp do_reduce_versions(bucket, cfg, key_marker, version_marker, acc, reducer) do
    page =
      Objects.list_object_versions(bucket, %{
        max_keys: cfg[:page_size],
        key_marker: key_marker,
        version_id_marker: version_marker
      })

    objects = Enum.reject(page.versions, & &1.is_delete_marker)
    acc = Enum.reduce(objects, acc, reducer)

    if page.is_truncated do
      Throttle.maybe_wait_between_batches(cfg)

      do_reduce_versions(
        bucket,
        cfg,
        page.next_key_marker,
        page.next_version_id_marker,
        acc,
        reducer
      )
    else
      acc
    end
  end

  defp bucket_names(nil), do: Buckets.list() |> Enum.map(& &1.name)

  defp bucket_names(bucket) when is_binary(bucket) do
    if Enum.any?(Buckets.list(), &(&1.name == bucket)), do: [bucket], else: []
  end

  defp healer_for(ErasureCoded), do: {LocalHeal, :erasure}
  defp healer_for(Distributed), do: {ClusterHeal, :distributed}
  defp healer_for(_backend), do: :none

  defp scrub_set(:erasure, _bucket, _key, _cfg), do: {:erasure, :local}

  defp scrub_set(:distributed, bucket, key, cfg),
    do: {:distributed, Router.set_for(bucket, key, cfg[:topology])}

  defp lock_opts(backend_kind, set_id, cfg) do
    [
      mode: :write,
      retries: 0,
      ttl_ms: cfg[:lock_ttl_ms],
      timeout: cfg[:lock_timeout_ms],
      heartbeat_ms: cfg[:lock_heartbeat_ms]
    ]
    |> Keyword.reject(fn {_key, value} -> is_nil(value) end)
    |> maybe_put_lock_nodes(lock_nodes(backend_kind, set_id, cfg))
  end

  defp maybe_put_lock_nodes(opts, nil), do: opts
  defp maybe_put_lock_nodes(opts, nodes), do: Keyword.put(opts, :nodes, nodes)

  defp lock_nodes(backend_kind, set_id, cfg) do
    case Keyword.get(cfg, :lock_nodes) do
      nodes when is_list(nodes) -> Enum.uniq(nodes)
      _ -> default_lock_nodes(backend_kind, set_id, cfg)
    end
  end

  defp default_lock_nodes(:erasure, _set_id, _cfg), do: [Node.self()]

  defp default_lock_nodes(:distributed, {:distributed, set_id}, cfg) do
    endpoints =
      case cfg[:topology] do
        nil -> Topology.endpoints(set_id)
        topology -> Topology.endpoints_from(topology, set_id)
      end

    endpoints
    |> Enum.map(fn {node, _drive} -> node end)
    |> Enum.uniq()
  end

  @doc """
  Returns whether an object should receive a deep heal check for a scrub cycle.

  Manual runs default to `sample: :full`. Periodic runs use `sample: :configured`
  plus a monotonically increasing `sample_cycle`, selecting one deterministic
  bucket/key/version partition per cycle.
  """
  @spec sampled?(String.t(), map(), keyword()) :: boolean()
  def sampled?(bucket, object, cfg) do
    inverse = Keyword.get(cfg, :sample_inverse, 1)

    cond do
      Keyword.get(cfg, :sample, :full) == :full ->
        true

      inverse <= 1 ->
        true

      true ->
        :erlang.phash2({bucket, object.key, object.version_id}, inverse) ==
          rem(cycle(cfg), inverse)
    end
  end

  defp config(opts) do
    cfg = Application.get_env(:maxio, :scrubber, [])
    drive_cfg = Application.get_env(:maxio, :drive_health, [])

    page_size =
      positive_int(Keyword.get(opts, :page_size, Keyword.get(cfg, :page_size, 500)), 500)

    [
      enabled: Keyword.get(opts, :enabled, Keyword.get(cfg, :enabled, false)),
      interval_ms: Keyword.get(opts, :interval_ms, Keyword.get(cfg, :interval_ms, 86_400_000)),
      initial_delay_ms:
        Keyword.get(opts, :initial_delay_ms, Keyword.get(cfg, :initial_delay_ms, 60_000)),
      page_size: page_size,
      scan_versions: Keyword.get(opts, :scan_versions, Keyword.get(cfg, :scan_versions, false)),
      sample: Keyword.get(opts, :sample, :full),
      sample_inverse:
        positive_int(
          Keyword.get(opts, :sample_inverse, Keyword.get(cfg, :sample_inverse, 1024)),
          1
        ),
      sample_cycle: non_negative_int(Keyword.get(opts, :sample_cycle, 0), 0),
      bucket: Keyword.get(opts, :bucket),
      backend: Keyword.get(opts, :backend),
      topology: Keyword.get(opts, :topology),
      lock_nodes: Keyword.get(opts, :lock_nodes, Keyword.get(cfg, :lock_nodes)),
      lock_ttl_ms: Keyword.get(opts, :lock_ttl_ms, Keyword.get(cfg, :lock_ttl_ms, 60_000)),
      lock_timeout_ms:
        Keyword.get(opts, :lock_timeout_ms, Keyword.get(cfg, :lock_timeout_ms, 3_000)),
      lock_heartbeat_ms:
        Keyword.get(opts, :lock_heartbeat_ms, Keyword.get(cfg, :lock_heartbeat_ms)),
      max_objects_per_sec: config_value(opts, cfg, :max_objects_per_sec, 200),
      object_burst: positive_int(config_value(opts, cfg, :object_burst, 1), 1),
      sleep_between_batches_ms: config_value(opts, cfg, :sleep_between_batches_ms, 50),
      adaptive_io: config_value(opts, cfg, :adaptive_io, true),
      max_live_requests: non_negative_int(config_value(opts, cfg, :max_live_requests, 0), 0),
      io_pause_ms: positive_int(config_value(opts, cfg, :io_pause_ms, 100), 100),
      io_max_pause_ms: non_negative_int(config_value(opts, cfg, :io_max_pause_ms, 5_000), 5_000),
      io_load_fun: Keyword.get(opts, :io_load_fun),
      io_load_source:
        Maxio.Cluster.IOPressure.normalize_source(
          config_value(opts, cfg, :io_load_source, :cluster_combined)
        ),
      throttle_sleep_fun: Keyword.get(opts, :throttle_sleep_fun),
      throttle_now_fun: Keyword.get(opts, :throttle_now_fun),
      drive_health_enabled:
        Keyword.get(
          opts,
          :drive_health_enabled,
          Keyword.get(cfg, :drive_health_enabled, Keyword.get(drive_cfg, :enabled, true))
        ),
      drive_offline_after_ms:
        non_negative_int(
          Keyword.get(
            opts,
            :drive_offline_after_ms,
            Keyword.get(
              cfg,
              :drive_offline_after_ms,
              Keyword.get(drive_cfg, :offline_after_ms, DriveHealth.default_offline_after_ms())
            )
          ),
          DriveHealth.default_offline_after_ms()
        ),
      drive_health_now_fun: Keyword.get(opts, :drive_health_now_fun),
      no_throttle: Keyword.get(opts, :no_throttle, false),
      reconcile_index:
        Keyword.get(opts, :reconcile_index, Keyword.get(cfg, :reconcile_index, false)),
      force_reconcile_index: Keyword.get(opts, :force_reconcile_index, false),
      reconcile_index_dry_run: Keyword.get(opts, :reconcile_index_dry_run, false),
      reconcile_batch_size: Keyword.get(opts, :reconcile_batch_size),
      cleanup_orphan_shards: Keyword.get(opts, :cleanup_orphan_shards, false),
      orphan_cleanup_dry_run: Keyword.get(opts, :orphan_cleanup_dry_run, false),
      orphan_cleanup_min_age_ms: Keyword.get(opts, :orphan_cleanup_min_age_ms),
      orphan_cleanup_max_deletes: Keyword.get(opts, :orphan_cleanup_max_deletes),
      authoritative_source: Keyword.get(opts, :authoritative_source),
      transport: Keyword.get(opts, :transport),
      healer_opts: healer_opts(opts)
    ]
  end

  defp backend(cfg), do: cfg[:backend] || Application.fetch_env!(:maxio, :storage_backend)

  defp healer_opts(opts) do
    opts
    |> Keyword.drop([
      :enabled,
      :interval_ms,
      :initial_delay_ms,
      :page_size,
      :scan_versions,
      :sample,
      :sample_inverse,
      :sample_cycle,
      :bucket,
      :backend,
      :lock_nodes,
      :lock_ttl_ms,
      :lock_timeout_ms,
      :lock_heartbeat_ms,
      :max_objects_per_sec,
      :object_burst,
      :sleep_between_batches_ms,
      :adaptive_io,
      :max_live_requests,
      :io_pause_ms,
      :io_max_pause_ms,
      :io_load_fun,
      :io_load_source,
      :drive_health_enabled,
      :drive_offline_after_ms,
      :drive_health_now_fun,
      :sleep_between_objects_ms,
      :throttle_sleep_fun,
      :throttle_now_fun,
      :reconcile_index,
      :force_reconcile_index,
      :reconcile_index_dry_run,
      :reconcile_batch_size,
      :cleanup_orphan_shards,
      :orphan_cleanup_dry_run,
      :orphan_cleanup_min_age_ms,
      :orphan_cleanup_max_deletes,
      :no_throttle
    ])
  end

  defp positive_int(n, _default) when is_integer(n) and n > 0, do: n
  defp positive_int(_n, default), do: default

  defp non_negative_int(n, _default) when is_integer(n) and n >= 0, do: n
  defp non_negative_int(_n, default), do: default

  defp config_value(opts, cfg, key, default) do
    case Keyword.fetch(opts, key) do
      {:ok, nil} -> Keyword.get(cfg, key, default)
      {:ok, value} -> value
      :error -> Keyword.get(cfg, key, default)
    end
  end

  defp cycle(cfg), do: Keyword.get(cfg, :sample_cycle, 0)

  defp zero_summary(backend) do
    %{
      status: :ok,
      backend: backend,
      buckets: 0,
      scanned: 0,
      damaged: 0,
      healed: 0,
      unrecoverable: 0,
      missing: 0,
      skipped: 0,
      sampled_out: 0,
      index_status: :not_run,
      index_scanned: 0,
      index_upserted: 0,
      index_gc: 0,
      index_skipped: 0,
      index_divergent: 0,
      index_orphan_shards: 0,
      index_orphan_bytes: 0,
      index_orphan_cleaned: 0,
      index_orphan_cleaned_bytes: 0,
      drive_sets: 0,
      drive_endpoints: 0,
      drive_online: 0,
      drive_suspect: 0,
      drive_offline: 0,
      drive_heal_required: 0,
      object_count: 0,
      total_size: 0
    }
  end

  defp zero_counts, do: Map.new(@count_keys, &{&1, 0})
  defp zero_usage, do: %{object_count: 0, total_size: 0}

  defp add_usage(usage, object) do
    usage
    |> Map.update!(:object_count, &(&1 + 1))
    |> Map.update!(:total_size, &(&1 + (object.size || 0)))
  end

  defp bump(counts, key), do: Map.update!(counts, key, &(&1 + 1))

  defp merge_summary(left, right) do
    left
    |> merge_counts(right)
    |> merge_usage(right)
  end

  defp merge_counts(acc, counts) do
    Enum.reduce(@count_keys, acc, fn key, summary ->
      Map.update!(summary, key, &(&1 + Map.fetch!(counts, key)))
    end)
  end

  defp merge_usage(acc, usage) do
    Enum.reduce(@usage_keys, acc, fn key, summary ->
      Map.update!(summary, key, &(&1 + Map.fetch!(usage, key)))
    end)
  end

  defp merge_index_report(summary, report) do
    %{
      summary
      | index_status: Map.fetch!(report, :status),
        index_scanned: Map.fetch!(report, :scanned),
        index_upserted: Map.fetch!(report, :upserted),
        index_gc: Map.fetch!(report, :gc),
        index_skipped: Map.fetch!(report, :skipped),
        index_divergent: Map.fetch!(report, :divergent),
        index_orphan_shards: Map.fetch!(report, :orphan_shards),
        index_orphan_bytes: Map.fetch!(report, :orphan_bytes),
        index_orphan_cleaned: Map.fetch!(report, :orphan_cleaned),
        index_orphan_cleaned_bytes: Map.fetch!(report, :orphan_cleaned_bytes)
    }
  end

  defp merge_drive_report(summary, report) do
    %{
      summary
      | drive_sets: Map.fetch!(report, :sets),
        drive_endpoints: Map.fetch!(report, :endpoints),
        drive_online: Map.fetch!(report, :online),
        drive_suspect: Map.fetch!(report, :suspect),
        drive_offline: Map.fetch!(report, :offline),
        drive_heal_required: Map.fetch!(report, :heal_required)
    }
  end

  defp zero_index_report(status) do
    %{
      status: status,
      scanned: 0,
      upserted: 0,
      gc: 0,
      skipped: 0,
      divergent: 0,
      orphan_shards: 0,
      orphan_bytes: 0,
      orphan_cleaned: 0,
      orphan_cleaned_bytes: 0
    }
  end

  defp zero_drive_report do
    %{
      sets: 0,
      endpoints: 0,
      online: 0,
      suspect: 0,
      offline: 0,
      heal_required: 0
    }
  end
end
