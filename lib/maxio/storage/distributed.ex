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

  put：逐块流式编码（Codec.split_block），分片 i 写端点 i 的 temp obj-dir，流尾 sidecar 写 temp，
       最后各端点 commit_object（数据先于元数据原子 rename 到 final，B1-2），成功端点数 >= write_quorum
       才 {:ok}；否则清理全部 temp + {:error,:write_quorum}（铁律 3）。
  原子提交（B1-2）：写路径绝不就地覆盖 final 的 part.0/meta.json——每端点先 begin_tmp 得同卷
       `<drive>/.tmp/<uuid>` temp obj-dir，逐块 put_shard 进 temp，commit_object fsync + temp->final
       原子 rename（crash 任意点要么旧要么新，绝不撕裂）。fsync-before-quorum 让 write_quorum 在掉电下
       不再是耐久谎言。
  对象锁（B1-1）由 handler 层 `Maxio.Lock` 横跨「字节 + 元数据」提交 seam 单点持有；本后端不自持
  对象锁——否则 handler 已持同名 {bucket,key} 锁、后端再 `:global.trans` 同资源会死等自己
  （`:global.trans` 非重入）。锁是请求编排关注点，不是字节后端关注点（铁律 2）。非 handler 的直接
  调用方（backfill/scanner/conformance）若需并发安全须自行 `Maxio.Lock.with_object_lock`。
  get：逐块跨节点并行读 K-of-N 分片（宕机/超时端点 -> nil），按 sidecar BLAKE3 校验 + Codec.restore_block
       重建（存活 < K -> raise InsufficientShardsError，绝不静默返回错数据，铁律 3）+ 截断 + Range 裁剪，流式发出。

  每 callback 末参 opts：opts[:topology]（parsed struct）覆盖 :persistent_term；
  opts[:transport] 覆盖 config :maxio, :shard_transport。便于 ExUnit 注入进程内多节点 transport。
  """
  @behaviour Maxio.Storage.Backend

  require Logger

  alias Maxio.Storage.Erasure.{Codec, Config}
  alias Maxio.Cluster.{Paths, Placement, Topology, Transport}
  alias Maxio.Sidecar

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

  # B5-3 R6：version_id 无默认参（ErasureCoded/Storage 门面/behaviour 均无）——"null" 默认值会诱发
  # 调用方静默误写 null marker（替换 Suspended null 版本），删除这类语义性 version_id 必须显式传。
  @impl true
  def put_delete_marker(bucket, key, version_id, entry_opts \\ [], opts \\ []),
    do: do_put_delete_marker(bucket, key, version_id, entry_opts, opts)

  @impl true
  def delete_version(bucket, key, version_id \\ "null", opts \\ []),
    do: do_delete_version(bucket, key, version_id, opts)

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
    case Placement.resolve(bucket, key, opts) do
      {:ok, placement} -> {:ok, endpoints_for_set(placement.set_id, opts)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp endpoints_with_placement(bucket, key, opts) do
    case Placement.resolve(bucket, key, opts) do
      {:ok, placement} -> {:ok, {endpoints_for_set(placement.set_id, opts), placement}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp endpoints_for_set(nil, _opts), do: Topology.endpoints(nil)

  defp endpoints_for_set(set_id, opts) do
    case topology(opts) do
      nil -> Topology.endpoints(set_id)
      t -> Topology.endpoints_from(t, set_id)
    end
  end

  # part 的端点：以 upload_id 作 key 路由（同 upload 全 part + assemble 同 set）。
  defp endpoints_for_upload(bucket, upload_id, opts),
    do: endpoints_for(bucket, ".uploads/" <> upload_id, opts)

  defp transport(opts), do: Transport.impl(opts)

  # 端点 i 的「该对象在该 drive 下的目录」= Path.join(drive_i, obj_rel)。
  defp endpoint_dirs(endpoints, obj_rel),
    do: Enum.map(endpoints, fn {node, drive} -> {node, Path.join(drive, obj_rel)} end)

  # ── 原子提交编排（B1-2）──
  # 每端点 begin_tmp（drive_root = endpoint drive，与 final 同卷保证 rename 原子）；返回保序的
  # %{node, final_dir, tmp_dir}（begin_tmp 失败 -> tmp_dir=nil，写时跳过、commit 不计入 quorum）。
  defp begin_commit_targets(tx, endpoints, obj_rel) do
    Enum.map(endpoints, fn {node, drive} ->
      final_dir = Path.join(drive, obj_rel)

      tmp_dir =
        case tx.begin_tmp(node, drive) do
          {:ok, tmp} -> tmp
          {:error, _} -> nil
        end

      %{node: node, final_dir: final_dir, tmp_dir: tmp_dir}
    end)
  end

  # 保序 N 元素 (node, tmp_dir | nil)：分片 i 写端点 i 的 temp；begin_tmp 失败端点 -> nil（写时跳过）。
  defp ordered_tmp_dirs(targets) do
    Enum.map(targets, fn %{node: node, tmp_dir: tmp} -> {node, tmp} end)
  end

  # 各端点 commit_object（temp -> final 数据先于元数据原子 rename）；返回成功端点数（write quorum 判定）。
  # :meta_only 仅 do_put_delete_marker 注入（纯元数据提交声明，B5-0）；do_put/assemble 不注入 →
  # 缺省 false → 缺 part.0 仍立即失败（绝不静默把「忘写数据」当成功提交）。
  defp commit_all(tx, targets, opts) do
    commit_opts = Keyword.take(opts, [:fsync, :meta_only])

    targets
    |> Enum.filter(& &1.tmp_dir)
    |> Task.async_stream(
      fn %{node: node, tmp_dir: tmp, final_dir: final} ->
        case tx.commit_object(node, tmp, final, commit_opts) do
          :ok -> :ok
          _ -> :error
        end
      end,
      timeout: :infinity,
      max_concurrency: max(length(targets), 1)
    )
    |> Enum.count(fn
      {:ok, :ok} -> true
      _ -> false
    end)
  end

  # write_quorum 未达：回滚此次写参与（begin_tmp 成功）的端点——删其 temp obj-dir + 已 commit 到 final
  # 的 obj-dir（某些端点可能已原子 rename 到 final，但整体未达 quorum；删 final 保证「quorum 失败 =>
  # 对象不存在」不变量，绝不留低于 read_quorum 的撕裂半对象给后续 GET）。未参与端点（begin_tmp 失败）
  # 从未触碰 final，不删（保其旧值不变）。
  defp cleanup_tmp(tx, targets) do
    targets
    |> Enum.filter(& &1.tmp_dir)
    |> Enum.each(fn %{node: node, tmp_dir: tmp, final_dir: final} ->
      tx.delete_shard(node, tmp)
      tx.delete_shard(node, final)
    end)
  end

  # ── PUT（逐块流式编码；分片 i -> 端点 i）──
  # 不自持对象锁：B1-1 起锁由 handler 层 Maxio.Lock 横跨字节+元数据 seam 单点持有（避免双锁/非重入死等）。

  defp do_put(bucket, key, version_id, chunks, opts) do
    case Paths.object_rel(bucket, key, version_id) do
      {:error, :invalid_key} ->
        {:error, :invalid_key}

      {:ok, obj_rel} ->
        case endpoints_with_placement(bucket, key, opts) do
          {:ok, {endpoints, placement}} ->
            put_locked(bucket, key, version_id, obj_rel, chunks, opts, endpoints, placement)

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp put_locked(bucket, key, version_id, obj_rel, chunks, opts, endpoints, placement) do
    c = cfg(opts)
    tx = transport(opts)
    n = Config.total(c)

    # B1-2 原子提交：每端点先 begin_tmp（同卷 .tmp obj-dir），逐块流式写进 temp，最后 commit
    # 数据先于元数据原子 rename 到 final。begin_tmp 失败的端点（node down）记 tmp=nil，写时跳过。
    commit_targets = begin_commit_targets(tx, endpoints, obj_rel)

    # 保序 N 元素 (node, tmp_dir | nil)：分片 i 必须写端点 i 的 temp（down 端点 nil 跳过，绝不错位）。
    tmp_dirs = ordered_tmp_dirs(commit_targets)

    acc0 = %{
      md5: :crypto.hash_init(:md5),
      sha: :crypto.hash_init(:sha256),
      size: 0,
      shard_len: nil,
      block_hashes: List.duplicate([], n),
      buffer: <<>>,
      block_index: 0,
      dirs: tmp_dirs,
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
        version_id,
        opts,
        acc.size,
        etag,
        sha256,
        shard_len,
        Enum.map(acc.block_hashes, &Enum.reverse/1)
      )

    # sidecar 写进各端点 temp（与 part.0 同 temp obj-dir，一并原子提交）。
    _ = write_sidecars(tx, tmp_dirs, meta)

    ok_endpoints = commit_all(tx, commit_targets, opts)

    if ok_endpoints >= c.write_quorum do
      {:ok,
       %{
         size: acc.size,
         etag: etag,
         sha256: sha256,
         placement_set_id: placement.set_id,
         placement_pool_id: placement.pool_id,
         placement_topology_hash: placement.topology_hash
       }}
    else
      Logger.error("distributed put below write quorum",
        bucket: bucket,
        key: key,
        reason: "ok_endpoints=#{ok_endpoints} < write_quorum=#{c.write_quorum}"
      )

      cleanup_tmp(tx, commit_targets)
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
  # dirs 为保序 N 元素 (node, tmp_dir | nil)；nil 端点（begin_tmp 失败/down）跳过，绝不错位分片。
  defp write_block_shards(tx, dirs, j, shards, shard_len) do
    dirs
    |> Enum.zip(shards)
    |> Enum.reject(fn {{_node, dir}, _shard} -> is_nil(dir) end)
    |> Task.async_stream(
      fn {{node, dir}, shard} ->
        case tx.put_shard(node, dir, j, shard, shard_len) do
          :ok -> :ok
          _ -> :error
        end
      end,
      timeout: :infinity,
      max_concurrency: max(length(dirs), 1)
    )
    |> Enum.count(fn
      {:ok, :ok} -> true
      _ -> false
    end)
  end

  # ROUTE B B4-5：构造 v1 core（耐久 ec/shards/size/etag/sha256/parts，字节不变）后经
  # Sidecar.migrate_v1/2 升级为完整 maxio/2 sidecar（仅 Map.put 加 format + 单元素 versions，绝不
  # 污染耐久字段）。分布式同样单次 build_meta、同一份 meta 发所有端点 → N 份 signature 逐字一致。
  # version_id + opts 由 put/5 → do_put → put_locked 一路透传。
  defp build_meta(cfg, version_id, opts, size, etag, sha256, shard_len, block_hashes_per_drive) do
    n = Config.total(cfg)

    shards =
      for i <- 0..(n - 1) do
        hashes = Enum.at(block_hashes_per_drive, i)
        %{"drive" => i, "shard_file_size" => length(hashes) * shard_len, "block_hashes" => hashes}
      end

    core = %{
      "ec" => %{
        "k" => cfg.data_shards,
        "m" => cfg.parity_shards,
        "block_size" => cfg.block_size,
        "algo" => "blake3-256"
      },
      "size" => size,
      "etag" => etag,
      "sha256" => sha256,
      # 字节承载对象恒非 delete marker；sidecar 自描述该字段（缺省 false），使 drive-walk LIST
      # 能从盘上判定当前版本是否逻辑删除（对齐 MinIO xl.meta 承载 version type）。
      "is_delete_marker" => false,
      "parts" => [%{"part" => 0, "size" => size}],
      "shards" => shards
    }

    Sidecar.migrate_v1(core, version_opts(version_id, opts))
  end

  # 从 opts[:object_meta] 取 maxio/2 版本头字段，产出 Sidecar.migrate_v1/2 的 keyword（与
  # ErasureCoded.version_opts 逐字一致）。modtime 一次计算（同一份 meta 发所有端点 → N 份
  # signature 一致）；data_dir = version_id（方案 B 每版本独立目录）。
  # :etag（B6-2a）：多段完成对象的 S3 多段 ETag（"...-N"，Multipart.complete 透传）覆盖 versions
  # entry 的 S3 可见 etag；单次 PUT 无此键（nil）→ migrate_v1 沿用 core etag。
  defp version_opts(version_id, opts) do
    om = Keyword.get(opts, :object_meta, %{})
    modtime = System.os_time(:nanosecond)

    [
      version_id: version_id,
      data_dir: version_id,
      modtime: modtime,
      size: object_meta_value(om, :size),
      etag: Map.get(om, :etag),
      content_type: Map.get(om, :content_type, "binary/octet-stream"),
      content_encoding: Map.get(om, :content_encoding),
      content_disposition: Map.get(om, :content_disposition),
      cache_control: Map.get(om, :cache_control),
      expires: Map.get(om, :expires),
      tags: Map.get(om, :tags, %{}),
      sse: Map.get(om, :sse),
      acl_canned: Map.get(om, :acl_canned, "private"),
      acl_grants: Map.get(om, :acl_grants, %{"grants" => []}),
      storage_class: Map.get(om, :storage_class, "STANDARD"),
      user_metadata: Map.get(om, :user_metadata, %{})
    ]
  end

  defp object_meta_value(om, key) do
    case Map.get(om, key) do
      fun when is_function(fun, 0) -> fun.()
      value -> value
    end
  end

  # sidecar 写各端点（并行），返回成功端点数。dirs 可能含 nil（begin_tmp 失败端点）-> 跳过。
  defp write_sidecars(tx, dirs, meta) do
    dirs
    |> Enum.reject(fn {_node, dir} -> is_nil(dir) end)
    |> Task.async_stream(
      fn {node, dir} ->
        case tx.put_sidecar(node, dir, meta) do
          :ok -> :ok
          _ -> :error
        end
      end,
      timeout: :infinity,
      max_concurrency: max(length(dirs), 1)
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

        with {:ok, endpoints} <- endpoints_for(bucket, key, opts) do
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
                 stream_object(
                   c,
                   bucket,
                   key,
                   version_id,
                   tx,
                   dirs,
                   meta,
                   block_size,
                   first,
                   last
                 )}
              end

            {:error, :enoent} ->
              {:error, :enoent}
          end
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
        with {:ok, endpoints} <- endpoints_for(bucket, key, opts) do
          dirs = endpoint_dirs(endpoints, obj_rel)
          tx = transport(opts)

          case read_any_sidecar(tx, dirs) do
            {:ok, meta} -> {:ok, %{size: meta["size"]}}
            {:error, :enoent} -> {:error, :enoent}
          end
        end
    end
  end

  defp do_delete(bucket, key, version_id, opts) do
    case Paths.object_rel(bucket, key, version_id) do
      {:error, :invalid_key} ->
        {:error, :invalid_key}

      {:ok, obj_rel} ->
        with {:ok, endpoints} <- endpoints_for(bucket, key, opts) do
          dirs = endpoint_dirs(endpoints, obj_rel)
          tx = transport(opts)

          # 不自持对象锁（B1-1：锁由 handler 层 Maxio.Lock 横跨提交 seam 单点持有）。
          Enum.each(dirs, fn {node, dir} -> tx.delete_shard(node, dir) end)
          :ok
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

    with {:ok, endpoints} <- endpoints_for_upload(bucket, upload_id, opts) do
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

    with {:ok, endpoints} <- endpoints_for_upload(bucket, upload_id, opts) do
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
  end

  defp do_assemble(bucket, key, upload_id, part_numbers, opts) do
    version_id = Keyword.get(opts, :version_id, "null")

    case Paths.object_rel(bucket, key, version_id) do
      {:error, :invalid_key} ->
        {:error, :invalid_key}

      {:ok, obj_rel} ->
        # 不自持对象锁（B1-1：锁由 handler 层 Maxio.Lock 横跨 assemble 字节 + put_metadata 元数据单点持有）。
        case endpoints_with_placement(bucket, key, opts) do
          {:ok, {endpoints, placement}} ->
            assemble_locked(
              bucket,
              key,
              upload_id,
              version_id,
              obj_rel,
              part_numbers,
              opts,
              endpoints,
              placement
            )

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp assemble_locked(
         bucket,
         key,
         upload_id,
         version_id,
         obj_rel,
         part_numbers,
         opts,
         endpoints,
         placement
       ) do
    c = cfg(opts)
    tx = transport(opts)
    n = Config.total(c)

    # B1-2 原子提交：组装的对象同样先写各端点 temp obj-dir，commit 数据先于元数据原子 rename 到 final。
    commit_targets = begin_commit_targets(tx, endpoints, obj_rel)
    tmp_dirs = ordered_tmp_dirs(commit_targets)

    acc0 = %{
      md5: :crypto.hash_init(:md5),
      sha: :crypto.hash_init(:sha256),
      size: 0,
      shard_len: nil,
      block_hashes: List.duplicate([], n),
      buffer: <<>>,
      block_index: 0,
      dirs: tmp_dirs,
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

    # 多段 assemble 的最终对象落 opts[:version_id] 指定布局（缺省 null）；同样产 maxio/2 sidecar
    # 使其 sidecar-可读/可列。ROUTE B B4-6 D1：透传 assemble 的 opts（携 opts[:object_meta]，由
    # Multipart.complete 从 upload 会话取 content_type/user_metadata 构造），version_opts 据此自描述
    # 真实 content_type/user_metadata（替换原硬编码 []，消除多段 :sidecar 读 content-type 错误）。
    meta =
      build_meta(
        c,
        version_id,
        opts,
        acc.size,
        etag,
        sha256,
        shard_len,
        Enum.map(acc.block_hashes, &Enum.reverse/1)
      )

    _ = write_sidecars(tx, tmp_dirs, meta)

    ok_endpoints = commit_all(tx, commit_targets, opts)

    if ok_endpoints >= c.write_quorum do
      {:ok,
       %{
         size: acc.size,
         placement_set_id: placement.set_id,
         placement_pool_id: placement.pool_id,
         placement_topology_hash: placement.topology_hash
       }}
    else
      Logger.error("distributed assemble below write quorum",
        bucket: bucket,
        key: key,
        reason: "ok_endpoints=#{ok_endpoints} < write_quorum=#{c.write_quorum}"
      )

      cleanup_tmp(tx, commit_targets)
      {:error, :write_quorum}
    end
  end

  defp do_abort_upload(bucket, _key, upload_id, opts) do
    upload_rel = Paths.upload_rel(bucket, upload_id)

    with {:ok, endpoints} <- endpoints_for_upload(bucket, upload_id, opts) do
      dirs = endpoint_dirs(endpoints, upload_rel)
      tx = transport(opts)
      Enum.each(dirs, fn {node, dir} -> tx.delete_shard(node, dir) end)
      :ok
    end
  end

  # ── delete marker 落盘（ROUTE B B5-0；B5-3 R2 非破坏化）──
  # 在 version_id 对应盘上对象目录写**纯 delete-marker maxio/2 sidecar**（无 part.0、无 ec/shards
  # core），与 PUT 同级 B1-2 原子提交。单次 build_delete_marker_meta、同一份 meta 发所有端点 →
  # N 份 signature 一致。
  #
  # B5-3 R2 —— marker 提交是对 final 的**替换**（Suspended null 路径的 final 可能持有既有 null 版本，
  # meta_only commit 原子 rename meta.json 覆盖旧 sidecar 即「替换」语义），故与 do_put 的
  # 「quorum 失败 ⇒ 新对象不存在」回滚不变量不同——此处**任何失败路径都绝不删 final**（删 final =
  # 摧毁被替换的旧版本，制造裸 404 破坏窗口）：
  #   1) pre-commit quorum 闸：temp sidecar 成功写出的端点数 < write_quorum → 在触碰任何 final 之前
  #      中止（只清 temp）→ 503 后旧版本全端点完好（GET 仍 200），重试收敛；
  #   2) commit 后仍 < quorum（罕见：rename 级失败）→ 只清 temp；已 commit 端点留部分 marker
  #      （< quorum 不构成读权威），由重试/heal 收敛（Logger.error 留痕，铁律 3 不静默）；
  #   3) quorum 成功 → best-effort GC final 里的孤儿 part.0（delete-marker 版本目录里任何 part.0
  #      定义上都是被替换 null 版本的孤儿字节；transport delete_shard 契约幂等/自吞，残余孤儿归
  #      heal/reverse-GC 渠道）。
  defp do_put_delete_marker(bucket, key, version_id, entry_opts, opts) do
    case Paths.object_rel(bucket, key, version_id) do
      {:error, :invalid_key} ->
        {:error, :invalid_key}

      {:ok, obj_rel} ->
        c = cfg(opts)

        with {:ok, endpoints} <- endpoints_for(bucket, key, opts) do
          tx = transport(opts)

          commit_targets = begin_commit_targets(tx, endpoints, obj_rel)
          tmp_dirs = ordered_tmp_dirs(commit_targets)
          meta = build_delete_marker_meta(version_id, entry_opts)

          prepared = write_sidecars(tx, tmp_dirs, meta)

          if prepared < c.write_quorum do
            Logger.error("distributed put_delete_marker below write quorum (pre-commit)",
              bucket: bucket,
              key: key,
              reason: "prepared=#{prepared} < write_quorum=#{c.write_quorum}"
            )

            cleanup_tmps(tx, commit_targets)
            {:error, :write_quorum}
          else
            # 纯元数据提交声明（ShardServer.commit/3 :meta_only）：temp 只有 meta.json 无 part.0 →
            # 跳过 part rename 只提交 meta.json（仍 fsync + 原子 rename + sync dir）。
            ok_endpoints = commit_all(tx, commit_targets, Keyword.put(opts, :meta_only, true))

            if ok_endpoints >= c.write_quorum do
              gc_orphan_parts(tx, commit_targets)
              :ok
            else
              Logger.error("distributed put_delete_marker below write quorum",
                bucket: bucket,
                key: key,
                reason: "ok_endpoints=#{ok_endpoints} < write_quorum=#{c.write_quorum}"
              )

              cleanup_tmps(tx, commit_targets)
              {:error, :write_quorum}
            end
          end
        end
    end
  end

  # B5-3 R2：只清本次写参与端点的 temp obj-dir，**绝不触碰 final**（替换式提交的失败回滚专用；
  # 与 cleanup_tmp/2 的「删 temp + final」语义相区分——那是 do_put/assemble 新对象落点的不变量）。
  defp cleanup_tmps(tx, targets) do
    targets
    |> Enum.filter(& &1.tmp_dir)
    |> Enum.each(fn %{node: node, tmp_dir: tmp} -> tx.delete_shard(node, tmp) end)
  end

  # B5-3 R2：marker quorum 成功后 best-effort GC 各端点 final 里被替换 null 版本的孤儿 part.0
  # （delete marker 无字节，其版本目录里任何 part.0 定义上都是孤儿）。delete_shard 契约幂等且把
  # 宕机塌缩为 :ok（best-effort by contract），残余孤儿归既有 heal/reverse-GC 渠道。
  defp gc_orphan_parts(tx, targets) do
    Enum.each(targets, fn %{node: node, final_dir: final} ->
      _ = tx.delete_shard(node, Path.join(final, "part.0"))
    end)
  end

  # ROUTE B B5-0：纯 delete-marker maxio/2 sidecar（无字节、无耐久 core）。与 ErasureCoded 同源
  # （Maxio.Storage.DeleteMarker.sidecar/2，单一形态来源）；modtime 单次计算所有端点同值 → signature 一致。
  defp build_delete_marker_meta(version_id, entry_opts) do
    Maxio.Storage.DeleteMarker.sidecar(version_id, entry_opts)
  end

  # ── DELETE ?versionId 的权威 quorum 删除（ROUTE B fidelity，Backend.delete_version/4 契约）──
  #
  # 与 do_delete 的 best-effort 清理删除不同：每端点删版本 obj-dir 后经 list_dir 探针**确认**
  # 「端点可达且版本目录显式 missing」（transport 的 delete_shard 把宕机塌缩成 :ok——契约如此，
  # 故确认必须经 list_dir 的结构性 {:error,:unavailable}，与 Maxio.Storage.Scanner.probe_endpoint
  # 同源判定，铁律 3 绝不把不可达当已删除）。确认数 >= write_quorum → :ok；否则
  # {:error, :write_quorum}（绝不静默成功——否则 scanner forward 会从幸存 sidecar 复活该版本）。
  # 幂等：版本本就缺失的端点同样计入确认。
  defp do_delete_version(bucket, key, version_id, opts) do
    case Paths.object_rel(bucket, key, version_id) do
      {:error, :invalid_key} ->
        {:error, :invalid_key}

      {:ok, obj_rel} ->
        c = cfg(opts)
        tx = transport(opts)

        with {:ok, endpoints} <- endpoints_for(bucket, key, opts) do
          confirmed =
            Enum.count(endpoints, fn {node, drive} ->
              dir = Path.join(drive, obj_rel)
              _ = tx.delete_shard(node, dir)
              version_deleted?(tx, node, dir)
            end)

          if confirmed >= c.write_quorum do
            :ok
          else
            Logger.error("distributed delete_version below write quorum",
              bucket: bucket,
              key: key,
              reason:
                "confirmed=#{confirmed} < write_quorum=#{c.write_quorum} version_id=#{version_id}"
            )

            {:error, :write_quorum}
          end
        end
    end
  end

  # 单端点删除确认探针：列版本目录的父目录——可达（{:ok, entries}，目录不存在为 {:ok,[]}）且无
  # 「名为版本末段且含 meta.json（object?=true）」的子目录 = 确认已删除；{:error,_}（宕机/异常）=
  # 不可达，绝不计入确认。
  defp version_deleted?(tx, node, dir) do
    parent = Path.dirname(dir)
    base = Path.basename(dir)

    case tx.list_dir(node, parent, []) do
      {:ok, entries} -> not Enum.any?(entries, &(&1.name == base and &1.object?))
      {:error, _} -> false
    end
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
