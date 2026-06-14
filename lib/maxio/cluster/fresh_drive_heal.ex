defmodule Maxio.Cluster.FreshDriveHeal do
  @moduledoc """
  Operator-triggered fresh-drive heal workflow.

  The workflow consumes node-local `DriveHealth.heal_required?` markers created
  after a long drive outage where the erasure set stayed writable. It enumerates
  PG object inventory for affected erasure sets and invokes the existing cluster
  heal engine. Markers are cleared only after a complete, unfiltered, non-dry-run
  pass with no missing, skipped, unrecoverable, or error outcomes.
  """

  alias Maxio.{Buckets, Objects}
  alias Maxio.Cluster.{DriveHealth, DriveIdentity, Heal, Lock, Router, Topology, Transport}
  alias Maxio.Cluster.Scrubber.Throttle
  alias Maxio.S3.Log
  alias Maxio.Storage.Distributed
  alias Maxio.Storage.Erasure.{Codec, Config}
  alias Maxio.Sidecar

  @counter_keys [
    :scanned,
    :healed_objects,
    :healed_shards,
    :unrecoverable,
    :missing,
    :skipped,
    :errors
  ]

  @type report :: %{
          status:
            :ok | :no_targets | :dry_run | :waiting | :partial | :partial_scope | :incomplete,
          backend: module(),
          bucket: String.t() | nil,
          scan_versions: boolean(),
          dry_run: boolean(),
          max_objects: pos_integer() | nil,
          drives_considered: non_neg_integer(),
          drives_selected: non_neg_integer(),
          drives_cleared: non_neg_integer(),
          drives_skipped_same_set: non_neg_integer(),
          drives_waiting: non_neg_integer(),
          sets: non_neg_integer(),
          buckets: non_neg_integer(),
          scanned: non_neg_integer(),
          healed_objects: non_neg_integer(),
          healed_shards: non_neg_integer(),
          unrecoverable: non_neg_integer(),
          missing: non_neg_integer(),
          skipped: non_neg_integer(),
          errors: non_neg_integer(),
          truncated: boolean()
        }

  @doc """
  Run one fresh-drive heal pass.

  Options:

    * `:bucket` - restricts scanning to one bucket. Restricted runs never clear markers.
    * `:scan_versions` - defaults to true so old versions and delete markers are healed.
    * `:max_objects` - bounds target-set objects processed. Partial runs never clear markers.
    * `:dry_run` - reports marked drives without healing or clearing.
    * `:topology` / `:transport` - test or operator overrides matching distributed storage.
  """
  @spec run_once(keyword()) :: {:ok, report()}
  def run_once(opts \\ []) do
    topology = Keyword.get(opts, :topology)
    targets = targets(topology)
    selected = selected_targets(targets)
    buckets = bucket_names(Keyword.get(opts, :bucket))
    report = zero_report(opts, targets, selected, buckets)

    report =
      cond do
        report.dry_run ->
          report

        report.drives_considered == 0 or report.drives_selected == 0 ->
          report

        true ->
          cfg = config(opts, selected)
          cfg = Keyword.put(cfg, :throttle, Throttle.new(cfg))
          {report, _throttle} = scan_buckets(buckets, cfg, report)
          report
      end

    report = maybe_clear_selected(report, selected)
    report = Map.put(report, :status, status_for(report))

    Log.info("fresh-drive heal pass complete",
      action: :fresh_drive_heal,
      reason:
        "status=#{report.status} drives_considered=#{report.drives_considered} " <>
          "drives_selected=#{report.drives_selected} drives_cleared=#{report.drives_cleared} " <>
          "drives_skipped_same_set=#{report.drives_skipped_same_set} " <>
          "drives_waiting=#{report.drives_waiting} sets=#{report.sets} buckets=#{report.buckets} " <>
          "scanned=#{report.scanned} healed_objects=#{report.healed_objects} " <>
          "healed_shards=#{report.healed_shards} unrecoverable=#{report.unrecoverable} " <>
          "missing=#{report.missing} skipped=#{report.skipped} errors=#{report.errors} " <>
          "truncated=#{report.truncated}"
    )

    {:ok, report}
  end

  defp targets(topology) do
    DriveHealth.snapshot()
    |> Enum.filter(&Map.fetch!(&1, :heal_required?))
    |> Enum.map(&with_set_id(&1, topology))
  end

  defp with_set_id(%{set_id: nil} = status, topology),
    do: %{status | set_id: set_for_endpoint(status.endpoint, topology)}

  defp with_set_id(status, _topology), do: status

  defp selected_targets(targets) do
    targets
    |> Enum.filter(&(&1.status == :online and not is_nil(&1.set_id)))
    |> Enum.group_by(& &1.set_id)
    |> Enum.map(fn {_set_id, statuses} ->
      statuses
      |> Enum.sort_by(fn %{endpoint: {node, drive}} -> {inspect(node), drive} end)
      |> List.first()
    end)
  end

  defp zero_report(opts, targets, selected, buckets) do
    online_targets = Enum.count(targets, &(&1.status == :online and not is_nil(&1.set_id)))
    target_sets = selected |> Enum.map(& &1.set_id) |> MapSet.new()

    %{
      status: :ok,
      backend: Distributed,
      bucket: Keyword.get(opts, :bucket),
      scan_versions: Keyword.get(opts, :scan_versions, true),
      dry_run: Keyword.get(opts, :dry_run, false),
      max_objects: positive_int_or_nil(Keyword.get(opts, :max_objects)),
      drives_considered: length(targets),
      drives_selected: length(selected),
      drives_cleared: 0,
      drives_skipped_same_set: max(online_targets - length(selected), 0),
      drives_waiting: max(length(targets) - online_targets, 0),
      sets: MapSet.size(target_sets),
      buckets: length(buckets),
      scanned: 0,
      healed_objects: 0,
      healed_shards: 0,
      unrecoverable: 0,
      missing: 0,
      skipped: 0,
      errors: 0,
      truncated: false
    }
  end

  defp config(opts, selected) do
    [
      topology: Keyword.get(opts, :topology),
      transport: Keyword.get(opts, :transport) || Transport.impl(opts),
      scan_versions: Keyword.get(opts, :scan_versions, true),
      page_size: positive_int(Keyword.get(opts, :page_size), 500),
      max_objects: positive_int_or_nil(Keyword.get(opts, :max_objects)),
      target_sets: selected |> Enum.map(& &1.set_id) |> MapSet.new(),
      selected_by_set: Map.new(selected, &{&1.set_id, &1.endpoint}),
      lock_nodes: Keyword.get(opts, :lock_nodes),
      lock_ttl_ms: Keyword.get(opts, :lock_ttl_ms, 60_000),
      lock_timeout_ms: Keyword.get(opts, :lock_timeout_ms, 3_000),
      lock_heartbeat_ms: Keyword.get(opts, :lock_heartbeat_ms),
      max_objects_per_sec: config_value(opts, :max_objects_per_sec, 200),
      object_burst: positive_int(config_value(opts, :object_burst, 1), 1),
      sleep_between_batches_ms: config_value(opts, :sleep_between_batches_ms, 50),
      adaptive_io: config_value(opts, :adaptive_io, true),
      max_live_requests: non_negative_int(config_value(opts, :max_live_requests, 0), 0),
      io_pause_ms: positive_int(config_value(opts, :io_pause_ms, 100), 100),
      io_max_pause_ms: non_negative_int(config_value(opts, :io_max_pause_ms, 5_000), 5_000),
      io_load_fun: Keyword.get(opts, :io_load_fun),
      io_load_source:
        Maxio.Cluster.IOPressure.normalize_source(
          config_value(opts, :io_load_source, :cluster_combined)
        ),
      throttle_sleep_fun: Keyword.get(opts, :throttle_sleep_fun),
      throttle_now_fun: Keyword.get(opts, :throttle_now_fun),
      no_throttle: Keyword.get(opts, :no_throttle, false),
      ec_config: erasure_config(Keyword.get(opts, :topology)),
      healer_opts:
        [
          topology: Keyword.get(opts, :topology),
          transport: Keyword.get(opts, :transport)
        ]
        |> Keyword.reject(fn {_key, value} -> is_nil(value) end)
    ]
  end

  defp scan_buckets(buckets, cfg, report) do
    Enum.reduce_while(buckets, {report, cfg[:throttle]}, fn bucket, {acc, throttle} ->
      {acc, throttle} = scan_bucket(bucket, Keyword.put(cfg, :throttle, throttle), acc)
      if acc.truncated, do: {:halt, {acc, throttle}}, else: {:cont, {acc, throttle}}
    end)
  end

  defp scan_bucket(bucket, cfg, report) do
    if cfg[:scan_versions] do
      reduce_version_pages(bucket, cfg, report, nil, nil)
    else
      reduce_current_pages(bucket, cfg, report, nil)
    end
  rescue
    e ->
      Log.error("fresh-drive heal bucket scan crashed",
        bucket: bucket,
        action: :fresh_drive_heal,
        reason: Exception.message(e)
      )

      {bump(report, :errors), cfg[:throttle]}
  catch
    kind, reason ->
      Log.error("fresh-drive heal bucket scan caught",
        bucket: bucket,
        action: :fresh_drive_heal,
        reason: inspect({kind, reason})
      )

      {bump(report, :errors), cfg[:throttle]}
  end

  defp reduce_current_pages(bucket, cfg, report, cursor) do
    page =
      Objects.list_objects_v2(bucket, %{
        max_keys: cfg[:page_size],
        continuation_token: cursor
      })

    {report, throttle} = reduce_objects(bucket, cfg, report, page.objects)
    cfg = Keyword.put(cfg, :throttle, throttle)

    cond do
      report.truncated ->
        {report, throttle}

      page.is_truncated and cap_reached?(report, cfg) ->
        {%{report | truncated: true}, throttle}

      page.is_truncated ->
        Throttle.maybe_wait_between_batches(cfg)
        reduce_current_pages(bucket, cfg, report, page.next_continuation_token)

      true ->
        {report, throttle}
    end
  end

  defp reduce_version_pages(bucket, cfg, report, key_marker, version_marker) do
    page =
      Objects.list_object_versions(bucket, %{
        max_keys: cfg[:page_size],
        key_marker: key_marker,
        version_id_marker: version_marker
      })

    {report, throttle} = reduce_objects(bucket, cfg, report, page.versions)
    cfg = Keyword.put(cfg, :throttle, throttle)

    cond do
      report.truncated ->
        {report, throttle}

      page.is_truncated and cap_reached?(report, cfg) ->
        {%{report | truncated: true}, throttle}

      page.is_truncated ->
        Throttle.maybe_wait_between_batches(cfg)

        reduce_version_pages(
          bucket,
          cfg,
          report,
          page.next_key_marker,
          page.next_version_id_marker
        )

      true ->
        {report, throttle}
    end
  end

  defp reduce_objects(bucket, cfg, report, objects) do
    Enum.reduce_while(objects, {report, cfg[:throttle]}, fn object, {acc, throttle} ->
      {acc, throttle} =
        maybe_scan_object(bucket, Keyword.put(cfg, :throttle, throttle), acc, object)

      if acc.truncated, do: {:halt, {acc, throttle}}, else: {:cont, {acc, throttle}}
    end)
  end

  defp maybe_scan_object(bucket, cfg, report, object) do
    set_id = object_set_id(bucket, object, cfg)

    cond do
      not MapSet.member?(cfg[:target_sets], set_id) ->
        {report, cfg[:throttle]}

      cap_reached?(report, cfg) ->
        {%{report | truncated: true}, cfg[:throttle]}

      true ->
        report = scan_object(bucket, cfg, report, object, set_id)
        {report, Throttle.maybe_wait(cfg[:throttle])}
    end
  end

  defp scan_object(bucket, cfg, report, object, set_id) do
    resource = {:scrubber_set, {:distributed, set_id}}
    report = bump(report, :scanned)
    healer_opts = Keyword.put(cfg[:healer_opts], :placement_set_id, set_id)

    case Lock.quorum_with_lock(
           resource,
           fn -> Heal.heal_object(bucket, object.key, object.version_id, healer_opts) end,
           lock_opts(set_id, cfg)
         ) do
      {:ok, {:ok, %{healed: healed}}} when healed > 0 ->
        case verify_target_endpoint(bucket, object, set_id, cfg) do
          :ok ->
            report
            |> bump(:healed_objects)
            |> add(:healed_shards, healed)

          {:error, reason} ->
            Log.error("fresh-drive heal target endpoint verification failed",
              bucket: bucket,
              key: object.key,
              action: :fresh_drive_heal,
              reason:
                "version_id=#{object.version_id} set_id=#{inspect(set_id)} #{inspect(reason)}"
            )

            bump(report, :errors)
        end

      {:ok, {:ok, _}} ->
        case verify_target_endpoint(bucket, object, set_id, cfg) do
          :ok ->
            report

          {:error, reason} ->
            Log.error("fresh-drive heal target endpoint verification failed",
              bucket: bucket,
              key: object.key,
              action: :fresh_drive_heal,
              reason:
                "version_id=#{object.version_id} set_id=#{inspect(set_id)} #{inspect(reason)}"
            )

            bump(report, :errors)
        end

      {:ok, {:error, :unrecoverable}} ->
        Log.error("fresh-drive heal found unrecoverable object",
          bucket: bucket,
          key: object.key,
          action: :fresh_drive_heal,
          reason: "version_id=#{object.version_id}"
        )

        bump(report, :unrecoverable)

      {:ok, {:error, :enoent}} ->
        Log.warn("fresh-drive heal metadata row has no storage sidecar",
          bucket: bucket,
          key: object.key,
          action: :fresh_drive_heal,
          reason: "version_id=#{object.version_id}"
        )

        bump(report, :missing)

      {:error, :no_quorum} ->
        Log.warn("fresh-drive heal skipped object because set lock is held",
          bucket: bucket,
          key: object.key,
          action: :fresh_drive_heal,
          reason: "version_id=#{object.version_id} set_id=#{inspect(set_id)}"
        )

        bump(report, :skipped)

      other ->
        Log.error("fresh-drive heal object failed",
          bucket: bucket,
          key: object.key,
          action: :fresh_drive_heal,
          reason: "version_id=#{object.version_id} result=#{inspect(other)}"
        )

        bump(report, :errors)
    end
  rescue
    e ->
      Log.error("fresh-drive heal object crashed",
        bucket: bucket,
        key: object.key,
        action: :fresh_drive_heal,
        reason: Exception.message(e)
      )

      bump(report, :errors)
  catch
    kind, reason ->
      Log.error("fresh-drive heal object caught",
        bucket: bucket,
        key: object.key,
        action: :fresh_drive_heal,
        reason: inspect({kind, reason})
      )

      bump(report, :errors)
  end

  defp maybe_clear_selected(report, selected) do
    if status_for(report) == :ok do
      Enum.reduce(selected, report, fn target, acc ->
        case clear_heal_required(target.endpoint) do
          :ok ->
            %{acc | drives_cleared: acc.drives_cleared + 1}

          {:error, reason} ->
            log_identity_clear_error(target.endpoint, reason)
            bump(acc, :errors)
        end
      end)
    else
      report
    end
  end

  defp clear_heal_required(endpoint) do
    case DriveIdentity.clear_heal_required(endpoint) do
      {:ok, _status} ->
        _ = DriveHealth.clear_heal_required(endpoint)
        :ok

      {:error, :not_found} ->
        _ = DriveHealth.clear_heal_required(endpoint)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp log_identity_clear_error({node, drive}, reason) do
    Log.error("fresh-drive heal identity marker clear failed",
      action: :fresh_drive_heal,
      reason: "node=#{inspect(node)} drive=#{drive} reason=#{inspect(reason)}"
    )

    :ok
  end

  defp status_for(report) do
    cond do
      report.drives_considered == 0 -> :no_targets
      report.dry_run -> :dry_run
      report.drives_selected == 0 -> :waiting
      report.truncated -> :partial
      not report.scan_versions -> :partial_scope
      not is_nil(report.bucket) -> :partial_scope
      clean?(report) -> :ok
      true -> :incomplete
    end
  end

  defp clean?(report) do
    report.unrecoverable == 0 and report.missing == 0 and report.skipped == 0 and
      report.errors == 0
  end

  defp cap_reached?(report, cfg) do
    is_integer(cfg[:max_objects]) and report.scanned >= cfg[:max_objects]
  end

  defp object_set_id(_bucket, %{placement_set_id: set_id}, _cfg) when is_integer(set_id),
    do: set_id

  defp object_set_id(bucket, object, cfg), do: Router.set_for(bucket, object.key, cfg[:topology])

  defp bucket_names(nil), do: Buckets.list() |> Enum.map(& &1.name)

  defp bucket_names(bucket) when is_binary(bucket) do
    if Enum.any?(Buckets.list(), &(&1.name == bucket)), do: [bucket], else: []
  end

  defp set_for_endpoint(endpoint, topology) do
    view = topology_view(topology)

    view
    |> all_set_ids()
    |> Enum.find(fn set_id ->
      view
      |> endpoints(set_id)
      |> Enum.any?(&(normalize_endpoint(&1) == normalize_endpoint(endpoint)))
    end)
  end

  defp topology_view(nil),
    do: if(Topology.configured?(), do: {:configured, nil}, else: :no_topology)

  defp topology_view(topology), do: {:injected, topology}

  defp all_set_ids(:no_topology), do: []
  defp all_set_ids({:configured, nil}), do: Topology.all_set_ids()
  defp all_set_ids({:injected, topology}), do: Topology.all_set_ids_from(topology)

  defp endpoints(:no_topology, _set_id), do: []
  defp endpoints({:configured, nil}, set_id), do: Topology.endpoints(set_id)
  defp endpoints({:injected, topology}, set_id), do: Topology.endpoints_from(topology, set_id)

  defp normalize_endpoint({node, drive}), do: {node, Path.expand(drive)}

  defp verify_target_endpoint(bucket, object, set_id, cfg) do
    with {:ok, endpoint} <- selected_endpoint(set_id, cfg),
         {:ok, dir} <- endpoint_object_dir(bucket, object, endpoint),
         {:ok, meta} <- cfg[:transport].get_sidecar(elem(endpoint, 0), dir) do
      if delete_marker_meta?(meta, object.version_id) do
        verify_delete_marker_target(cfg[:transport], endpoint, dir)
      else
        verify_object_target(bucket, object, set_id, endpoint, dir, meta, cfg)
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp selected_endpoint(set_id, cfg) do
    case Map.fetch(cfg[:selected_by_set], set_id) do
      {:ok, endpoint} -> {:ok, endpoint}
      :error -> {:error, {:missing_selected_endpoint, set_id}}
    end
  end

  defp endpoint_object_dir(bucket, object, {_node, drive}) do
    case Maxio.Cluster.Paths.object_rel(bucket, object.key, object.version_id) do
      {:ok, rel} -> {:ok, Path.join(drive, rel)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp verify_delete_marker_target(transport, {node, _drive}, dir) do
    case transport.stat_shard(node, dir) do
      {:error, :enoent} -> :ok
      {:ok, _size} -> {:error, :delete_marker_part_left_behind}
      {:error, reason} -> {:error, reason}
    end
  end

  defp verify_object_target(bucket, object, set_id, endpoint, dir, meta, cfg) do
    with {:ok, endpoint_index} <- endpoint_index(set_id, endpoint, cfg),
         :ok <- verify_object_blocks(bucket, object, endpoint, dir, meta, endpoint_index, cfg) do
      :ok
    end
  end

  defp endpoint_index(set_id, endpoint, cfg) do
    cfg[:topology]
    |> topology_view()
    |> endpoints(set_id)
    |> Enum.find_index(&(normalize_endpoint(&1) == normalize_endpoint(endpoint)))
    |> case do
      nil -> {:error, {:endpoint_not_in_set, set_id, endpoint}}
      index -> {:ok, index}
    end
  end

  defp verify_object_blocks(bucket, object, {node, _drive}, dir, meta, endpoint_index, cfg) do
    case meta["size"] do
      0 ->
        :ok

      size when is_integer(size) and size > 0 ->
        verify_nonempty_object_blocks(bucket, object, {node, nil}, dir, meta, endpoint_index, cfg)

      _ ->
        {:error, :invalid_size}
    end
  end

  defp verify_nonempty_object_blocks(
         bucket,
         object,
         {node, _drive},
         dir,
         meta,
         endpoint_index,
         cfg
       ) do
    with {:ok, drive_meta} <- drive_meta(meta, endpoint_index) do
      size = meta["size"]
      block_size = get_in(meta, ["ec", "block_size"]) || cfg[:ec_config].block_size
      shard_len = block_shard_len(meta, cfg[:ec_config])
      num_blocks = div(size + block_size - 1, block_size)

      Enum.reduce_while(0..(num_blocks - 1), :ok, fn block_index, :ok ->
        checksum = block_checksum(drive_meta, block_index)
        shard = cfg[:transport].get_shard(node, dir, block_index, shard_len)

        if Codec.verify_shard(shard, checksum) do
          {:cont, :ok}
        else
          Log.error("fresh-drive heal target shard verification failed",
            bucket: bucket,
            key: object.key,
            action: :fresh_drive_heal,
            reason: "version_id=#{object.version_id} block=#{block_index}"
          )

          {:halt, {:error, {:invalid_target_shard, block_index}}}
        end
      end)
    end
  end

  defp drive_meta(meta, endpoint_index) do
    case meta["shards"] do
      shards when is_list(shards) ->
        case Enum.at(shards, endpoint_index) do
          nil -> {:error, {:missing_drive_meta, endpoint_index}}
          drive_meta -> {:ok, drive_meta}
        end

      _ ->
        {:error, :missing_shards_meta}
    end
  end

  defp block_checksum(drive_meta, block_index) do
    hex =
      drive_meta
      |> Map.get("block_hashes", [])
      |> Enum.at(block_index)

    case if(is_binary(hex), do: Base.decode16(hex, case: :lower), else: :error) do
      {:ok, raw} -> raw
      _ -> <<0::256>>
    end
  end

  defp block_shard_len(meta, ec_config) do
    block_size = get_in(meta, ["ec", "block_size"]) || ec_config.block_size

    meta["shards"]
    |> Enum.find_value(fn shard_meta ->
      block_hashes = shard_meta["block_hashes"]

      if is_list(block_hashes) and length(block_hashes) > 0 and shard_meta["shard_file_size"] > 0 do
        div(shard_meta["shard_file_size"], length(block_hashes))
      end
    end) || div(block_size + ec_config.data_shards - 1, ec_config.data_shards)
  end

  defp delete_marker_meta?(%{"is_delete_marker" => true}, _version_id), do: true

  defp delete_marker_meta?(%{} = meta, version_id) do
    entry = Sidecar.find_version(meta, version_id) || Sidecar.latest(meta) || %{}
    entry["type"] == "delete_marker"
  end

  defp erasure_config(topology) do
    ec =
      case topology do
        nil -> Topology.ec_params()
        topology -> Topology.ec_params_from(topology)
      end

    total = Keyword.fetch!(ec, :data_shards) + Keyword.fetch!(ec, :parity_shards)

    Config.load!(
      Keyword.put(ec, :drives, for(index <- 0..(total - 1), do: "__remote_#{index}__"))
    )
  end

  defp lock_opts(set_id, cfg) do
    [
      mode: :write,
      retries: 0,
      ttl_ms: cfg[:lock_ttl_ms],
      timeout: cfg[:lock_timeout_ms],
      heartbeat_ms: cfg[:lock_heartbeat_ms]
    ]
    |> Keyword.reject(fn {_key, value} -> is_nil(value) end)
    |> maybe_put_lock_nodes(lock_nodes(set_id, cfg))
  end

  defp maybe_put_lock_nodes(opts, nil), do: opts
  defp maybe_put_lock_nodes(opts, nodes), do: Keyword.put(opts, :nodes, nodes)

  defp lock_nodes(set_id, cfg) do
    case cfg[:lock_nodes] do
      nodes when is_list(nodes) ->
        Enum.uniq(nodes)

      _ ->
        cfg[:topology]
        |> topology_view()
        |> endpoints(set_id)
        |> Enum.map(fn {node, _drive} -> node end)
        |> Enum.uniq()
    end
  end

  defp bump(report, key) when key in @counter_keys, do: Map.update!(report, key, &(&1 + 1))
  defp add(report, key, n) when key in @counter_keys, do: Map.update!(report, key, &(&1 + n))

  defp positive_int(n, _default) when is_integer(n) and n > 0, do: n
  defp positive_int(_n, default), do: default

  defp non_negative_int(n, _default) when is_integer(n) and n >= 0, do: n
  defp non_negative_int(_n, default), do: default

  defp positive_int_or_nil(n) when is_integer(n) and n > 0, do: n
  defp positive_int_or_nil(_n), do: nil

  defp config_value(opts, key, default) do
    case Keyword.fetch(opts, key) do
      {:ok, nil} -> default
      {:ok, value} -> value
      :error -> default
    end
  end
end
