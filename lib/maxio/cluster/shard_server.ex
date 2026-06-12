defmodule Maxio.Cluster.ShardServer do
  @moduledoc """
  每节点一个的本机分片 IO 服务（named GenServer，M7）。对外被 :erpc 寻址到「正确的节点」，
  对内只操作「本机一个 drive 路径」。复用 M6 ErasureCoded 的 part.0 偏移寻址（j * shard_len）
  + per-block BLAKE3 sidecar 读写 + heal pwrite 语义，只是 drive_obj_dir 由调用方显式传入
  （不再从 cfg.drives 列表枚举——因为「哪个盘」已由 Topology 的端点决定，「哪个节点」已由 :erpc 决定）。

  铁律 4：put_shard/get_shard 逐块有界（一次一个 ~block_size/K 的分片），绝不一次传整对象/整文件。
  这些函数是「本机执行」纯操作，可直接被 :erpc 调用；GenServer 仅为命名锚点 + 限流/fd 缓存演进位。

  ## 原子提交原语（ROUTE B B1-2）

  写路径不再「就地」覆盖 final obj-dir 的 part.0/meta.json（crash 在分片写与 sidecar 写之间留撕裂
  对象，且就地覆盖对并发读者非原子，更无 fsync = write-quorum 在掉电下是耐久谎言）。改为
  **temp-dir + 原子 rename + fsync-before-quorum**：

    * `begin_tmp/1`：在 `<drive_root>/.tmp/<uuid>` 建空 temp obj-dir（与 final 同 drive 卷 -> rename 原子）。
      调用方随后用既有 `put_shard/4`、`put_sidecar/2` 把 part.0 / meta.json 逐块流式写进 **temp**。
    * `commit/3`：fsync temp part.0 + temp meta.json -> 原子 rename part.0 到 final
      （**数据先于元数据**，对齐 MinIO PR #10734）-> fsync final 目录 -> 原子 rename meta.json
      到 final -> fsync final 目录 -> 删 temp。
      crash 在两 rename 之间：数据在、meta 旧/无（harmless，旧值或交 heal），**绝不 meta 指向不存在数据**。
    * `prepare_commit/5`：把整对象 block_map + sidecar 一次写进 temp（小对象/单测用原语；不流式）。

  Windows rename-over-open-file：`:file.rename/2` 覆盖既有 target 在 Windows 上若 reader 持文件打开会
  失败（busy）。落地：temp 与 final 同卷保证 rename 是原子重命名；rename busy -> 有界重试后
  `{:error, :rename_busy}`（调用方映射 503，绝不静默写坏，铁律 3）。fsync 目录在 Windows 上
  `:file.open` 目录可能失败 -> best-effort `:ok`（诚实文档化，对齐 MinIO Windows 行为）。
  fsync 开关由 `config :maxio, :durability, fsync:`（prod true / test false）控制；每次 `:file.sync`
  成功发 `[:maxio, :durability, :fsync]` 遥测（可观测 + 单测断言点）。
  """
  use GenServer

  alias Maxio.Cluster.{DriveIO, DriveIdentity, DriveStats}
  alias Maxio.Storage.Erasure.Meta

  @part_file "part.0"
  @meta_file "meta.json"
  @tmp_root ".tmp"
  @rename_retries 5

  def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok), do: {:ok, %{}}

  @doc "存活探针（:erpc.multicall 健康检查用）。"
  @spec ping() :: :pong
  def ping, do: :pong

  @doc """
  写对象在 drive_obj_dir 下、block_index 的单个分片字节（幂等覆盖，pwrite 偏移 j*shard_len）。
  drive_obj_dir = Path.join(drive, obj_rel)，由后端组装（端点已选定 node+drive）。
  """
  @spec put_shard(String.t(), non_neg_integer(), binary(), pos_integer()) ::
          :ok | {:error, term()}
  def put_shard(drive_obj_dir, block_index, shard_bytes, shard_len) do
    DriveIO.track(
      :write,
      fn ->
        path = Path.join(drive_obj_dir, @part_file)

        # mkdir/open 失败（:enametoolong/:eacces/盘满等）→ 结构化 {:error, posix}，绝不 raise——
        # File.mkdir_p! 的异常 message 内嵌服务器绝对盘路径，曾沿 500 InternalError 泄露给客户端。
        with :ok <- File.mkdir_p(drive_obj_dir),
             {:ok, fd} <- :file.open(String.to_charlist(path), [:read, :write, :binary, :raw]) do
          try do
            :file.pwrite(fd, block_index * shard_len, shard_bytes)
          after
            :file.close(fd)
          end
        end
      end,
      bytes: byte_size(shard_bytes)
    )
  end

  @doc "读对象在 drive_obj_dir 下、block_index 的分片字节；缺文件/缺块/短读 -> nil（交 EC 重建）。"
  @spec get_shard(String.t(), non_neg_integer(), pos_integer()) :: binary() | nil
  def get_shard(drive_obj_dir, block_index, shard_len) do
    DriveIO.track(
      :read,
      fn ->
        path = Path.join(drive_obj_dir, @part_file)

        case :file.open(String.to_charlist(path), [:read, :binary, :raw]) do
          {:ok, fd} ->
            try do
              case :file.pread(fd, block_index * shard_len, shard_len) do
                {:ok, data} when byte_size(data) == shard_len -> data
                _ -> nil
              end
            after
              :file.close(fd)
            end

          {:error, _} ->
            nil
        end
      end,
      bytes: fn
        data when is_binary(data) -> byte_size(data)
        _ -> 0
      end
    )
  end

  @doc "写该 drive 上对象的 sidecar（每端点一份；read 侧从任一存活端点恢复）。"
  @spec put_sidecar(String.t(), map()) :: :ok | {:error, term()}
  def put_sidecar(drive_obj_dir, meta) do
    meta_bin = Meta.encode(meta)

    DriveIO.track(
      :write,
      fn ->
        # 结构化错误而非 raise（同 put_shard：异常 message 内嵌盘路径，绝不泄露给客户端）。
        with :ok <- File.mkdir_p(drive_obj_dir) do
          File.write(Path.join(drive_obj_dir, @meta_file), meta_bin)
        end
      end,
      bytes: byte_size(meta_bin)
    )
  end

  @doc "读该 drive 上对象的 sidecar。"
  @spec get_sidecar(String.t()) :: {:ok, map()} | {:error, :enoent}
  def get_sidecar(drive_obj_dir) do
    DriveIO.track(:read, fn ->
      case File.read(Path.join(drive_obj_dir, @meta_file)) do
        {:ok, bin} -> {:ok, Meta.decode!(bin)}
        {:error, _} -> {:error, :enoent}
      end
    end)
  end

  # 走盘 LIST 须跳过的内部前缀（ROUTE B P3）：.versions（版本树）/.uploads（multipart parts）/.tmp（原子提交临时区）。
  @internal_prefixes [".versions", ".uploads", ".tmp"]

  @doc """
  读单层目录 drive_dir 下的条目（ROUTE B P3 drive-walk LIST 原语，本机；被 :erpc 寻址，无 node 首参）。
  默认返回 `{:ok, [%{name, object?}]}`（name 升序）；object? = 该子目录内含 meta.json
  （即一个 null 版本对象目录）。默认跳过内部前缀 .versions/.uploads/.tmp 与 meta.json/part.0
  文件本身。目录不存在 -> {:ok, []}。

  `opts[:include_layout_files]` 仅给 scanner orphan-shard 取证使用：在保持内部前缀过滤的同时，
  额外返回当前目录下的 `meta.json` / `part.0` 文件条目（`type: :file`）。默认调用路径仍只看目录。
  """
  @spec list_dir(String.t(), keyword()) ::
          {:ok, [%{name: String.t(), object?: boolean()}]} | {:error, term()}
  def list_dir(drive_dir, opts \\ []) do
    DriveIO.track(:list, fn ->
      case File.ls(drive_dir) do
        {:ok, names} ->
          include_layout_files? = Keyword.get(opts, :include_layout_files, false)

          entries =
            names
            |> Enum.reject(&(&1 in @internal_prefixes))
            |> Enum.flat_map(fn n ->
              path = Path.join(drive_dir, n)

              cond do
                File.dir?(path) ->
                  [
                    %{
                      name: n,
                      object?: File.regular?(Path.join([drive_dir, n, @meta_file])),
                      type: :dir
                    }
                  ]

                include_layout_files? and n in [@meta_file, @part_file] and File.regular?(path) ->
                  [%{name: n, object?: false, type: :file}]

                true ->
                  []
              end
            end)
            |> Enum.sort_by(& &1.name)

          {:ok, entries}

        {:error, :enoent} ->
          {:ok, []}

        {:error, reason} ->
          {:error, reason}
      end
    end)
  end

  @doc "Probe a configured drive root; unlike list_dir/2, a missing root is unavailable."
  @spec probe_drive(String.t()) :: :ok | {:error, term()}
  def probe_drive(drive_root) do
    DriveIO.track(:probe, fn ->
      case File.stat(drive_root) do
        {:ok, %File.Stat{type: :directory}} -> :ok
        {:ok, _stat} -> {:error, :enotdir}
        {:error, :enoent} -> {:error, :unavailable}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  @doc "Probe a configured drive root and return its persistent software identity marker."
  @spec probe_drive_identity(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def probe_drive_identity(drive_root, opts \\ []) do
    DriveIO.track(:probe, fn -> DriveIdentity.probe_drive_root(drive_root, opts) end)
  end

  @doc "Return OS-backed filesystem capacity stats for a configured drive root."
  @spec drive_stats(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def drive_stats(drive_root, opts \\ []) do
    DriveIO.track(:metadata, fn -> DriveStats.local(drive_root, opts) end)
  end

  @doc "stat：该 drive 上 part.0 字节数（heal 用其判文件完整）。"
  @spec stat_shard(String.t()) :: {:ok, non_neg_integer()} | {:error, :enoent}
  def stat_shard(drive_obj_dir) do
    DriveIO.track(:metadata, fn ->
      case File.stat(Path.join(drive_obj_dir, @part_file)) do
        {:ok, %File.Stat{size: s}} -> {:ok, s}
        {:error, _} -> {:error, :enoent}
      end
    end)
  end

  @doc "stat：该 drive 上 part.0 字节数与 mtime（scanner orphan cleanup 安全年龄门使用）。"
  @spec stat_shard_info(String.t()) ::
          {:ok, %{size: non_neg_integer(), mtime_ms: integer()}} | {:error, :enoent}
  def stat_shard_info(drive_obj_dir) do
    DriveIO.track(:metadata, fn ->
      case File.stat(Path.join(drive_obj_dir, @part_file), time: :posix) do
        {:ok, %File.Stat{size: size, mtime: mtime}} ->
          {:ok, %{size: size, mtime_ms: mtime_ms(mtime)}}

        {:error, _} ->
          {:error, :enoent}
      end
    end)
  end

  @doc "删该 drive 上对象的整个目录（part.0 + meta.json）。幂等。"
  @spec delete_shard(String.t()) :: :ok
  def delete_shard(drive_obj_dir) do
    DriveIO.track(:delete, fn ->
      _ = File.rm_rf(drive_obj_dir)
      :ok
    end)
  end

  @doc "只删除该 drive 上对象目录里的 part.0，保留 meta.json 与子目录。幂等。"
  @spec delete_part_file(String.t()) :: :ok | {:error, term()}
  def delete_part_file(drive_obj_dir) do
    DriveIO.track(:delete, fn ->
      case File.rm(Path.join(drive_obj_dir, @part_file)) do
        :ok -> :ok
        {:error, :enoent} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  # ── 原子提交原语（ROUTE B B1-2）──

  @doc """
  建一个与 final obj-dir 同卷的 temp obj-dir：`<drive_root>/.tmp/<uuid>`。返回 {:ok, tmp_dir}。
  调用方随后用既有 put_shard/4、put_sidecar/2（drive_obj_dir 形参传 tmp_dir）把 part.0 / meta.json
  逐块流式写进 temp，最后 commit/3 原子 rename 到 final。drive_root = 端点 drive（与 final 同卷）。
  """
  @spec begin_tmp(String.t()) :: {:ok, String.t()} | {:error, term()}
  def begin_tmp(drive_root) do
    DriveIO.track(:write, fn -> do_begin_tmp(drive_root) end)
  end

  @doc """
  原子提交准备（一次写整对象，小对象/单测用原语；流式写路径用 begin_tmp + put_shard + commit）：
  整对象所有 block 分片（block_map=%{block_index=>shard_bytes}）+ sidecar 写到 `<drive_root>/.tmp/<uuid>/`，
  fsync（opts[:fsync] 缺省读 durability 配置）。返回 {:ok, tmp_dir}。drive_root 由调用方传入（端点 drive 根，
  定位同卷 .tmp 保证 rename 原子）。
  """
  @spec prepare_commit(
          String.t(),
          %{non_neg_integer() => binary()},
          pos_integer(),
          map(),
          keyword()
        ) ::
          {:ok, String.t()} | {:error, term()}
  def prepare_commit(_drive_obj_dir, block_map, shard_len, meta, opts) do
    meta_bin = Meta.encode(meta)

    bytes =
      Enum.reduce(block_map, byte_size(meta_bin), fn {_j, shard}, acc ->
        acc + byte_size(shard)
      end)

    DriveIO.track(
      :write,
      fn ->
        drive_root = Keyword.fetch!(opts, :drive_root)
        fsync? = fsync?(opts)
        {:ok, tmp} = do_begin_tmp(drive_root)

        path = Path.join(tmp, @part_file)
        {:ok, fd} = :file.open(String.to_charlist(path), [:read, :write, :binary, :raw])

        try do
          Enum.each(block_map, fn {j, shard} -> :ok = :file.pwrite(fd, j * shard_len, shard) end)
          if fsync?, do: sync_fd(fd)
        after
          :file.close(fd)
        end

        File.write!(Path.join(tmp, @meta_file), meta_bin)
        if fsync?, do: sync_path(Path.join(tmp, @meta_file))
        {:ok, tmp}
      end,
      bytes: bytes
    )
  end

  @doc """
  原子提交：temp obj-dir 的 part.0（数据先）再 meta.json（元数据后）原子 rename 到 final obj-dir。
  同卷 :file.rename 原子；MinIO PR #10734「数据先于元数据」=> crash 在两 rename 之间绝不 meta 指向
  不存在数据。每 rename 后 fsync final 目录（fsync? = opts[:fsync] 缺省读 durability 配置）。
  rename busy（target 被 reader 打开，Windows 语义）-> 有界重试后 {:error, :rename_busy}（绝不静默写坏，
  调用方映射 503）。成功删 temp。

  ROUTE B B5-0 —— `opts[:meta_only]`（缺省 false）：**显式纯元数据提交声明**。delete marker 是
  无字节版本（temp 只有 meta.json、合法无 part.0），声明 `meta_only: true` 则跳过 part.0 rename，
  只提交 meta.json（meta.json 即数据本体 → fsync 它再原子 rename + sync final 目录，fsync-before-quorum
  对 marker 同样成立）。**默认（正常对象提交）缺 part.0 仍立即 `{:error, :enoent}`**——写时早失败优于
  读时才发现撕裂（铁律 3 绝不静默把「忘写数据」当成功提交）。
  """
  @spec commit(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def commit(tmp_dir, drive_obj_dir, opts) do
    DriveIO.track(:write, fn ->
      fsync? = fsync?(opts)
      rename_fun = rename_fun(opts)
      meta_only? = Keyword.get(opts, :meta_only, false)

      src_part = Path.join(tmp_dir, @part_file)
      src_meta = Path.join(tmp_dir, @meta_file)
      if fsync? and File.exists?(src_part), do: sync_path(src_part)

      # meta.json 是对象可见性的真值源：正常对象提交也必须在暴露元数据 rename 前 fsync，
      # 否则 write_quorum 成功后掉电可能只耐久 part.0，读侧看不见对象或看见旧 sidecar。
      # meta_only（delete marker）同理，meta.json 即数据本体。
      if fsync?, do: sync_path(src_meta)

      # mkdir 失败（:enametoolong 段超 NAME_MAX / :eacces / 盘满等）→ 结构化 {:error, posix}，
      # 绝不 raise——File.mkdir_p! 的异常 message 内嵌服务器绝对盘路径，曾沿 500 InternalError
      # 序列化给客户端（信息泄露 + 违反铁律 3 结构化错误）。调用方（FS/EC/Distributed）按
      # 既有 {:error, reason} 分支回滚 temp。
      with :ok <- File.mkdir_p(drive_obj_dir),
           :ok <- commit_part(meta_only?, rename_fun, src_part, drive_obj_dir),
           :ok <- maybe_sync_dir(fsync?, drive_obj_dir),
           :ok <- rename_atomic(rename_fun, src_meta, Path.join(drive_obj_dir, @meta_file)),
           :ok <- maybe_sync_dir(fsync?, drive_obj_dir) do
        _ = File.rm_rf(tmp_dir)
        :ok
      end
    end)
  end

  # part.0 提交步：meta_only（纯元数据版本，B5-0 delete marker）显式跳过——temp 无 part.0 合法；
  # 默认必须 rename，缺 src 由 :file.rename 的 {:error, :enoent} 立即失败（绝不静默）。
  defp commit_part(true, _rename_fun, _src_part, _final_dir), do: :ok

  defp commit_part(false, rename_fun, src_part, final_dir),
    do: rename_atomic(rename_fun, src_part, Path.join(final_dir, @part_file))

  @doc """
  单文件原子提交（FS 后端用：对象是单个文件而非 obj-dir）：fsync src 文件 -> 原子 rename 覆盖到
  dst（同卷保证原子）-> fsync dst 所在目录。rename busy -> 有界重试后 {:error, :rename_busy}。
  """
  @spec commit_file(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def commit_file(src, dst, opts) do
    bytes =
      case File.stat(src) do
        {:ok, %File.Stat{size: size}} -> size
        {:error, _} -> 0
      end

    DriveIO.track(
      :write,
      fn ->
        fsync? = fsync?(opts)
        rename_fun = rename_fun(opts)
        if fsync? and File.exists?(src), do: sync_path(src)

        with :ok <- File.mkdir_p(Path.dirname(dst)),
             :ok <- rename_atomic(rename_fun, src, dst),
             :ok <- maybe_sync_dir(fsync?, Path.dirname(dst)) do
          :ok
        end
      end,
      bytes: bytes
    )
  end

  defp do_begin_tmp(drive_root) do
    tmp = Path.join([drive_root, @tmp_root, uuid()])

    case File.mkdir_p(tmp) do
      :ok -> {:ok, tmp}
      {:error, reason} -> {:error, reason}
    end
  end

  # opts[:fsync] 显式覆盖；否则读 config :maxio, :durability, fsync:（prod true / test false）。
  defp fsync?(opts) do
    case Keyword.fetch(opts, :fsync) do
      {:ok, v} -> v
      :error -> Application.get_env(:maxio, :durability, [])[:fsync] || false
    end
  end

  # rename 注入点（缺省 :file.rename/2）。耐久性测试经此注入 busy 错误，确定性验证有界重试 ->
  # :rename_busy 映射（与 :transport/:topology/:drives 同款 opts 依赖注入，绝非 prod 旁路）。
  defp rename_fun(opts) do
    Keyword.get(opts, :rename_fun, fn src, dst ->
      :file.rename(String.to_charlist(src), String.to_charlist(dst))
    end)
  end

  defp uuid, do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)

  defp rename_atomic(rename_fun, src, dst),
    do: rename_atomic(rename_fun, src, dst, @rename_retries)

  defp rename_atomic(rename_fun, src, dst, 0) do
    case rename_fun.(src, dst) do
      :ok -> :ok
      {:error, reason} when reason in [:eacces, :eexist, :ebusy] -> {:error, :rename_busy}
      {:error, _} = err -> err
    end
  end

  defp rename_atomic(rename_fun, src, dst, n) do
    case rename_fun.(src, dst) do
      :ok ->
        :ok

      {:error, reason} when reason in [:eacces, :eexist, :ebusy] ->
        rename_atomic(rename_fun, src, dst, n - 1)

      {:error, _} = err ->
        err
    end
  end

  defp maybe_sync_dir(false, _dir), do: :ok
  defp maybe_sync_dir(true, dir), do: sync_dir(dir)

  # fsync 一个已打开的文件 fd（提交前确保 part.0 字节落盘）。
  defp sync_fd(fd) do
    case :file.sync(fd) do
      :ok ->
        emit_fsync(:file)
        :ok

      {:error, _} ->
        :ok
    end
  end

  # 打开路径短持 + fsync（part.0 文件/meta.json 文件落盘）。
  defp sync_path(path) do
    case :file.open(String.to_charlist(path), [:read, :write, :binary, :raw]) do
      {:ok, fd} ->
        _ = sync_fd(fd)
        :file.close(fd)
        :ok

      {:error, _} ->
        :ok
    end
  end

  # fsync 目录 fd（POSIX：open dir + fsync；Windows：open 目录可能失败 -> best-effort :ok）。
  defp sync_dir(dir) do
    case :file.open(String.to_charlist(dir), [:read, :raw]) do
      {:ok, fd} ->
        case :file.sync(fd) do
          :ok -> emit_fsync(:dir)
          {:error, _} -> :ok
        end

        :file.close(fd)
        :ok

      {:error, _} ->
        :ok
    end
  end

  # 每次 fsync 成功发遥测（可观测 + 单测断言点）。
  defp emit_fsync(kind) do
    :telemetry.execute([:maxio, :durability, :fsync], %{count: 1}, %{kind: kind})
    :ok
  end

  @doc """
  heal：把 block_map（%{block_index => shard_bytes}）回写该 drive 的 part.0（缺文件先补零到
  shard_file_size 再 pwrite）+ 重写 sidecar。返回 {:ok, 回写块数}。
  与 M6 Heal.apply_fixes/5 的单盘语义逐字一致。
  """
  @spec heal_shard(String.t(), %{non_neg_integer() => binary()}, pos_integer(), map()) ::
          {:ok, non_neg_integer()}
  def heal_shard(drive_obj_dir, block_map, shard_len, meta) do
    meta_bin = Meta.encode(meta)

    bytes =
      Enum.reduce(block_map, byte_size(meta_bin), fn {_j, shard}, acc ->
        acc + byte_size(shard)
      end)

    DriveIO.track(
      :write,
      fn ->
        File.mkdir_p!(drive_obj_dir)
        path = Path.join(drive_obj_dir, @part_file)
        ensure_part_file!(path, meta, drive_obj_dir, shard_len)
        {:ok, fd} = :file.open(String.to_charlist(path), [:read, :write, :binary, :raw])

        try do
          Enum.each(block_map, fn {j, shard} -> :ok = :file.pwrite(fd, j * shard_len, shard) end)
        after
          :file.close(fd)
        end

        File.write!(Path.join(drive_obj_dir, @meta_file), meta_bin)
        {:ok, map_size(block_map)}
      end,
      bytes: bytes
    )
  end

  # 整列缺失时先确保 part.0 存在；:raw 文件 pwrite 到偏移会自动以 0 填充空洞（POSIX/Windows 均如此），
  # 故只需保证文件存在，后续 pwrite 各偏移即可（最后一块 pwrite 决定文件长度，中间块空洞补零）。
  defp ensure_part_file!(path, _meta, _dir, shard_len) do
    case File.stat(path) do
      {:ok, _} ->
        :ok

      {:error, _} ->
        {:ok, fd} = :file.open(String.to_charlist(path), [:write, :binary, :raw])

        # 至少建空文件；具体偏移由后续 pwrite 拉伸（:raw 文件 pwrite 自动补零）。
        :file.close(fd)
        _ = shard_len
        :ok
    end
  end

  defp mtime_ms(mtime) when is_integer(mtime), do: mtime * 1_000

  defp mtime_ms({{year, month, day}, {hour, minute, second}}) do
    {:ok, date} = Date.new(year, month, day)
    {:ok, time} = Time.new(hour, minute, second)
    {:ok, datetime} = DateTime.new(date, time)
    DateTime.to_unix(datetime, :millisecond)
  end
end
