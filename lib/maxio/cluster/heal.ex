defmodule Maxio.Cluster.Heal do
  @moduledoc """
  跨节点纠删码自愈（M7）。检测某对象在各 {node,drive} 端点上缺失/损坏的分片（校验和不匹配/读不到，
  含宕机或被替换的节点），从 K 个存活端点（peer）RS 重建坏分片、经 Transport.heal_shard 回写 +
  修复其 sidecar 副本。坏分片数 > M（存活 < K）-> {:error, :unrecoverable} + 结构化错误日志
  （铁律 3：绝不伪造数据）。结构化日志含 bucket/key/version_id/set/endpoint/block/result（铁律 4）。

  复用 M6 heal 引擎思路（逐块重算 BLAKE3 + restore_block 重建 + split_block 重编码），
  只是分片读/回写经 Transport（本地或 peer），不重写 RS 数学。heal 粒度到整对象。
  """
  require Logger

  alias Maxio.Storage.Erasure.{Codec, Config}
  alias Maxio.Cluster.{Paths, Router, Topology, Transport}
  alias Maxio.Sidecar

  @doc """
  heal 单个对象版本：从存活端点重建各端点缺/损分片。返回 {:ok, %{healed: n}}（n=回写分片数）或
  {:error, :unrecoverable}（某 block 存活 < K）/ {:error, :enoent}（无任何 sidecar）。
  opts[:topology]/opts[:transport] 注入（同 Distributed 后端）。
  """
  @spec heal_object(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, %{healed: non_neg_integer()}} | {:error, :unrecoverable | :enoent}
  def heal_object(bucket, key, version_id \\ "null", opts \\ []) do
    case Paths.object_rel(bucket, key, version_id) do
      {:error, :invalid_key} ->
        {:error, :enoent}

      {:ok, obj_rel} ->
        c = cfg(opts)
        endpoints = endpoints_for(bucket, key, opts)
        dirs = endpoint_dirs(endpoints, obj_rel)
        tx = transport(opts)

        case read_any_sidecar(tx, dirs) do
          {:error, :enoent} -> {:error, :enoent}
          {:ok, meta} -> do_heal(c, bucket, key, version_id, tx, dirs, meta)
        end
    end
  end

  defp do_heal(cfg, bucket, key, version_id, tx, dirs, meta) do
    if delete_marker_meta?(meta, version_id) do
      healed = heal_delete_marker(bucket, key, version_id, tx, dirs, meta)
      {:ok, %{healed: healed}}
    else
      heal_erasure_object(cfg, bucket, key, version_id, tx, dirs, meta)
    end
  end

  defp heal_erasure_object(cfg, bucket, key, version_id, tx, dirs, meta) do
    n = Config.total(cfg)
    size = meta["size"]
    block_size = get_in(meta, ["ec", "block_size"]) || cfg.block_size
    shard_len = block_shard_len(meta, cfg)
    num_blocks = if size == 0, do: 0, else: div(size + block_size - 1, block_size)
    shards_meta = meta["shards"]

    # 逐 block 收集每端点需修复的分片字节：%{endpoint_index => %{block_index => shard_bytes}}。
    result =
      Enum.reduce_while(0..max(num_blocks - 1, 0), {:ok, %{}}, fn j, {:ok, fixes} ->
        if num_blocks == 0 do
          {:cont, {:ok, fixes}}
        else
          heal_block(
            cfg,
            bucket,
            key,
            version_id,
            tx,
            dirs,
            shards_meta,
            n,
            size,
            block_size,
            shard_len,
            j,
            fixes
          )
        end
      end)

    case result do
      {:error, :unrecoverable} ->
        Logger.error("cluster heal unrecoverable",
          bucket: bucket,
          key: key,
          reason: "block survivors < K"
        )

        {:error, :unrecoverable}

      {:ok, fixes} ->
        healed = apply_fixes(tx, dirs, meta, shard_len, fixes)
        {:ok, %{healed: healed}}
    end
  end

  defp heal_block(
         cfg,
         bucket,
         key,
         version_id,
         tx,
         dirs,
         shards_meta,
         n,
         size,
         block_size,
         shard_len,
         j,
         fixes
       ) do
    # 跨端点读 block j 的 N 个分片（宕机端点 -> nil）。
    read_shards =
      0..(n - 1)
      |> Enum.zip(dirs)
      |> Enum.map(fn {i, {node, dir}} ->
        drive_meta = Enum.at(shards_meta, i)

        if drive_meta && j < length(drive_meta["block_hashes"]) do
          tx.get_shard(node, dir, j, shard_len)
        else
          nil
        end
      end)

    checksums = block_checksums(shards_meta, n, j)

    bad =
      0..(n - 1)
      |> Enum.filter(fn i ->
        not Codec.verify_shard(Enum.at(read_shards, i), Enum.at(checksums, i))
      end)

    cond do
      bad == [] ->
        {:cont, {:ok, fixes}}

      length(bad) > cfg.parity_shards ->
        Logger.error("cluster heal block unrecoverable",
          bucket: bucket,
          key: key,
          reason: "block=#{j} bad=#{length(bad)} > M=#{cfg.parity_shards}"
        )

        {:halt, {:error, :unrecoverable}}

      true ->
        block_plain_len = block_plain_len(size, block_size, j)

        plain =
          Codec.restore_block(cfg, read_shards, checksums, block_plain_len,
            bucket: bucket,
            key: key,
            version_id: version_id,
            block_index: j
          )

        # 重编码须与 PUT 完全一致的固定 block_size 填充语境（保证 shard_len 与 sidecar 一致）。
        padded =
          if byte_size(plain) < block_size do
            plain <> <<0::size((block_size - byte_size(plain)) * 8)>>
          else
            plain
          end

        %{shards: good_shards} = Codec.split_block(cfg, padded)

        fixes =
          Enum.reduce(bad, fixes, fn i, acc ->
            shard = Enum.at(good_shards, i)
            ep_map = Map.get(acc, i, %{})
            Map.put(acc, i, Map.put(ep_map, j, shard))
          end)

        Logger.info("cluster heal block repaired",
          bucket: bucket,
          key: key,
          reason: "block=#{j} repaired_endpoints=#{inspect(bad)}"
        )

        {:cont, {:ok, fixes}}
    end
  end

  # 把 fixes 经 transport.heal_shard 回写到各坏端点 + 修 sidecar。返回回写分片数。
  defp apply_fixes(tx, dirs, meta, shard_len, fixes) do
    Enum.reduce(fixes, 0, fn {ep_index, block_map}, count ->
      {node, dir} = Enum.at(dirs, ep_index)
      {:ok, written} = tx.heal_shard(node, dir, block_map, shard_len, meta)
      count + written
    end)
  end

  defp heal_delete_marker(bucket, key, version_id, tx, dirs, meta) do
    Enum.reduce(dirs, 0, fn {node, dir}, healed ->
      if same_delete_marker?(tx, node, dir, meta, version_id) do
        _ = tx.delete_part_file(node, dir)
        healed
      else
        case tx.put_sidecar(node, dir, meta) do
          :ok ->
            _ = tx.delete_part_file(node, dir)
            healed + 1

          {:error, reason} ->
            Logger.warning("cluster heal delete-marker sidecar skipped",
              bucket: bucket,
              key: key,
              reason:
                "version_id=#{version_id} endpoint=#{inspect({node, dir})} reason=#{inspect(reason)}"
            )

            healed
        end
      end
    end)
  end

  defp same_delete_marker?(tx, node, dir, meta, version_id) do
    case tx.get_sidecar(node, dir) do
      {:ok, existing} -> existing == meta and delete_marker_meta?(existing, version_id)
      {:error, _} -> false
    end
  end

  defp delete_marker_meta?(%{"is_delete_marker" => true}, _version_id), do: true

  defp delete_marker_meta?(%{} = meta, version_id) do
    entry = Sidecar.find_version(meta, version_id) || Sidecar.latest(meta) || %{}
    entry["type"] == "delete_marker"
  end

  @doc """
  scrub 整桶：遍历桶内全部对象（去重存活端点副本），逐个 heal。

  对象来源经 opts[:objects]（[{key, version_id}]）显式列表（CLI 从 Maxio.Objects 元数据上下文取
  key 列表，e2e 用已知 key）。无 opts[:objects] 时回 []（文档化 defer：自动跨节点 walk 见 § M7 deferral #4）。
  """
  @spec scrub_bucket(String.t(), keyword()) ::
          {:ok,
           %{
             scanned: non_neg_integer(),
             healed_objects: non_neg_integer(),
             unrecoverable: non_neg_integer()
           }}
  def scrub_bucket(bucket, opts \\ []) do
    objects = list_objects(bucket, opts)

    {scanned, healed, unrec} =
      Enum.reduce(objects, {0, 0, 0}, fn {key, version_id}, {sc, hl, ur} ->
        case heal_object(bucket, key, version_id, opts) do
          {:ok, %{healed: n}} when n > 0 -> {sc + 1, hl + 1, ur}
          {:ok, _} -> {sc + 1, hl, ur}
          {:error, :unrecoverable} -> {sc + 1, hl, ur + 1}
          {:error, :enoent} -> {sc + 1, hl, ur}
        end
      end)

    Logger.info("cluster scrub bucket done",
      bucket: bucket,
      reason: "scanned=#{scanned} healed=#{healed} unrecoverable=#{unrec}"
    )

    {:ok, %{scanned: scanned, healed_objects: healed, unrecoverable: unrec}}
  end

  # 列桶内对象 {key, version_id}：MVP 经 opts[:objects] 显式列表（CLI 与 e2e 提供）。
  # 完整自动跨节点 walk（需 transport list_dir callback + 协调节点聚合 peer 列举 + 1/1024 采样 + 限流）
  # = 显式 defer（见 § M7 deferral #4，绝不静默假装实现）。
  defp list_objects(_bucket, opts), do: Keyword.get(opts, :objects, [])

  # ── 复用 M6 的纯辅助（与 Distributed 后端逐字一致）──

  defp topology(opts), do: Keyword.get(opts, :topology)
  defp transport(opts), do: Transport.impl(opts)

  defp cfg(opts) do
    ec =
      case topology(opts) do
        nil -> Topology.ec_params()
        t -> Topology.ec_params_from(t)
      end

    n = Keyword.fetch!(ec, :data_shards) + Keyword.fetch!(ec, :parity_shards)
    Config.load!(Keyword.put(ec, :drives, for(i <- 0..(n - 1), do: "__remote_#{i}__")))
  end

  defp endpoints_for(bucket, key, opts) do
    case topology(opts) do
      nil ->
        Topology.endpoints(Router.set_for(bucket, key, nil))

      t ->
        Topology.endpoints_from(t, Router.set_for(bucket, key, t))
    end
  end

  defp endpoint_dirs(endpoints, obj_rel),
    do: Enum.map(endpoints, fn {node, drive} -> {node, Path.join(drive, obj_rel)} end)

  defp read_any_sidecar(tx, dirs) do
    Enum.find_value(dirs, {:error, :enoent}, fn {node, dir} ->
      case tx.get_sidecar(node, dir) do
        {:ok, meta} -> {:ok, meta}
        {:error, _} -> nil
      end
    end)
  end

  defp block_checksums(shards_meta, n, j) do
    for i <- 0..(n - 1) do
      drive_meta = Enum.at(shards_meta, i)
      hex = drive_meta && Enum.at(drive_meta["block_hashes"], j)

      case hex && Base.decode16(hex, case: :lower) do
        {:ok, raw} -> raw
        _ -> <<0::256>>
      end
    end
  end

  defp block_shard_len(meta, cfg) do
    block_size = get_in(meta, ["ec", "block_size"]) || cfg.block_size

    meta["shards"]
    |> Enum.find_value(fn s ->
      bh = s["block_hashes"]

      if is_list(bh) and length(bh) > 0 and s["shard_file_size"] > 0 do
        div(s["shard_file_size"], length(bh))
      end
    end) || div(block_size + cfg.data_shards - 1, cfg.data_shards)
  end

  defp block_plain_len(size, block_size, j) do
    num_blocks = div(size + block_size - 1, block_size)

    cond do
      num_blocks == 0 -> 0
      j < num_blocks - 1 -> block_size
      true -> size - (num_blocks - 1) * block_size
    end
  end
end
