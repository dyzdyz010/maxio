defmodule Maxio.Storage.FS do
  @moduledoc """
  单机文件系统存储后端。ROUTE B B6-1 起对象落 **obj-dir 布局**（与 ErasureCoded/Distributed
  同构，铁律 2 单一布局语义）：

    * null 版本：`<data_dir>/<bucket>/<encoded-key>/{part.0, meta.json}`
    * 版本化：`<data_dir>/.versions/<bucket>/<encoded-key>/<version_id>/{part.0, meta.json}`

  `part.0` 为对象完整字节（FS 单盘无纠删，无填充——文件长度即对象 size）；`meta.json` 为
  maxio/2 sidecar（v1 core `size/etag/sha256` 经 `Maxio.Sidecar.migrate_v1/2` 携 versions 数组，
  富元数据从 `opts[:object_meta]` 取——FS 从此不再忽略 object_meta），与 EC/Distributed 的
  sidecar 同构，使 ObjectMeta/Listing/Scanner 经合成单端点 topology 逐字复用（B6-2）。

  key → 盘段编码经 `Maxio.Cluster.Paths.encode_key/1`（空段/尾斜杠/布局保留名段无碰撞落盘，
  单一事实来源）。put 流式写入并边写边算 MD5/SHA256（绝不全缓冲，铁律 4）；get 支持 Range，
  按区间用 :file.pread 分块发出；防 `..` 路径穿越。

  写路径（put/assemble/put_delete_marker）经 **temp obj-dir + 原子 rename + fsync**
  （`ShardServer.begin_tmp/1` + `ShardServer.commit/3`，B1-2 原语：数据先于元数据 rename，
  crash 在两 rename 之间绝不 meta 指向不存在数据）。rename busy（Windows reader 持文件打开）
  -> 有界重试后 {:error, :rename_busy}（铁律 3）。fsync 开关由 `config :maxio, :durability, fsync:` 控制。

  ## 旧单文件布局读回退（B6-1 兼容；P7 B7-1 backfill 收尾迁移）

  B6-1 之前 FS 对象 = 裸单文件（路径与 obj-dir 同名互斥）。get/stat（含 copy 源读，经同一
  do_get）先探 obj-dir 的 part.0，miss 则回退旧单文件路径——命中**必记**结构化日志
  `action: :legacy_layout_read`（绝不静默）；delete 双布局清理；put/assemble/put_delete_marker
  覆盖旧布局对象时先摘除旧文件（`action: :legacy_layout_replace` 日志；文件→目录无原子转换，
  rm 与 commit 之间存在极窄 crash 窗口，S3 PUT 替换语义下旧字节本就被替换，诚实文档化）。

  每个回调额外接受可选末参 `opts`（`:data_dir` 覆盖根目录，便于测试隔离），
  缺省时从 `config :maxio, :s3, :data_dir` 读取。
  """
  @behaviour Maxio.Storage.Backend

  require Logger

  alias Maxio.Cluster.{Paths, ShardServer}
  alias Maxio.Sidecar
  alias Maxio.Storage.DeleteMarker

  @chunk_size 1_048_576
  @part_file "part.0"
  @meta_file "meta.json"

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

  # ── 分段上传 parts 回调（M2-4）。part 字节落在
  # <data_dir>/.uploads/<bucket>/<upload_id>/<part_number>.part（平铺布局不变，B6-1 非目标）；
  # assemble 按 part 升序拼到对象 obj-dir；abort 删整个 upload 临时目录。──

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

  # ROUTE B B6-1：delete marker 落盘（替换 B5-0 的 {:error, :not_supported}）。FS 单盘 quorum=1：
  # 唯一副本的 meta_only 原子提交成功即 :ok。与 ErasureCoded/Distributed 同源
  # （Maxio.Storage.DeleteMarker.sidecar/2 单一形态来源 + ShardServer.commit :meta_only）。
  @impl true
  def put_delete_marker(bucket, key, version_id, entry_opts \\ [], opts \\ []),
    do: do_put_delete_marker(bucket, key, version_id, entry_opts, opts)

  # ROUTE B fidelity —— DELETE ?versionId 的权威删除（Backend.delete_version/4 契约）。FS 单副本
  # 本地盘：唯一副本的删除即权威提交（无 quorum 语义）——rm 成功 / 本就不存在 → :ok（幂等）；
  # IO 错误 → {:error, term}（handler 据此绝不回 204，铁律 3 不静默）。
  @impl true
  def delete_version(bucket, key, version_id \\ "null", opts \\ []),
    do: do_delete(bucket, key, version_id, opts)

  # ── PUT：流式写 temp obj-dir（part.0 + meta.json sidecar），原子提交到 final ──

  defp do_put(bucket, key, version_id, chunks, opts) do
    with {:ok, final_dir} <- object_path(bucket, key, version_id, opts) do
      # B1-2 原子提交：同卷 .tmp temp obj-dir 内流式写 part.0，流尾写 maxio/2 sidecar（meta.json），
      # 数据先于元数据原子 rename 到 final（crash 前 final 保旧值/缺失）。
      {:ok, tmp} = ShardServer.begin_tmp(data_dir(opts))
      {:ok, fd} = File.open(Path.join(tmp, @part_file), [:write, :binary, :raw])

      {etag, sha256, size} =
        try do
          md5_0 = :crypto.hash_init(:md5)
          sha_0 = :crypto.hash_init(:sha256)

          {md5_ctx, sha_ctx, size} =
            Enum.reduce(chunks, {md5_0, sha_0, 0}, fn chunk, {m, s, acc} ->
              :ok = IO.binwrite(fd, chunk)

              {:crypto.hash_update(m, chunk), :crypto.hash_update(s, chunk),
               acc + byte_size(chunk)}
            end)

          etag = md5_ctx |> :crypto.hash_final() |> Base.encode16(case: :lower)
          sha256 = sha_ctx |> :crypto.hash_final() |> Base.encode16(case: :lower)
          {etag, sha256, size}
        after
          File.close(fd)
        end

      meta = build_meta(version_id, opts, size, etag, sha256)

      case ShardServer.put_sidecar(tmp, meta) do
        :ok ->
          commit_obj_dir(tmp, final_dir, bucket, key, version_id, opts, %{
            size: size,
            etag: etag,
            sha256: sha256
          })

        {:error, reason} ->
          _ = File.rm_rf(tmp)
          {:error, reason}
      end
    end
  end

  # ── GET / STAT：先 obj-dir（part.0），miss 回退旧单文件布局（命中必记日志，绝不静默）──

  defp do_get(bucket, key, version_id, range, opts) do
    with {:ok, dir} <- object_path(bucket, key, version_id, opts) do
      part = Path.join(dir, @part_file)

      case File.stat(part) do
        {:ok, %File.Stat{size: total}} ->
          {:ok, stream_file(part, range, total)}

        {:error, _} ->
          with {:ok, total} <- legacy_stat(dir, bucket, key, version_id) do
            {:ok, stream_file(dir, range, total)}
          end
      end
    end
  end

  defp do_stat(bucket, key, version_id, opts) do
    with {:ok, dir} <- object_path(bucket, key, version_id, opts) do
      case File.stat(Path.join(dir, @part_file)) do
        {:ok, %File.Stat{size: size}} ->
          {:ok, %{size: size}}

        {:error, _} ->
          with {:ok, size} <- legacy_stat(dir, bucket, key, version_id) do
            {:ok, %{size: size}}
          end
      end
    end
  end

  # ── DELETE：双布局清理。obj-dir 只摘对象布局文件 part.0/meta.json（绝不 rm_rf 整目录——
  # FS 单树上对象 "a" 的 obj-dir 同时是更深 key "a/b" 的命名空间父目录，rm_rf 会踩踏兄弟对象
  # 字节）；空目录 best-effort rmdir 收尾。旧单文件布局直接 rm。幂等（本就不存在 → :ok）。──

  defp do_delete(bucket, key, version_id, opts) do
    with {:ok, dir} <- object_path(bucket, key, version_id, opts) do
      if File.dir?(dir) do
        delete_obj_dir(dir)
      else
        # 旧单文件布局（或不存在，幂等 :ok）。
        rm_ok(dir)
      end
    end
  end

  defp delete_obj_dir(dir) do
    with :ok <- rm_ok(Path.join(dir, @part_file)),
         :ok <- rm_ok(Path.join(dir, @meta_file)) do
      # 仅当目录已空（无更深 key 的子目录）才删得掉；非空失败即忽略（目录此后只是命名空间前缀）。
      _ = File.rmdir(dir)
      :ok
    end
  end

  defp rm_ok(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_put_bucket(bucket, opts) do
    File.mkdir_p!(bucket_path(bucket, opts))
    :ok
  end

  defp do_delete_bucket(bucket, opts) do
    case File.rmdir(bucket_path(bucket, opts)) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_put_part(bucket, key, upload_id, part_number, chunks, opts) do
    with {:ok, _obj} <- object_path(bucket, key, "null", opts) do
      path = part_path(bucket, upload_id, part_number, opts)
      File.mkdir_p!(Path.dirname(path))
      {:ok, fd} = File.open(path, [:write, :binary, :raw])

      try do
        ctx0 = :crypto.hash_init(:md5)

        {ctx, size} =
          Enum.reduce(chunks, {ctx0, 0}, fn chunk, {ctx, acc} ->
            :ok = IO.binwrite(fd, chunk)
            {:crypto.hash_update(ctx, chunk), acc + byte_size(chunk)}
          end)

        md5_raw = :crypto.hash_final(ctx)
        etag = Base.encode16(md5_raw, case: :lower)
        {:ok, %{size: size, etag: etag, md5_raw: md5_raw}}
      after
        File.close(fd)
      end
    end
  end

  defp do_get_part_stream(bucket, key, upload_id, part_number, opts) do
    with {:ok, _obj} <- object_path(bucket, key, "null", opts) do
      path = part_path(bucket, upload_id, part_number, opts)

      case File.stat(path) do
        {:ok, %File.Stat{size: total}} -> {:ok, stream_file(path, nil, total)}
        {:error, :enoent} -> {:error, :enoent}
      end
    end
  end

  # ── ASSEMBLE：逐 part 流式拼进 temp obj-dir 的 part.0（边拷边算 etag/sha256），流尾写
  # maxio/2 sidecar，原子提交到 null 布局 final（与 EC do_assemble 同语义：assemble 透传
  # opts[:object_meta]，sidecar 自描述真实 content_type/user_metadata，B4-6 D1）。──

  defp do_assemble(bucket, key, upload_id, part_numbers, opts) do
    with {:ok, final_dir} <- object_path(bucket, key, "null", opts) do
      {:ok, tmp} = ShardServer.begin_tmp(data_dir(opts))
      {:ok, out} = File.open(Path.join(tmp, @part_file), [:write, :binary, :raw])

      {etag, sha256, size} =
        try do
          acc0 = {:crypto.hash_init(:md5), :crypto.hash_init(:sha256), 0}

          {md5_ctx, sha_ctx, size} =
            Enum.reduce(part_numbers, acc0, fn pn, acc ->
              path = part_path(bucket, upload_id, pn, opts)
              {:ok, in_fd} = :file.open(String.to_charlist(path), [:read, :binary, :raw])

              try do
                copy_fd(in_fd, out, acc)
              after
                :file.close(in_fd)
              end
            end)

          {md5_ctx |> :crypto.hash_final() |> Base.encode16(case: :lower),
           sha_ctx |> :crypto.hash_final() |> Base.encode16(case: :lower), size}
        after
          File.close(out)
        end

      meta = build_meta("null", opts, size, etag, sha256)

      case ShardServer.put_sidecar(tmp, meta) do
        :ok ->
          commit_obj_dir(tmp, final_dir, bucket, key, "null", opts, %{size: size})

        {:error, reason} ->
          _ = File.rm_rf(tmp)
          {:error, reason}
      end
    end
  end

  defp do_abort_upload(bucket, _key, upload_id, opts) do
    dir = upload_dir(bucket, upload_id, opts)
    _ = File.rm_rf(dir)
    :ok
  end

  # ── delete marker 落盘（ROUTE B B6-1）：temp obj-dir 只写 marker sidecar（无 part.0，合法），
  # ShardServer.commit :meta_only 原子 rename meta.json 覆盖 final（Suspended 的 null「替换」语义
  # 天然由该 rename 完成，与 Distributed/EC 对齐）。quorum=1：单盘提交成功即 :ok。
  # B5-3 R2 不变式：pre-commit 绝不破坏 final（失败只清 temp）；quorum 成功后 best-effort GC
  # final 里被替换 null 版本的孤儿 part.0（delete marker 无字节，其版本目录里任何 part.0 定义上
  # 都是孤儿）。──

  defp do_put_delete_marker(bucket, key, version_id, entry_opts, opts) do
    with {:ok, final_dir} <- object_path(bucket, key, version_id, opts),
         {:ok, tmp} <- ShardServer.begin_tmp(data_dir(opts)) do
      meta = DeleteMarker.sidecar(version_id, entry_opts)

      case ShardServer.put_sidecar(tmp, meta) do
        :ok -> commit_marker(tmp, final_dir, bucket, key, version_id, opts)
        {:error, reason} -> marker_failed(tmp, bucket, key, reason)
      end
    end
  end

  defp commit_marker(tmp, final_dir, bucket, key, version_id, opts) do
    # 旧单文件布局的 null 对象与 obj-dir 同路径互斥：marker 落点被旧文件占据时先摘除
    # （文件→目录无原子转换；Suspended marker 本就替换 null 版本，rm 语义正确，日志留痕）。
    with :ok <- clear_legacy_file(final_dir, bucket, key, version_id),
         :ok <-
           ShardServer.commit(
             tmp,
             final_dir,
             Keyword.take(opts, [:fsync]) ++ [meta_only: true]
           ) do
      _ = File.rm(Path.join(final_dir, @part_file))
      :ok
    else
      {:error, reason} -> marker_failed(tmp, bucket, key, reason)
    end
  end

  # marker 提交失败：只清 temp，绝不触碰 final（B5-3 R2——替换式提交失败回滚删 final 会摧毁
  # 被替换的旧 null 版本，制造裸 404 窗口）。Logger.error 留痕（铁律 3 不静默）。
  defp marker_failed(tmp, bucket, key, reason) do
    Logger.error("fs put_delete_marker failed",
      action: :put_delete_marker,
      bucket: bucket,
      key: key,
      reason: inspect(reason)
    )

    _ = File.rm_rf(tmp)
    {:error, structured_reason(reason)}
  end

  # ── obj-dir 原子提交（do_put/do_assemble 共用）──

  defp commit_obj_dir(tmp, final_dir, bucket, key, version_id, opts, result) do
    with :ok <- clear_legacy_file(final_dir, bucket, key, version_id),
         :ok <- ShardServer.commit(tmp, final_dir, Keyword.take(opts, [:fsync])) do
      {:ok, result}
    else
      {:error, reason} ->
        _ = File.rm_rf(tmp)
        {:error, structured_reason(reason)}
    end
  end

  # OS 报路径段超 NAME_MAX（:enametoolong）→ 结构化 :key_too_long（handler 映射 400
  # KeyTooLongError），对齐 MinIO toObjectErr：errFileNameTooLong → ObjectNameTooLong →
  # ErrKeyTooLongError（cmd/xl-storage.go checkPathLength / cmd/api-errors.go）。
  # Paths.validate_key 的段长闸已在入口先行拦截；此处是后端 backstop（守卫部署前遗留的在途
  # multipart 会话等），绝不让 posix 原因冒成 500 InternalError。
  defp structured_reason(:enametoolong), do: :key_too_long
  defp structured_reason(reason), do: reason

  # 旧单文件布局对象占据 final obj-dir 路径 → 先摘除（否则 commit 的 mkdir_p 撞文件）。
  # 文件→目录无原子转换：rm 与 commit 之间存在极窄 crash 窗口（S3 PUT/marker 替换语义下
  # 旧字节本就被替换）；命中必记结构化日志（绝不静默），P7 backfill 迁移后此路径消亡。
  defp clear_legacy_file(final_dir, bucket, key, version_id) do
    if File.regular?(final_dir) do
      Logger.warning("fs legacy single-file layout object replaced by obj-dir commit",
        action: :legacy_layout_replace,
        bucket: bucket,
        key: key,
        version_id: version_id,
        path: final_dir
      )

      rm_ok(final_dir)
    else
      :ok
    end
  end

  # 旧单文件布局读回退：obj-dir 的 part.0 miss 后，对象路径本身若是常规文件即 B6-1 之前落的
  # 裸单文件对象——命中必记结构化日志 action: :legacy_layout_read（绝不静默）；目录（纯命名空间
  # 前缀 / 无 part.0 的 marker obj-dir）或不存在 → :enoent。
  defp legacy_stat(path, bucket, key, version_id) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} ->
        Logger.warning("fs legacy single-file layout read (pre-B6-1 data; P7 backfill migrates)",
          action: :legacy_layout_read,
          bucket: bucket,
          key: key,
          version_id: version_id,
          path: path
        )

        {:ok, size}

      {:ok, _stat} ->
        {:error, :enoent}

      {:error, _} ->
        {:error, :enoent}
    end
  end

  # ── sidecar 构造（ROUTE B B6-1）：v1 core 仅 size/etag/sha256（FS 单盘无 ec/shards——合法，
  # 读侧 Sidecar.latest/find_version/to_view 只依赖 versions 数组），经 Sidecar.migrate_v1/2
  # 升级为完整 maxio/2（富元数据来自 opts[:object_meta]，FS 从此不再忽略 object_meta）。──

  defp build_meta(version_id, opts, size, etag, sha256) do
    core = %{"size" => size, "etag" => etag, "sha256" => sha256}
    Sidecar.migrate_v1(core, version_opts(version_id, opts))
  end

  # 从 opts[:object_meta] 取 maxio/2 版本头字段，产出 Sidecar.migrate_v1/2 的 keyword。
  # 与 ErasureCoded/Distributed 的同名私有函数逐字一致（铁律 2 单一语义）；modtime 一次计算；
  # data_dir = version_id（方案 B 每版本独立目录）。缺字段由 migrate_v1 兜底默认。
  # :etag（B6-2a）：多段完成对象的 S3 多段 ETag（"...-N"，Multipart.complete 透传）覆盖 versions
  # entry 的 S3 可见 etag；单次 PUT 无此键（nil）→ migrate_v1 沿用 core etag。
  defp version_opts(version_id, opts) do
    om = Keyword.get(opts, :object_meta, %{})
    modtime = System.os_time(:nanosecond)

    [
      version_id: version_id,
      data_dir: version_id,
      modtime: modtime,
      etag: Map.get(om, :etag),
      content_type: Map.get(om, :content_type, "binary/octet-stream"),
      tags: Map.get(om, :tags, %{}),
      sse: Map.get(om, :sse),
      acl_canned: Map.get(om, :acl_canned, "private"),
      storage_class: Map.get(om, :storage_class, "STANDARD"),
      user_metadata: Map.get(om, :user_metadata, %{})
    ]
  end

  # 1MB 分块把 in_fd 全量拷到 out，边拷边算 MD5/SHA256（assemble 的 sidecar 需 etag/sha256，
  # 与 EC do_assemble 同语义；铁律 4 绝不全缓冲）。acc = {md5_ctx, sha_ctx, size}。
  defp copy_fd(in_fd, out, {md5, sha, size} = acc) do
    case :file.read(in_fd, @chunk_size) do
      {:ok, data} ->
        :ok = IO.binwrite(out, data)

        copy_fd(
          in_fd,
          out,
          {:crypto.hash_update(md5, data), :crypto.hash_update(sha, data), size + byte_size(data)}
        )

      :eof ->
        acc

      {:error, _} ->
        acc
    end
  end

  defp upload_dir(bucket, upload_id, opts) do
    Path.join([data_dir(opts), ".uploads", bucket, upload_id])
  end

  defp part_path(bucket, upload_id, part_number, opts) do
    Path.join(upload_dir(bucket, upload_id, opts), "#{part_number}.part")
  end

  defp stream_file(path, nil, total), do: stream_file(path, {0, max(total - 1, 0)}, total)
  defp stream_file(_path, {_first, _last}, 0), do: []

  defp stream_file(path, {first, last}, _total) do
    length = last - first + 1

    Stream.resource(
      fn ->
        {:ok, fd} = :file.open(String.to_charlist(path), [:read, :binary, :raw])
        {fd, first, length}
      end,
      fn
        {fd, _off, remaining} when remaining <= 0 ->
          {:halt, fd}

        {fd, off, remaining} ->
          to_read = min(@chunk_size, remaining)

          case :file.pread(fd, off, to_read) do
            {:ok, data} -> {[data], {fd, off + byte_size(data), remaining - byte_size(data)}}
            :eof -> {:halt, fd}
            {:error, _} -> {:halt, fd}
          end
      end,
      fn fd -> :file.close(fd) end
    )
  end

  defp data_dir(opts) do
    Keyword.get(opts, :data_dir) ||
      Application.fetch_env!(:maxio, :s3) |> Keyword.fetch!(:data_dir)
  end

  defp bucket_path(bucket, opts), do: Path.join(data_dir(opts), bucket)

  # version_id == "null"（无版本）→ obj-dir 落 <data_dir>/<bucket>/<encoded-key>/。
  # 否则落版本化 obj-dir <data_dir>/.versions/<bucket>/<encoded-key>/<version_id>/（物理隔离）。
  #
  # key → 盘段编码经 Maxio.Cluster.Paths.encode_key（单一事实来源，铁律 2）：空段（"a//b"）、
  # 尾斜杠 folder marker（"dir/"）、布局保留名段（meta.json 等）全部无碰撞落盘——绝不再
  # trim 折叠空段（"a//b" 与 "a/b"、"dir/" 与 "dir" 曾静默同路径 = 跨 key 字节覆写）。
  defp object_path(bucket, key, "null", opts) do
    case Paths.encode_key(key) do
      {:ok, rel} -> {:ok, Path.join([data_dir(opts), bucket, rel])}
      {:error, :invalid_key} -> {:error, :invalid_key}
    end
  end

  defp object_path(bucket, key, version_id, opts) do
    case Paths.encode_key(key) do
      {:ok, rel} ->
        {:ok, Path.join([data_dir(opts), ".versions", bucket, rel, version_id])}

      {:error, :invalid_key} ->
        {:error, :invalid_key}
    end
  end
end
