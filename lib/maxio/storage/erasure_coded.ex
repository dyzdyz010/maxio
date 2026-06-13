defmodule Maxio.Storage.ErasureCoded do
  @moduledoc """
  Reed-Solomon 纠删码存储后端（单机多盘 = 一个 erasure set），实现 Maxio.Storage.Backend 契约，
  与 Maxio.Storage.FS 返回形态逐字节一致（铁律 2：后端即插件，核心管线一行不改）。

  对象在每个盘 i 落成一个目录：part.0（盘 i 的分片字节，逐块流式追加）+ meta.json（per-object sidecar）。
  put 逐块流式编码（绝不缓冲整对象，铁律 4），分片 i 写盘 i + sidecar 写全部 N 盘，
  成功盘数 >= write_quorum 才 {:ok}，否则 {:error,:write_quorum}（铁律 3）。
  get 逐块读 K 个存活分片、按 sidecar 的 per-block BLAKE3 校验、重建、流式发出；
  存活 < K -> raise InsufficientShardsError（绝不静默返回错数据）。

  每个 callback 接受可选末参 opts（:drives 覆盖盘目录列表、:data_shards/:parity_shards/:block_size
  覆盖 EC 参数，便于测试隔离），缺省从 config :maxio, :erasure 读。
  """
  @behaviour Maxio.Storage.Backend

  require Logger

  alias Maxio.Storage.Erasure.{Codec, Config, Meta}
  alias Maxio.Cluster.ShardServer
  alias Maxio.Sidecar

  @meta_file "meta.json"
  @part_file "part.0"

  # ── Backend callbacks（签名与 FS 一致；opts 末参默认）──

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

  # ── 分段上传 parts 回调（M6-4）。part 分片落
  # <drive_i>/.uploads/<bucket>/<upload_id>/<n>/part.0 + meta.json；
  # assemble 逐 part 解码再重编码进对象 part.0；abort 跨盘删 upload 目录。──

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

  @impl true
  def put_delete_marker(bucket, key, version_id, entry_opts \\ [], opts \\ []),
    do: do_put_delete_marker(bucket, key, version_id, entry_opts, opts)

  @impl true
  def delete_version(bucket, key, version_id \\ "null", opts \\ []),
    do: do_delete_version(bucket, key, version_id, opts)

  # part 在盘 d 下的目录。
  defp part_dirs(bucket, upload_id, part_number, cfg) do
    sub = Path.join([".uploads", bucket, upload_id, Integer.to_string(part_number)])
    Enum.map(cfg.drives, &Path.join(&1, sub))
  end

  defp upload_dirs(bucket, upload_id, cfg) do
    sub = Path.join([".uploads", bucket, upload_id])
    Enum.map(cfg.drives, &Path.join(&1, sub))
  end

  defp do_put_part(bucket, _key, upload_id, part_number, chunks, opts) do
    cfg = Config.load!(opts)
    dirs = part_dirs(bucket, upload_id, part_number, cfg)
    Enum.each(dirs, &File.mkdir_p!/1)
    fds = Enum.map(dirs, fn dir -> open_write!(Path.join(dir, @part_file)) end)

    try do
      acc0 = %{
        md5: :crypto.hash_init(:md5),
        sha: nil,
        size: 0,
        shard_len: nil,
        block_hashes: List.duplicate([], Config.total(cfg)),
        buffer: <<>>,
        fds: fds
      }

      acc = Enum.reduce(chunks, acc0, fn chunk, acc -> feed_part(cfg, acc, chunk) end)
      acc = flush_final(cfg, acc)

      md5_raw = :crypto.hash_final(acc.md5)
      etag = Base.encode16(md5_raw, case: :lower)
      shard_len = acc.shard_len || 0

      meta =
        build_part_meta(
          cfg,
          acc.size,
          etag,
          shard_len,
          Enum.map(acc.block_hashes, &Enum.reverse/1)
        )

      _ = write_sidecars(dirs, meta)
      {:ok, %{size: acc.size, etag: etag, md5_raw: md5_raw}}
    after
      Enum.each(fds, &File.close/1)
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
    cfg = Config.load!(opts)
    dirs = part_dirs(bucket, upload_id, part_number, cfg)

    case read_any_sidecar(dirs) do
      {:ok, meta} ->
        size = meta["size"]
        block_size = get_in(meta, ["ec", "block_size"])

        if size == 0 do
          {:ok, []}
        else
          {:ok,
           stream_object(
             cfg,
             bucket,
             "#{upload_id}/#{part_number}",
             "null",
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
    cfg = Config.load!(opts)
    version_id = Keyword.get(opts, :version_id, "null")

    with {:ok, commit_pairs} <- commit_pairs(bucket, key, version_id, cfg) do
      # B1-2 原子提交：组装对象同样先写各盘 temp obj-dir，commit 数据先于元数据原子 rename 到 final。
      tmps = Enum.map(commit_pairs, fn {drive_root, _final} -> begin_tmp!(drive_root) end)
      fds = Enum.map(tmps, fn tmp -> open_write!(Path.join(tmp, @part_file)) end)

      acc =
        try do
          acc0 = %{
            md5: :crypto.hash_init(:md5),
            sha: :crypto.hash_init(:sha256),
            size: 0,
            shard_len: nil,
            block_hashes: List.duplicate([], Config.total(cfg)),
            buffer: <<>>,
            fds: fds
          }

          # 逐 part 解码 -> 喂入对象编码流（块接块流式）。
          acc =
            Enum.reduce(part_numbers, acc0, fn pn, acc ->
              {:ok, part_stream} = do_get_part_stream(bucket, key, upload_id, pn, opts)
              Enum.reduce(part_stream, acc, fn chunk, a -> feed(cfg, a, chunk) end)
            end)

          flush_final(cfg, acc)
        after
          Enum.each(fds, &File.close/1)
        end

      etag = acc.md5 |> :crypto.hash_final() |> Base.encode16(case: :lower)
      sha256 = acc.sha |> :crypto.hash_final() |> Base.encode16(case: :lower)
      shard_len = acc.shard_len || 0

      # 多段 assemble 的最终对象落 opts[:version_id] 指定布局（缺省 null）；同样产 maxio/2 sidecar
      # 使其 sidecar-可读/可列。ROUTE B B4-6 D1：透传 assemble 的 opts（携 opts[:object_meta]，由
      # Multipart.complete 从 upload 会话取 content_type/user_metadata 构造），version_opts 据此自描述
      # 真实 content_type/user_metadata（替换原硬编码 []，消除多段 :sidecar 读 content-type 错误）。
      meta =
        build_meta(
          cfg,
          version_id,
          opts,
          acc.size,
          etag,
          sha256,
          shard_len,
          Enum.map(acc.block_hashes, &Enum.reverse/1)
        )

      write_tmp_sidecars(tmps, meta)

      ok_drives = commit_drives(tmps, commit_pairs, opts)

      if ok_drives >= cfg.write_quorum do
        {:ok, %{size: acc.size}}
      else
        Logger.error("erasure assemble below write quorum",
          bucket: bucket,
          key: key,
          reason: "ok_drives=#{ok_drives} < write_quorum=#{cfg.write_quorum}"
        )

        rollback_commit(tmps, commit_pairs)
        {:error, :write_quorum}
      end
    end
  end

  defp do_abort_upload(bucket, _key, upload_id, opts) do
    cfg = Config.load!(opts)
    Enum.each(upload_dirs(bucket, upload_id, cfg), fn dir -> _ = File.rm_rf(dir) end)
    :ok
  end

  # ── delete marker 落盘（ROUTE B B5-0）──
  # 在 version_id 对应盘上对象目录写**纯 delete-marker maxio/2 sidecar**（无 part.0、无 ec/shards
  # core），与 PUT 同级 temp→rename 原子提交：各盘先 begin_tmp，sidecar 写 temp，commit 数据先于元数据
  # 原子 rename 到 final，成功盘数 >= write_quorum 才 :ok，否则回滚 + {:error,:write_quorum}（铁律 3）。
  defp do_put_delete_marker(bucket, key, version_id, entry_opts, opts) do
    cfg = Config.load!(opts)

    with {:ok, commit_pairs} <- commit_pairs(bucket, key, version_id, cfg) do
      tmps = Enum.map(commit_pairs, fn {drive_root, _final} -> begin_tmp!(drive_root) end)
      meta = build_delete_marker_meta(version_id, entry_opts)

      write_tmp_sidecars(tmps, meta)

      # 纯元数据提交声明（ShardServer.commit/3 :meta_only）：temp 只有 meta.json 无 part.0 →
      # 跳过 part rename 只提交 meta.json（仍 fsync + 原子 rename + sync dir）。
      ok_drives = commit_drives(tmps, commit_pairs, Keyword.put(opts, :meta_only, true))

      if ok_drives >= cfg.write_quorum do
        # B5-3 R2：marker 提交是对 final 的「替换」（Suspended null 路径 final 可能持有既有 null
        # 版本，meta_only rename 覆盖其 sidecar）——quorum 成功后 best-effort GC 各盘 final 里被
        # 替换 null 版本的孤儿 part.0（delete marker 无字节，marker 版本目录里任何 part.0 定义上
        # 都是孤儿）。失败幂等忽略（残余孤儿归 heal/GC 渠道），与 Distributed 同语义（铁律 2）。
        Enum.each(commit_pairs, fn {_drive_root, final_dir} ->
          _ = File.rm(Path.join(final_dir, @part_file))
        end)

        :ok
      else
        Logger.error("erasure put_delete_marker below write quorum",
          bucket: bucket,
          key: key,
          reason: "ok_drives=#{ok_drives} < write_quorum=#{cfg.write_quorum}"
        )

        # B5-3 R2：替换式提交的失败回滚**只清 temp，绝不删 final**（rollback_commit 会连 final 一并
        # 删掉 = 摧毁被替换的旧 null 版本，制造裸 404 破坏窗口）。已 commit 的盘留部分 marker
        # （< quorum 不构成读权威），由重试/heal 收敛，与 Distributed 同语义（铁律 2）。
        Enum.each(tmps, &File.rm_rf/1)
        {:error, :write_quorum}
      end
    end
  end

  # ── 对象目录布局（每盘一份）──

  # 对象在盘 d 下的目录：<d>/<bucket>/<rel>（null 版本）或 <d>/.versions/<bucket>/<rel>/<version_id>。
  # rel 经 Maxio.Cluster.Paths.object_rel（单一事实来源，铁律 2）：空段/尾斜杠/布局保留名段
  # 全部段编码无碰撞落盘（绝不 trim 折叠、绝不与 meta.json/part.0 布局名冲突）。
  defp object_dirs(bucket, key, version_id, cfg) do
    case Maxio.Cluster.Paths.object_rel(bucket, key, version_id) do
      {:ok, sub} -> {:ok, Enum.map(cfg.drives, &Path.join(&1, sub))}
      {:error, :invalid_key} -> {:error, :invalid_key}
    end
  end

  # ── 原子提交编排（B1-2）──
  # 每盘返回 {drive_root, final_obj_dir}：drive_root（cfg.drives 元素）下建同卷 .tmp，final 为对象目录。
  defp commit_pairs(bucket, key, version_id, cfg) do
    case Maxio.Cluster.Paths.object_rel(bucket, key, version_id) do
      {:ok, sub} ->
        {:ok, Enum.map(cfg.drives, fn drive -> {drive, Path.join(drive, sub)} end)}

      {:error, :invalid_key} ->
        {:error, :invalid_key}
    end
  end

  # 在某盘 drive_root 下建同卷 temp obj-dir（与 final 同卷 -> rename 原子）。
  defp begin_tmp!(drive_root) do
    {:ok, tmp} = ShardServer.begin_tmp(drive_root)
    tmp
  end

  # sidecar 写各盘 temp obj-dir（与 part.0 同 temp，一并 commit）。
  defp write_tmp_sidecars(tmps, meta) do
    bin = Meta.encode(meta)
    Enum.each(tmps, fn tmp -> File.write!(Path.join(tmp, @meta_file), bin) end)
  end

  # 各盘 commit（temp -> final 数据先于元数据原子 rename + fsync）；返回成功盘数（write quorum 判定）。
  # :meta_only 仅 do_put_delete_marker 注入（纯元数据提交声明，B5-0）；do_put/assemble 不注入 →
  # 缺省 false → 缺 part.0 仍立即失败（绝不静默把「忘写数据」当成功提交）。
  defp commit_drives(tmps, commit_pairs, opts) do
    commit_opts = Keyword.take(opts, [:fsync, :meta_only])

    tmps
    |> Enum.zip(commit_pairs)
    |> Enum.reduce(0, fn {tmp, {_drive_root, final_dir}}, ok ->
      case ShardServer.commit(tmp, final_dir, commit_opts) do
        :ok -> ok + 1
        {:error, _} -> ok
      end
    end)
  end

  # write_quorum 未达：回滚——删各盘 temp + 已 commit 到 final 的 obj-dir（保证 quorum 失败 => 对象不存在）。
  defp rollback_commit(tmps, commit_pairs) do
    Enum.each(tmps, &File.rm_rf/1)
    Enum.each(commit_pairs, fn {_drive_root, final_dir} -> File.rm_rf(final_dir) end)
  end

  # ── PUT：逐块流式编码 ──

  defp do_put(bucket, key, version_id, chunks, opts) do
    cfg = Config.load!(opts)

    with {:ok, commit_pairs} <- commit_pairs(bucket, key, version_id, cfg) do
      # B1-2 原子提交：各盘先建同卷 temp obj-dir，逐块流式写 temp 的 part.0，流尾 sidecar 写 temp，
      # 最后各盘 commit（数据先于元数据原子 rename 到 final），成功盘数 >= write_quorum 才 {:ok}。
      tmps = Enum.map(commit_pairs, fn {drive_root, _final} -> begin_tmp!(drive_root) end)
      fds = Enum.map(tmps, fn tmp -> open_write!(Path.join(tmp, @part_file)) end)

      acc =
        try do
          acc0 = %{
            md5: :crypto.hash_init(:md5),
            sha: :crypto.hash_init(:sha256),
            size: 0,
            shard_len: nil,
            # 每盘一个 block_hashes 反序列表（hex）
            block_hashes: List.duplicate([], Config.total(cfg)),
            buffer: <<>>,
            fds: fds
          }

          acc = Enum.reduce(chunks, acc0, fn chunk, acc -> feed(cfg, acc, chunk) end)
          flush_final(cfg, acc)
        after
          Enum.each(fds, &File.close/1)
        end

      etag = acc.md5 |> :crypto.hash_final() |> Base.encode16(case: :lower)
      sha256 = acc.sha |> :crypto.hash_final() |> Base.encode16(case: :lower)
      shard_len = acc.shard_len || 0

      meta =
        build_meta(
          cfg,
          version_id,
          opts,
          acc.size,
          etag,
          sha256,
          shard_len,
          Enum.map(acc.block_hashes, &Enum.reverse/1)
        )

      # sidecar 写各盘 temp（与 part.0 同 temp obj-dir，一并原子提交）。
      write_tmp_sidecars(tmps, meta)

      ok_drives = commit_drives(tmps, commit_pairs, opts)

      if ok_drives >= cfg.write_quorum do
        {:ok, %{size: acc.size, etag: etag, sha256: sha256}}
      else
        Logger.error("erasure put below write quorum",
          bucket: bucket,
          key: key,
          reason: "ok_drives=#{ok_drives} < write_quorum=#{cfg.write_quorum}"
        )

        rollback_commit(tmps, commit_pairs)
        {:error, :write_quorum}
      end
    end
  end

  # 累积 chunk 到 buffer，满 block_size 即编码落盘。
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

  # 流尽：写最后不满块（非空对象至少一个块；空对象 buffer="" 不写块）。
  defp flush_final(_cfg, %{buffer: <<>>} = acc), do: acc

  defp flush_final(cfg, %{buffer: buffer} = acc),
    do: write_block(cfg, %{acc | buffer: <<>>}, buffer)

  # 编码一个 block：N 分片写各盘 fd，校验和按盘累积。
  #
  # 关键：把每个 block 零填充到固定 block_size 后再编码，保证全对象所有 block 的 shard_len 一致
  # （= even(ceil(block_size/K))）。否则末块（明文 < block_size）会产出更短的分片，破坏 sidecar
  # 单一 shard_len 假设与 GET 侧 `j * shard_len` 偏移寻址。填充字节在 GET 侧按每块明文长度
  # （block_plain_len）截断，明文逐字节不变（铁律 5）。
  defp write_block(cfg, acc, block) do
    padded =
      if byte_size(block) < cfg.block_size do
        block <> <<0::size((cfg.block_size - byte_size(block)) * 8)>>
      else
        block
      end

    %{shards: shards, checksums: checksums, shard_len: shard_len} = Codec.split_block(cfg, padded)

    Enum.zip(acc.fds, shards) |> Enum.each(fn {fd, shard} -> :ok = IO.binwrite(fd, shard) end)

    block_hashes =
      acc.block_hashes
      |> Enum.zip(checksums)
      |> Enum.map(fn {acc_list, ck} -> [Base.encode16(ck, case: :lower) | acc_list] end)

    %{acc | shard_len: shard_len, block_hashes: block_hashes}
  end

  # ROUTE B B4-5：构造 v1 core（耐久 ec/shards/size/etag/sha256/parts，字节不变），紧接经
  # Sidecar.migrate_v1/2 升级为完整 maxio/2 sidecar（仅 Map.put 加 format + 单元素 versions 数组，
  # 绝不污染耐久字段）。富元数据从 opts[:object_meta] 取（缺省 %{}）；modtime 一次计算（do_put
  # 单次 build_meta、同一份 meta 写所有盘 → N 份 Sidecar.signature 逐字一致）。version_id + opts
  # 由 put/5 → do_put 一路透传。
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

  # 从 opts[:object_meta] 取 maxio/2 版本头字段，产出 Sidecar.migrate_v1/2 的 keyword。
  # modtime 一次计算（同一份 meta 写所有盘 → N 份 signature 一致，铁律 3 分歧检测前提）；
  # data_dir = version_id（方案 B 每版本独立目录）。缺字段由 migrate_v1 兜底默认。
  # :etag（B6-2a）：多段完成对象的 S3 多段 ETag（"...-N"，Multipart.complete 透传）覆盖 versions
  # entry 的 S3 可见 etag；单次 PUT 无此键（nil）→ migrate_v1 沿用 core etag。
  defp version_opts(version_id, opts) do
    om = Keyword.get(opts, :object_meta, %{})
    modtime = Map.get(om, :modtime, System.os_time(:nanosecond))

    [
      version_id: version_id,
      data_dir: version_id,
      modtime: modtime,
      generation: Map.get(om, :generation, 0),
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

  defp write_sidecars(dirs, meta) do
    bin = Meta.encode(meta)

    Enum.reduce(dirs, 0, fn dir, ok ->
      case File.write(Path.join(dir, @meta_file), bin) do
        :ok -> ok + 1
        {:error, _} -> ok
      end
    end)
  end

  # ROUTE B B5-0：纯 delete-marker maxio/2 sidecar（无 part.0 字节、无 ec/shards 耐久 core——delete
  # marker 无字节，合法）。entry：type="delete_marker"/version_id/modtime（单次纳秒，所有盘同值 →
  # N 份 Sidecar.signature 一致）/generation:0/is_latest:true。读侧 ObjectMeta.view_or_not_found /
  # Maxio.Listing 的 delete_marker 处理（B4-3/B4-4）据此 latest marker→404+头 / LIST 排除。
  defp build_delete_marker_meta(version_id, entry_opts) do
    Maxio.Storage.DeleteMarker.sidecar(version_id, entry_opts)
  end

  # ── GET：逐块流式重建 ──

  defp do_get(bucket, key, version_id, range, opts) do
    cfg = Config.load!(opts)

    with {:ok, dirs} <- object_dirs(bucket, key, version_id, cfg),
         {:ok, meta} <- read_any_sidecar(dirs) do
      size = meta["size"]
      block_size = get_in(meta, ["ec", "block_size"])
      {first, last} = normalize_range(range, size)

      if size == 0 or last < first do
        {:ok, []}
      else
        {:ok, stream_object(cfg, bucket, key, version_id, dirs, meta, block_size, first, last)}
      end
    else
      {:error, :enoent} -> {:error, :enoent}
      :error -> {:error, :invalid_key}
    end
  end

  defp normalize_range(nil, size), do: {0, max(size - 1, 0)}
  defp normalize_range({first, last}, _size), do: {first, last}

  # 逐 block 读 K 存活分片、校验+重建、裁剪到 [first,last]，发出。
  defp stream_object(cfg, bucket, key, version_id, dirs, meta, block_size, first, last) do
    n = Config.total(cfg)
    shards_meta = meta["shards"]
    size = meta["size"]
    shard_len = block_shard_len(meta, cfg)
    first_block = div(first, block_size)
    last_block = div(last, block_size)

    Stream.resource(
      fn ->
        fds =
          Enum.map(dirs, fn dir ->
            case :file.open(String.to_charlist(Path.join(dir, @part_file)), [:read, :binary, :raw]) do
              {:ok, fd} -> fd
              {:error, _} -> nil
            end
          end)

        {fds, first_block}
      end,
      fn
        {fds, j} when j > last_block ->
          {:halt, {fds, j}}

        {fds, j} ->
          block_plain_len = block_plain_len(size, block_size, j)

          shards =
            Enum.with_index(fds)
            |> Enum.map(fn {fd, i} -> read_shard(fd, j, shard_len, shards_meta, i) end)

          checksums = block_checksums(shards_meta, n, j)

          plain =
            Codec.restore_block(cfg, shards, checksums, block_plain_len,
              bucket: bucket,
              key: key,
              version_id: version_id,
              block_index: j
            )

          # 裁剪到 [first,last] 与本块的交集。
          block_start = j * block_size
          lo = max(first, block_start) - block_start
          hi = min(last, block_start + block_plain_len - 1) - block_start
          out = binary_part(plain, lo, hi - lo + 1)
          {[out], {fds, j + 1}}
      end,
      fn {fds, _j} -> Enum.each(fds, fn fd -> if fd, do: :file.close(fd) end) end
    )
  end

  # 某盘缺/读不到 -> nil；否则该盘 block j 的分片字节。
  defp read_shard(nil, _j, _shard_len, _shards_meta, _i), do: nil

  defp read_shard(fd, j, shard_len, shards_meta, i) do
    drive_meta = Enum.at(shards_meta, i)

    if drive_meta && j < length(drive_meta["block_hashes"]) do
      case :file.pread(fd, j * shard_len, shard_len) do
        {:ok, data} when byte_size(data) == shard_len -> data
        _ -> nil
      end
    else
      nil
    end
  end

  # block j 的 N 个存储校验和（来自 sidecar，原始字节；缺位补 32 个 0 -> 必不匹配 -> 当缺失）。
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

  # 由 sidecar 推 shard_len：shard_file_size / 块数（取首个有块的盘）。
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

  # 第 j 块的明文长度（除最后一块外都是 block_size）。
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
    cfg = Config.load!(opts)

    with {:ok, dirs} <- object_dirs(bucket, key, version_id, cfg),
         {:ok, meta} <- read_any_sidecar(dirs) do
      {:ok, %{size: meta["size"]}}
    else
      {:error, :enoent} -> {:error, :enoent}
      :error -> {:error, :invalid_key}
    end
  end

  defp do_delete(bucket, key, version_id, opts) do
    cfg = Config.load!(opts)

    with {:ok, dirs} <- object_dirs(bucket, key, version_id, cfg) do
      Enum.each(dirs, fn dir -> _ = File.rm_rf(dir) end)
      :ok
    end
  end

  # ROUTE B fidelity —— DELETE ?versionId 的权威 quorum 删除（Backend.delete_version/4 契约）：
  # 逐盘 rm_rf 版本 obj-dir 后确认 meta.json 显式 missing（本地盘恒「可达」；rm_rf 失败/残留
  # meta.json 的盘不计确认）。确认数 >= write_quorum → :ok；否则 {:error, :write_quorum}
  # （绝不在权威介质仍持有该版本时宣告删除成功）。幂等：本就缺失的盘计入确认。
  defp do_delete_version(bucket, key, version_id, opts) do
    cfg = Config.load!(opts)

    with {:ok, dirs} <- object_dirs(bucket, key, version_id, cfg) do
      confirmed =
        Enum.count(dirs, fn dir ->
          _ = File.rm_rf(dir)
          not File.regular?(Path.join(dir, @meta_file))
        end)

      if confirmed >= cfg.write_quorum do
        :ok
      else
        Logger.error("erasure delete_version below write quorum",
          bucket: bucket,
          key: key,
          reason:
            "confirmed=#{confirmed} < write_quorum=#{cfg.write_quorum} version_id=#{version_id}"
        )

        {:error, :write_quorum}
      end
    end
  end

  defp do_put_bucket(bucket, opts) do
    cfg = Config.load!(opts)
    Enum.each(cfg.drives, fn d -> File.mkdir_p!(Path.join(d, bucket)) end)
    :ok
  end

  defp do_delete_bucket(bucket, opts) do
    cfg = Config.load!(opts)

    Enum.each(cfg.drives, fn d ->
      case File.rmdir(Path.join(d, bucket)) do
        :ok -> :ok
        {:error, :enoent} -> :ok
        # 其余盘上非空/出错忽略（与 FS 单盘 rmdir 语义对齐：仅删空目录）
        {:error, _} -> :ok
      end
    end)

    :ok
  end

  # ── 辅助 ──

  defp read_any_sidecar(dirs) do
    Enum.find_value(dirs, {:error, :enoent}, fn dir ->
      case File.read(Path.join(dir, @meta_file)) do
        {:ok, bin} -> {:ok, Meta.decode!(bin)}
        {:error, _} -> nil
      end
    end)
  end

  defp open_write!(path) do
    {:ok, fd} = File.open(path, [:write, :binary, :raw])
    fd
  end
end
