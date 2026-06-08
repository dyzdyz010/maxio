defmodule Maxio.Cluster.ShardServer do
  @moduledoc """
  每节点一个的本机分片 IO 服务（named GenServer，M7）。对外被 :erpc 寻址到「正确的节点」，
  对内只操作「本机一个 drive 路径」。复用 M6 ErasureCoded 的 part.0 偏移寻址（j * shard_len）
  + per-block BLAKE3 sidecar 读写 + heal pwrite 语义，只是 drive_obj_dir 由调用方显式传入
  （不再从 cfg.drives 列表枚举——因为「哪个盘」已由 Topology 的端点决定，「哪个节点」已由 :erpc 决定）。

  铁律 4：put_shard/get_shard 逐块有界（一次一个 ~block_size/K 的分片），绝不一次传整对象/整文件。
  这些函数是「本机执行」纯操作，可直接被 :erpc 调用；GenServer 仅为命名锚点 + 限流/fd 缓存演进位。
  """
  use GenServer

  alias Maxio.Storage.Erasure.Meta

  @part_file "part.0"
  @meta_file "meta.json"

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
    File.mkdir_p!(drive_obj_dir)
    path = Path.join(drive_obj_dir, @part_file)
    {:ok, fd} = :file.open(String.to_charlist(path), [:read, :write, :binary, :raw])

    try do
      :file.pwrite(fd, block_index * shard_len, shard_bytes)
    after
      :file.close(fd)
    end
  end

  @doc "读对象在 drive_obj_dir 下、block_index 的分片字节；缺文件/缺块/短读 -> nil（交 EC 重建）。"
  @spec get_shard(String.t(), non_neg_integer(), pos_integer()) :: binary() | nil
  def get_shard(drive_obj_dir, block_index, shard_len) do
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
  end

  @doc "写该 drive 上对象的 sidecar（每端点一份；read 侧从任一存活端点恢复）。"
  @spec put_sidecar(String.t(), map()) :: :ok | {:error, term()}
  def put_sidecar(drive_obj_dir, meta) do
    File.mkdir_p!(drive_obj_dir)
    File.write(Path.join(drive_obj_dir, @meta_file), Meta.encode(meta))
  end

  @doc "读该 drive 上对象的 sidecar。"
  @spec get_sidecar(String.t()) :: {:ok, map()} | {:error, :enoent}
  def get_sidecar(drive_obj_dir) do
    case File.read(Path.join(drive_obj_dir, @meta_file)) do
      {:ok, bin} -> {:ok, Meta.decode!(bin)}
      {:error, _} -> {:error, :enoent}
    end
  end

  @doc "stat：该 drive 上 part.0 字节数（heal 用其判文件完整）。"
  @spec stat_shard(String.t()) :: {:ok, non_neg_integer()} | {:error, :enoent}
  def stat_shard(drive_obj_dir) do
    case File.stat(Path.join(drive_obj_dir, @part_file)) do
      {:ok, %File.Stat{size: s}} -> {:ok, s}
      {:error, _} -> {:error, :enoent}
    end
  end

  @doc "删该 drive 上对象的整个目录（part.0 + meta.json）。幂等。"
  @spec delete_shard(String.t()) :: :ok
  def delete_shard(drive_obj_dir) do
    _ = File.rm_rf(drive_obj_dir)
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
    File.mkdir_p!(drive_obj_dir)
    path = Path.join(drive_obj_dir, @part_file)
    ensure_part_file!(path, meta, drive_obj_dir, shard_len)
    {:ok, fd} = :file.open(String.to_charlist(path), [:read, :write, :binary, :raw])

    try do
      Enum.each(block_map, fn {j, shard} -> :ok = :file.pwrite(fd, j * shard_len, shard) end)
    after
      :file.close(fd)
    end

    File.write!(Path.join(drive_obj_dir, @meta_file), Meta.encode(meta))
    {:ok, map_size(block_map)}
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
end
