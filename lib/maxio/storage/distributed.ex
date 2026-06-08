defmodule Maxio.Storage.Distributed do
  @moduledoc """
  多节点分布式 Reed-Solomon 纠删码存储后端（M7），实现 Maxio.Storage.Backend 契约，与 FS/ErasureCoded
  返回形态逐字节一致（铁律 2：后端即插件，核心管线一行不改）。

  在 M6 单机纠删码核心（Maxio.Storage.Erasure.{Codec,Config,Meta} + NIF）之外加：
    * Router.set_for(bucket,key) -> set_id（对象名哈希取模，铁律 5 对齐 MinIO；版本不入哈希）
    * Topology.endpoints(set_id) -> 有序 N 个 {node, drive} 端点（索引 i = 分片 i）
    * Transport（:erpc / InProcess）把分片 i 寻址到端点 i 的节点 + drive（铁律 4 逐 block-shard）
  RS 数学/流式/quorum/校验 全部复用 M6，一行不重写——只把「分片 i 写本地盘 i」换成
  「分片 i 经 Transport 写端点 i」。

  put：逐块流式编码（Codec.split_block），分片 i 写端点 i，成功端点数 >= write_quorum 才 {:ok}，
       否则 {:error,:write_quorum}（铁律 3）；PUT 用 Maxio.Cluster.Lock.with_lock 守护并发（绝不撕裂对象）。
  get：逐块跨节点并行读 K-of-N 分片（宕机/超时端点 -> nil），按 sidecar BLAKE3 校验 + Codec.restore_block
       重建（存活 < K -> raise InsufficientShardsError，绝不静默返回错数据，铁律 3）+ 截断 + Range 裁剪，流式发出。

  每 callback 末参 opts：opts[:topology]（parsed struct）覆盖 :persistent_term；
  opts[:transport] 覆盖 config :maxio, :shard_transport。便于 ExUnit 注入进程内多节点 transport。
  """
  @behaviour Maxio.Storage.Backend

  require Logger

  alias Maxio.Storage.Erasure.{Codec, Config}
  alias Maxio.Cluster.{Lock, Paths, Router, Topology, Transport}

  # ── Backend callbacks（签名与 FS/ErasureCoded 一致）──

  @impl true
  def put(bucket, key, version_id \\ "null", chunks, opts \\ [])

  def put(bucket, key, version_id, chunks, opts),
    do: do_put(bucket, key, version_id, chunks, opts)

  @impl true
  def get(bucket, key, version_id \\ "null", range \\ nil, opts \\ []),
    do: do_get(bucket, key, version_id, range, opts)

  @impl true
  def stat(bucket, key, version_id \\ "null", opts \\ []),
    do: do_stat(bucket, key, version_id, opts)

  @impl true
  def delete(bucket, key, version_id \\ "null", opts \\ []),
    do: do_delete(bucket, key, version_id, opts)

  @impl true
  def put_bucket(bucket, opts \\ []), do: do_put_bucket(bucket, opts)

  @impl true
  def delete_bucket(bucket, opts \\ []), do: do_delete_bucket(bucket, opts)

  @impl true
  def put_part(bucket, key, upload_id, part_number, chunks, opts \\ []),
    do: do_put_part(bucket, key, upload_id, part_number, chunks, opts)

  @impl true
  def get_part_stream(bucket, key, upload_id, part_number, opts \\ []),
    do: do_get_part_stream(bucket, key, upload_id, part_number, opts)

  @impl true
  def assemble(bucket, key, upload_id, part_numbers, opts \\ []),
    do: do_assemble(bucket, key, upload_id, part_numbers, opts)

  @impl true
  def abort_upload(bucket, key, upload_id, opts \\ []),
    do: do_abort_upload(bucket, key, upload_id, opts)

  # ── 端点解析（对象 -> set -> [{node, drive}]）──

  defp topology(opts), do: Keyword.get(opts, :topology)

  defp cfg(opts), do: Config.load!(ec_params(opts))

  defp ec_params(opts) do
    case topology(opts) do
      nil -> Topology.ec_params()
      t -> Topology.ec_params_from(t)
    end
    # Config.load!/1 需 drives 非空校验；分布式不用 cfg.drives，但 Config 校验要求其存在。
    # 注入一个长度 N 的占位 drives（仅满足 length==K+M 校验，绝不用于 IO）。
    |> with_placeholder_drives()
  end

  defp with_placeholder_drives(ec_kw) do
    n = Keyword.fetch!(ec_kw, :data_shards) + Keyword.fetch!(ec_kw, :parity_shards)
    Keyword.put(ec_kw, :drives, for(i <- 0..(n - 1), do: "__remote_#{i}__"))
  end

  defp endpoints_for(bucket, key, opts) do
    case topology(opts) do
      nil ->
        set_id = Router.set_for(bucket, key, nil)
        Topology.endpoints(set_id)

      t ->
        set_id = Router.set_for(bucket, key, t)
        Topology.endpoints_from(t, set_id)
    end
  end

  # part 的端点：以 upload_id 作 key 路由（同 upload 全 part + assemble 同 set）。
  defp endpoints_for_upload(bucket, upload_id, opts),
    do: endpoints_for(bucket, ".uploads/" <> upload_id, opts)

  defp transport(opts), do: Transport.impl(opts)

  # 端点 i 的「该对象在该 drive 下的目录」= Path.join(drive_i, obj_rel)。
  defp endpoint_dirs(endpoints, obj_rel),
    do: Enum.map(endpoints, fn {node, drive} -> {node, Path.join(drive, obj_rel)} end)

  # ── PUT（逐块流式编码；分片 i -> 端点 i；with_lock 守护）──

  defp do_put(bucket, key, version_id, chunks, opts) do
    case Paths.object_rel(bucket, key, version_id) do
      {:error, :invalid_key} ->
        {:error, :invalid_key}

      {:ok, obj_rel} ->
        case Lock.with_lock({bucket, key}, fn ->
               put_locked(bucket, key, obj_rel, chunks, opts)
             end) do
          {:ok, result} -> result
          {:error, :locked} -> {:error, :locked}
        end
    end
  end

  defp put_locked(bucket, key, obj_rel, chunks, opts) do
    c = cfg(opts)
    endpoints = endpoints_for(bucket, key, opts)
    dirs = endpoint_dirs(endpoints, obj_rel)
    tx = transport(opts)
    n = Config.total(c)

    acc0 = %{
      md5: :crypto.hash_init(:md5),
      sha: :crypto.hash_init(:sha256),
      size: 0,
      shard_len: nil,
      block_hashes: List.duplicate([], n),
      buffer: <<>>,
      block_index: 0,
      dirs: dirs,
      tx: tx
    }

    acc = Enum.reduce(chunks, acc0, fn chunk, acc -> feed(c, acc, chunk) end)
    acc = flush_final(c, acc)

    etag = acc.md5 |> :crypto.hash_final() |> Base.encode16(case: :lower)
    sha256 = acc.sha |> :crypto.hash_final() |> Base.encode16(case: :lower)
    shard_len = acc.shard_len || 0

    meta =
      build_meta(
        c,
        acc.size,
        etag,
        sha256,
        shard_len,
        Enum.map(acc.block_hashes, &Enum.reverse/1)
      )

    ok_endpoints = write_sidecars(tx, dirs, meta)

    if ok_endpoints >= c.write_quorum do
      {:ok, %{size: acc.size, etag: etag, sha256: sha256}}
    else
      Logger.error("distributed put below write quorum",
        bucket: bucket,
        key: key,
        reason: "ok_endpoints=#{ok_endpoints} < write_quorum=#{c.write_quorum}"
      )

      {:error, :write_quorum}
    end
  end

  defp feed(cfg, acc, chunk) do
    acc = %{
      acc
      | md5: :crypto.hash_update(acc.md5, chunk),
        sha: :crypto.hash_update(acc.sha, chunk),
        size: acc.size + byte_size(chunk),
        buffer: acc.buffer <> chunk
    }

    drain_full_blocks(cfg, acc)
  end

  defp drain_full_blocks(cfg, %{buffer: buffer} = acc) when byte_size(buffer) >= cfg.block_size do
    block_size = cfg.block_size
    <<block::binary-size(^block_size), rest::binary>> = buffer
    acc = write_block(cfg, %{acc | buffer: rest}, block)
    drain_full_blocks(cfg, acc)
  end

  defp drain_full_blocks(_cfg, acc), do: acc

  defp flush_final(_cfg, %{buffer: <<>>} = acc), do: acc

  defp flush_final(cfg, %{buffer: buffer} = acc),
    do: write_block(cfg, %{acc | buffer: <<>>}, buffer)

  # 编码一个 block：N 分片经 transport 写各端点；校验和按端点累积（与 M6 write_block 逐字一致，
  # 仅落盘换成 transport.put_shard）。块零填充到 block_size 保证全对象 shard_len 一致（M6 不变量）。
  defp write_block(cfg, acc, block) do
    padded =
      if byte_size(block) < cfg.block_size do
        block <> <<0::size((cfg.block_size - byte_size(block)) * 8)>>
      else
        block
      end

    %{shards: shards, checksums: checksums, shard_len: shard_len} = Codec.split_block(cfg, padded)

    _ok = write_block_shards(acc.tx, acc.dirs, acc.block_index, shards, shard_len)

    block_hashes =
      acc.block_hashes
      |> Enum.zip(checksums)
      |> Enum.map(fn {acc_list, ck} -> [Base.encode16(ck, case: :lower) | acc_list] end)

    %{acc | shard_len: shard_len, block_index: acc.block_index + 1, block_hashes: block_hashes}
  end

  # 写 block j 的 N 个分片到 N 个端点（并行，铁律 4 一条消息一个分片）；返回成功端点数。
  defp write_block_shards(tx, dirs, j, shards, shard_len) do
    dirs
    |> Enum.zip(shards)
    |> Task.async_stream(
      fn {{node, dir}, shard} ->
        case tx.put_shard(node, dir, j, shard, shard_len) do
          :ok -> :ok
          _ -> :error
        end
      end,
      timeout: :infinity,
      max_concurrency: length(dirs)
    )
    |> Enum.count(fn
      {:ok, :ok} -> true
      _ -> false
    end)
  end

  defp build_meta(cfg, size, etag, sha256, shard_len, block_hashes_per_drive) do
    n = Config.total(cfg)

    shards =
      for i <- 0..(n - 1) do
        hashes = Enum.at(block_hashes_per_drive, i)
        %{"drive" => i, "shard_file_size" => length(hashes) * shard_len, "block_hashes" => hashes}
      end

    %{
      "ec" => %{
        "k" => cfg.data_shards,
        "m" => cfg.parity_shards,
        "block_size" => cfg.block_size,
        "algo" => "blake3-256"
      },
      "size" => size,
      "etag" => etag,
      "sha256" => sha256,
      "parts" => [%{"part" => 0, "size" => size}],
      "shards" => shards
    }
  end

  # sidecar 写全部 N 端点（并行），返回成功端点数（write quorum 判定）。
  defp write_sidecars(tx, dirs, meta) do
    dirs
    |> Task.async_stream(
      fn {node, dir} ->
        case tx.put_sidecar(node, dir, meta) do
          :ok -> :ok
          _ -> :error
        end
      end,
      timeout: :infinity,
      max_concurrency: length(dirs)
    )
    |> Enum.count(fn
      {:ok, :ok} -> true
      _ -> false
    end)
  end

  # ── GET（逐块跨节点并行读 K-of-N；校验 + 重建；Range 裁剪；流式）──

  defp do_get(bucket, key, version_id, range, opts) do
    case Paths.object_rel(bucket, key, version_id) do
      {:error, :invalid_key} ->
        {:error, :invalid_key}

      {:ok, obj_rel} ->
        c = cfg(opts)
        endpoints = endpoints_for(bucket, key, opts)
        dirs = endpoint_dirs(endpoints, obj_rel)
        tx = transport(opts)

        case read_any_sidecar(tx, dirs) do
          {:ok, meta} ->
            size = meta["size"]
            block_size = get_in(meta, ["ec", "block_size"])
            {first, last} = normalize_range(range, size)

            if size == 0 or last < first do
              {:ok, []}
            else
              {:ok,
               stream_object(c, bucket, key, version_id, tx, dirs, meta, block_size, first, last)}
            end

          {:error, :enoent} ->
            {:error, :enoent}
        end
    end
  end

  defp normalize_range(nil, size), do: {0, max(size - 1, 0)}
  defp normalize_range({first, last}, _size), do: {first, last}

  # 逐 block 跨节点并行读 K 存活分片、校验+重建、裁剪到 [first,last]，发出。
  # 控制流与 M6 stream_object/8 逐字一致；仅 read_shard 换成 read_block_shards（transport）。
  defp stream_object(cfg, bucket, key, version_id, tx, dirs, meta, block_size, first, last) do
    n = Config.total(cfg)
    shards_meta = meta["shards"]
    size = meta["size"]
    shard_len = block_shard_len(meta, cfg)
    first_block = div(first, block_size)
    last_block = div(last, block_size)

    Stream.resource(
      fn -> first_block end,
      fn
        j when j > last_block ->
          {:halt, j}

        j ->
          block_plain_len = block_plain_len(size, block_size, j)
          shards = read_block_shards(tx, dirs, shards_meta, j, shard_len, n)
          checksums = block_checksums(shards_meta, n, j)

          plain =
            Codec.restore_block(cfg, shards, checksums, block_plain_len,
              bucket: bucket,
              key: key,
              version_id: version_id,
              block_index: j
            )

          block_start = j * block_size
          lo = max(first, block_start) - block_start
          hi = min(last, block_start + block_plain_len - 1) - block_start
          out = binary_part(plain, lo, hi - lo + 1)
          {[out], j + 1}
      end,
      fn _j -> :ok end
    )
  end

  # 读 block j 的 N 个分片（跨节点并行；宕机/超时端点 -> nil）。保序（索引 i = 分片 i）。
  defp read_block_shards(tx, dirs, shards_meta, j, shard_len, n) do
    0..(n - 1)
    |> Enum.zip(dirs)
    |> Task.async_stream(
      fn {i, {node, dir}} ->
        drive_meta = Enum.at(shards_meta, i)

        if drive_meta && j < length(drive_meta["block_hashes"]) do
          tx.get_shard(node, dir, j, shard_len)
        else
          nil
        end
      end,
      timeout: :infinity,
      max_concurrency: n,
      on_timeout: :kill_task
    )
    |> Enum.map(fn
      {:ok, shard} -> shard
      {:exit, _} -> nil
    end)
  end

  # block j 的 N 个存储校验和（来自 sidecar；缺位补 32 个 0 -> 必不匹配 -> 当缺失）。与 M6 逐字一致。
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

  # ── stat / delete / bucket ──

  defp do_stat(bucket, key, version_id, opts) do
    case Paths.object_rel(bucket, key, version_id) do
      {:error, :invalid_key} ->
        {:error, :invalid_key}

      {:ok, obj_rel} ->
        endpoints = endpoints_for(bucket, key, opts)
        dirs = endpoint_dirs(endpoints, obj_rel)
        tx = transport(opts)

        case read_any_sidecar(tx, dirs) do
          {:ok, meta} -> {:ok, %{size: meta["size"]}}
          {:error, :enoent} -> {:error, :enoent}
        end
    end
  end

  defp do_delete(bucket, key, version_id, opts) do
    case Paths.object_rel(bucket, key, version_id) do
      {:error, :invalid_key} ->
        {:error, :invalid_key}

      {:ok, obj_rel} ->
        endpoints = endpoints_for(bucket, key, opts)
        dirs = endpoint_dirs(endpoints, obj_rel)
        tx = transport(opts)

        case Lock.with_lock({bucket, key}, fn ->
               Enum.each(dirs, fn {node, dir} -> tx.delete_shard(node, dir) end)
               :ok
             end) do
          {:ok, :ok} -> :ok
          {:error, :locked} -> {:error, :locked}
        end
    end
  end

  # 桶在每端点（全 set 的全端点并集）建 bucket 目录。put_bucket 不路由（桶在所有 set 都需有目录）。
  defp do_put_bucket(bucket, opts) do
    tx = transport(opts)

    all_endpoint_dirs(bucket, opts)
    |> Enum.each(fn {node, dir} -> tx.put_sidecar(node, mkdir_marker(dir), %{}) end)

    :ok
  end

  defp do_delete_bucket(bucket, opts) do
    tx = transport(opts)

    all_endpoint_dirs(bucket, opts)
    |> Enum.each(fn {node, dir} -> tx.delete_shard(node, mkdir_marker(dir)) end)

    :ok
  end

  # 全部 set 的全部端点的「桶根目录」（bucket 在每端点 drive 下一目录）。
  defp all_endpoint_dirs(bucket, opts) do
    set_ids =
      case topology(opts) do
        nil -> Topology.all_set_ids()
        t -> Topology.all_set_ids_from(t)
      end

    set_ids
    |> Enum.flat_map(fn set_id ->
      eps =
        case topology(opts) do
          nil -> Topology.endpoints(set_id)
          t -> Topology.endpoints_from(t, set_id)
        end

      Enum.map(eps, fn {node, drive} -> {node, Path.join(drive, bucket)} end)
    end)
    |> Enum.uniq()
  end

  # 桶目录用一个 .keep 标记的 sidecar 占位（put_bucket 只是建目录；delete_bucket 删之）。
  defp mkdir_marker(dir), do: Path.join(dir, ".keep")

  # ── parts（put_part / get_part_stream / assemble / abort）──

  defp do_put_part(bucket, _key, upload_id, part_number, chunks, opts) do
    part_rel = Paths.part_rel(bucket, upload_id, part_number)
    c = cfg(opts)
    endpoints = endpoints_for_upload(bucket, upload_id, opts)
    dirs = endpoint_dirs(endpoints, part_rel)
    tx = transport(opts)
    n = Config.total(c)

    acc0 = %{
      md5: :crypto.hash_init(:md5),
      sha: nil,
      size: 0,
      shard_len: nil,
      block_hashes: List.duplicate([], n),
      buffer: <<>>,
      block_index: 0,
      dirs: dirs,
      tx: tx
    }

    acc = Enum.reduce(chunks, acc0, fn chunk, acc -> feed_part(c, acc, chunk) end)
    acc = flush_final(c, acc)

    md5_raw = :crypto.hash_final(acc.md5)
    etag = Base.encode16(md5_raw, case: :lower)
    shard_len = acc.shard_len || 0

    meta =
      build_part_meta(c, acc.size, etag, shard_len, Enum.map(acc.block_hashes, &Enum.reverse/1))

    _ = write_sidecars(tx, dirs, meta)
    {:ok, %{size: acc.size, etag: etag, md5_raw: md5_raw}}
  end

  # 与 feed/3 同，但只更新 MD5（part 不需 sha256）。
  defp feed_part(cfg, acc, chunk) do
    acc = %{
      acc
      | md5: :crypto.hash_update(acc.md5, chunk),
        size: acc.size + byte_size(chunk),
        buffer: acc.buffer <> chunk
    }

    drain_full_blocks(cfg, acc)
  end

  defp build_part_meta(cfg, size, etag, shard_len, block_hashes_per_drive) do
    n = Config.total(cfg)

    shards =
      for i <- 0..(n - 1) do
        hashes = Enum.at(block_hashes_per_drive, i)
        %{"drive" => i, "shard_file_size" => length(hashes) * shard_len, "block_hashes" => hashes}
      end

    %{
      "ec" => %{
        "k" => cfg.data_shards,
        "m" => cfg.parity_shards,
        "block_size" => cfg.block_size,
        "algo" => "blake3-256"
      },
      "size" => size,
      "etag" => etag,
      "parts" => [%{"part" => 0, "size" => size}],
      "shards" => shards
    }
  end

  defp do_get_part_stream(bucket, _key, upload_id, part_number, opts) do
    part_rel = Paths.part_rel(bucket, upload_id, part_number)
    c = cfg(opts)
    endpoints = endpoints_for_upload(bucket, upload_id, opts)
    dirs = endpoint_dirs(endpoints, part_rel)
    tx = transport(opts)

    case read_any_sidecar(tx, dirs) do
      {:ok, meta} ->
        size = meta["size"]
        block_size = get_in(meta, ["ec", "block_size"])

        if size == 0 do
          {:ok, []}
        else
          {:ok,
           stream_object(
             c,
             bucket,
             "#{upload_id}/#{part_number}",
             "null",
             tx,
             dirs,
             meta,
             block_size,
             0,
             size - 1
           )}
        end

      {:error, :enoent} ->
        {:error, :enoent}
    end
  end

  defp do_assemble(bucket, key, upload_id, part_numbers, opts) do
    case Paths.object_rel(bucket, key, "null") do
      {:error, :invalid_key} ->
        {:error, :invalid_key}

      {:ok, obj_rel} ->
        case Lock.with_lock({bucket, key}, fn ->
               assemble_locked(bucket, key, upload_id, obj_rel, part_numbers, opts)
             end) do
          {:ok, result} -> result
          {:error, :locked} -> {:error, :locked}
        end
    end
  end

  defp assemble_locked(bucket, key, upload_id, obj_rel, part_numbers, opts) do
    c = cfg(opts)
    endpoints = endpoints_for(bucket, key, opts)
    dirs = endpoint_dirs(endpoints, obj_rel)
    tx = transport(opts)
    n = Config.total(c)

    acc0 = %{
      md5: :crypto.hash_init(:md5),
      sha: :crypto.hash_init(:sha256),
      size: 0,
      shard_len: nil,
      block_hashes: List.duplicate([], n),
      buffer: <<>>,
      block_index: 0,
      dirs: dirs,
      tx: tx
    }

    # 逐 part 解码（跨节点读）-> 喂入对象编码流（块接块流式，绝不缓冲整对象）。
    acc =
      Enum.reduce(part_numbers, acc0, fn pn, acc ->
        {:ok, part_stream} = do_get_part_stream(bucket, key, upload_id, pn, opts)
        Enum.reduce(part_stream, acc, fn chunk, a -> feed(c, a, chunk) end)
      end)

    acc = flush_final(c, acc)

    etag = acc.md5 |> :crypto.hash_final() |> Base.encode16(case: :lower)
    sha256 = acc.sha |> :crypto.hash_final() |> Base.encode16(case: :lower)
    shard_len = acc.shard_len || 0

    meta =
      build_meta(
        c,
        acc.size,
        etag,
        sha256,
        shard_len,
        Enum.map(acc.block_hashes, &Enum.reverse/1)
      )

    _ = write_sidecars(tx, dirs, meta)
    {:ok, %{size: acc.size}}
  end

  defp do_abort_upload(bucket, _key, upload_id, opts) do
    upload_rel = Paths.upload_rel(bucket, upload_id)
    endpoints = endpoints_for_upload(bucket, upload_id, opts)
    dirs = endpoint_dirs(endpoints, upload_rel)
    tx = transport(opts)
    Enum.each(dirs, fn {node, dir} -> tx.delete_shard(node, dir) end)
    :ok
  end

  # ── 辅助 ──

  # 从任一存活端点读 sidecar（与 M6 read_any_sidecar 等价，跨节点版）。
  defp read_any_sidecar(tx, dirs) do
    Enum.find_value(dirs, {:error, :enoent}, fn {node, dir} ->
      case tx.get_sidecar(node, dir) do
        {:ok, meta} -> {:ok, meta}
        {:error, _} -> nil
      end
    end)
  end
end
