defmodule Maxio.Storage.Erasure.Heal do
  @moduledoc """
  纠删码自愈：检测缺失/损坏分片（校验和不匹配或文件缺失），从 K 个存活分片 RS 重建、回写坏分片 +
  修复其 sidecar 副本。坏分片数 > M（存活 < K）-> 不可恢复，返回 {:error, :unrecoverable} +
  结构化错误日志（铁律 3：绝不伪造数据）。结构化日志含 bucket/key/version_id/drive/block/result（铁律 4）。

  heal 粒度到整对象（重建该对象所有坏分片）；scrub 全扫桶/全盘（MinIO 式 1/1024 采样 + 限流 defer M7）。
  """
  require Logger

  alias Maxio.Storage.Erasure.{Codec, Config, Meta}

  @part_file "part.0"
  @meta_file "meta.json"

  @doc """
  heal 单个对象版本：检测+重建坏分片。返回 {:ok, %{healed: n}}（n=回写的坏分片数）或
  {:error, :unrecoverable}（某 block 存活 < K）/ {:error, :enoent}（无任何 sidecar）。
  """
  @spec heal_object(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, %{healed: non_neg_integer()}} | {:error, :unrecoverable | :enoent}
  def heal_object(bucket, key, version_id \\ "null", opts \\ []) do
    cfg = Config.load!(opts)
    dirs = object_dirs(bucket, key, version_id, cfg)

    case read_any_sidecar(dirs) do
      {:error, :enoent} ->
        {:error, :enoent}

      {:ok, meta} ->
        do_heal(cfg, bucket, key, version_id, dirs, meta)
    end
  end

  defp do_heal(cfg, bucket, key, version_id, dirs, meta) do
    n = Config.total(cfg)
    size = meta["size"]
    block_size = get_in(meta, ["ec", "block_size"]) || cfg.block_size
    shard_len = block_shard_len(meta, cfg)
    num_blocks = if size == 0, do: 0, else: div(size + block_size - 1, block_size)

    # 打开各盘 part.0 读句柄（缺失 -> nil）。
    read_fds =
      Enum.map(dirs, fn dir ->
        case :file.open(String.to_charlist(Path.join(dir, @part_file)), [:read, :binary, :raw]) do
          {:ok, fd} -> fd
          {:error, _} -> nil
        end
      end)

    try do
      # 逐 block 收集每盘是否需修复的分片字节。
      result =
        Enum.reduce_while(0..max(num_blocks - 1, 0), {:ok, %{}}, fn j, {:ok, fixes} ->
          heal_block(
            cfg,
            bucket,
            key,
            version_id,
            meta,
            read_fds,
            n,
            size,
            block_size,
            shard_len,
            j,
            fixes,
            num_blocks
          )
        end)

      case result do
        {:error, :unrecoverable} ->
          Logger.error("erasure heal unrecoverable",
            bucket: bucket,
            key: key,
            reason: "block survivors < K"
          )

          {:error, :unrecoverable}

        {:ok, fixes} ->
          healed = apply_fixes(cfg, dirs, meta, shard_len, fixes)
          {:ok, %{healed: healed}}
      end
    after
      Enum.each(read_fds, fn fd -> if fd, do: :file.close(fd) end)
    end
  end

  # fixes: %{drive_index => %{block_index => shard_bytes}}（需回写的分片）。
  defp heal_block(
         cfg,
         bucket,
         key,
         version_id,
         meta,
         read_fds,
         n,
         size,
         block_size,
         shard_len,
         j,
         fixes,
         num_blocks
       ) do
    # 空对象（num_blocks == 0）无任何 block 需检测。
    if num_blocks == 0 do
      {:cont, {:ok, fixes}}
    else
      do_heal_block(
        cfg,
        bucket,
        key,
        version_id,
        meta,
        read_fds,
        n,
        size,
        block_size,
        shard_len,
        j,
        fixes
      )
    end
  end

  defp do_heal_block(
         cfg,
         bucket,
         key,
         version_id,
         meta,
         read_fds,
         n,
         size,
         block_size,
         shard_len,
         j,
         fixes
       ) do
    shards_meta = meta["shards"]

    read_shards =
      read_fds
      |> Enum.with_index()
      |> Enum.map(fn {fd, i} -> read_shard(fd, j, shard_len, shards_meta, i) end)

    checksums = block_checksums(shards_meta, n, j)

    # 哪些盘的分片坏了（校验不过）。
    bad =
      0..(n - 1)
      |> Enum.filter(fn i ->
        not Codec.verify_shard(Enum.at(read_shards, i), Enum.at(checksums, i))
      end)

    cond do
      bad == [] ->
        {:cont, {:ok, fixes}}

      length(bad) > cfg.parity_shards ->
        Logger.error("erasure heal block unrecoverable",
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

        # 重新编码须在与 PUT 完全一致的固定 block_size 填充语境下进行（保证 shard_len 与 sidecar 一致）。
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
            drive_map = Map.get(acc, i, %{})
            Map.put(acc, i, Map.put(drive_map, j, shard))
          end)

        Logger.info("erasure heal block repaired",
          bucket: bucket,
          key: key,
          reason: "block=#{j} repaired_drives=#{inspect(bad)}"
        )

        {:cont, {:ok, fixes}}
    end
  end

  # 把 fixes 回写到各盘 part.0（缺整文件先重建整列），并重写该盘 sidecar 副本。返回回写分片数。
  defp apply_fixes(_cfg, dirs, meta, shard_len, fixes) do
    bin = Meta.encode(meta)

    Enum.reduce(fixes, 0, fn {drive_index, block_map}, count ->
      dir = Enum.at(dirs, drive_index)
      File.mkdir_p!(dir)
      part = Path.join(dir, @part_file)

      # 整列缺失时先确保文件存在且达 shard_file_size（用 0 占位，随后 pwrite 覆盖）。
      ensure_part_file!(part, meta, drive_index, shard_len)

      {:ok, fd} = :file.open(String.to_charlist(part), [:read, :write, :binary, :raw])

      try do
        Enum.each(block_map, fn {j, shard} ->
          :ok = :file.pwrite(fd, j * shard_len, shard)
        end)
      after
        :file.close(fd)
      end

      # 修复该盘 sidecar 副本（用 leader sidecar 内容，保证全盘一致）。
      File.write!(Path.join(dir, @meta_file), bin)
      count + map_size(block_map)
    end)
  end

  # 确保 part.0 存在且长度 = 该盘 shard_file_size（缺则补零，便于 pwrite 各 block 偏移）。
  defp ensure_part_file!(part, meta, drive_index, shard_len) do
    drive_meta = Enum.at(meta["shards"], drive_index)
    raw_target = (drive_meta && drive_meta["shard_file_size"]) || 0

    target =
      if raw_target > 0,
        do: raw_target,
        else: length((drive_meta && drive_meta["block_hashes"]) || []) * shard_len

    cur =
      case File.stat(part) do
        {:ok, %File.Stat{size: s}} -> s
        {:error, _} -> 0
      end

    if cur == target do
      :ok
    else
      # 写到目标长度（截断或补零）。
      {:ok, fd} = :file.open(String.to_charlist(part), [:write, :binary, :raw])

      try do
        if target > 0, do: :ok = :file.pwrite(fd, target - 1, <<0>>)
      after
        :file.close(fd)
      end
    end
  end

  @doc """
  scrub 整桶：遍历桶内全部对象（去重 N 盘副本），逐个 heal。
  返回 {:ok, %{scanned, healed_objects, unrecoverable}}。
  """
  @spec scrub_bucket(String.t(), keyword()) ::
          {:ok,
           %{
             scanned: non_neg_integer(),
             healed_objects: non_neg_integer(),
             unrecoverable: non_neg_integer()
           }}
  def scrub_bucket(bucket, opts \\ []) do
    cfg = Config.load!(opts)
    objects = list_objects(cfg, bucket)

    {scanned, healed, unrec} =
      Enum.reduce(objects, {0, 0, 0}, fn {key, version_id}, {sc, hl, ur} ->
        case heal_object(bucket, key, version_id, opts) do
          {:ok, %{healed: n}} when n > 0 -> {sc + 1, hl + 1, ur}
          {:ok, _} -> {sc + 1, hl, ur}
          {:error, :unrecoverable} -> {sc + 1, hl, ur + 1}
          {:error, :enoent} -> {sc + 1, hl, ur}
        end
      end)

    Logger.info("erasure scrub bucket done",
      bucket: bucket,
      reason: "scanned=#{scanned} healed=#{healed} unrecoverable=#{unrec}"
    )

    {:ok, %{scanned: scanned, healed_objects: healed, unrecoverable: unrec}}
  end

  @doc "scrub 全部盘上全部桶。"
  @spec scrub_all(keyword()) :: {:ok, map()}
  def scrub_all(opts \\ []) do
    cfg = Config.load!(opts)

    buckets =
      cfg.drives
      |> Enum.flat_map(fn d ->
        case File.ls(d) do
          {:ok, entries} -> entries
          {:error, _} -> []
        end
      end)
      |> Enum.reject(&(&1 in [".uploads", ".versions"]))
      |> Enum.uniq()

    results = Enum.map(buckets, fn b -> {b, scrub_bucket(b, opts)} end)
    {:ok, %{buckets: results}}
  end

  # 列桶内对象 {key, version_id}（扫描所有盘并集，去重）。识别含 meta.json 的目录为对象。
  defp list_objects(cfg, bucket) do
    cfg.drives
    |> Enum.flat_map(fn d ->
      null_objs = scan_dir_for_objects(Path.join(d, bucket))
      versions_root = Path.join([d, ".versions", bucket])
      ver_objs = scan_versioned(versions_root)
      null_objs ++ ver_objs
    end)
    |> Enum.uniq()
  end

  # 递归找含 meta.json 的目录；返回 {key, "null"}（key = 相对 bucket 根的路径）。
  defp scan_dir_for_objects(root) do
    if File.dir?(root) do
      do_scan(root, root, "null")
    else
      []
    end
  end

  defp do_scan(base, dir, vid) do
    entries =
      case File.ls(dir) do
        {:ok, es} -> es
        {:error, _} -> []
      end

    if @meta_file in entries do
      key = dir |> Path.relative_to(base) |> to_unix()
      [{key, vid}]
    else
      Enum.flat_map(entries, fn e ->
        sub = Path.join(dir, e)
        if File.dir?(sub), do: do_scan(base, sub, vid), else: []
      end)
    end
  end

  # 版本化对象：.versions/<bucket>/<key...>/<version_id> 目录含 meta.json。
  defp scan_versioned(root) do
    if File.dir?(root) do
      do_scan_versioned(root, root)
    else
      []
    end
  end

  defp do_scan_versioned(base, dir) do
    entries =
      case File.ls(dir) do
        {:ok, es} -> es
        {:error, _} -> []
      end

    if @meta_file in entries do
      rel = dir |> Path.relative_to(base) |> to_unix()
      # rel 形如 "<key...>/<version_id>"；拆出末段为 version_id。
      segs = String.split(rel, "/")
      {key_segs, [vid]} = Enum.split(segs, length(segs) - 1)
      [{Enum.join(key_segs, "/"), vid}]
    else
      Enum.flat_map(entries, fn e ->
        sub = Path.join(dir, e)
        if File.dir?(sub), do: do_scan_versioned(base, sub), else: []
      end)
    end
  end

  defp to_unix(path), do: String.replace(path, "\\", "/")

  # ── 与 ErasureCoded 私有逻辑等价的本地辅助（heal 独立模块，避免暴露后端私有）──

  defp object_dirs(bucket, key, version_id, cfg) do
    {:ok, rel} = safe_relative(key)

    sub =
      if version_id == "null",
        do: Path.join([bucket, rel]),
        else: Path.join([".versions", bucket, rel, version_id])

    Enum.map(cfg.drives, &Path.join(&1, sub))
  end

  defp safe_relative(key) do
    segments = key |> String.split("/", trim: true)

    if key == "" or Enum.any?(segments, &(&1 in ["..", "."])),
      do: :error,
      else: {:ok, Path.join(segments)}
  end

  defp read_any_sidecar(dirs) do
    Enum.find_value(dirs, {:error, :enoent}, fn dir ->
      case File.read(Path.join(dir, @meta_file)) do
        {:ok, bin} -> {:ok, Meta.decode!(bin)}
        {:error, _} -> nil
      end
    end)
  end

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

      if is_list(bh) and length(bh) > 0 and s["shard_file_size"] > 0,
        do: div(s["shard_file_size"], length(bh))
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
