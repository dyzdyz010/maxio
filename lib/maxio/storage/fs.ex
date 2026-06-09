defmodule Maxio.Storage.FS do
  @moduledoc """
  单机文件系统存储后端（MVP）。对象落在 `<data_dir>/<bucket>/<key>`，key 中的 `/`
  自然映射为子目录。put 流式写入并边写边算 MD5（绝不全缓冲，铁律 4）；
  get 支持 Range，按区间用 :file.pread 分块发出；防 `..` 路径穿越。

  写路径（put/assemble）经 **temp-then-rename + fsync**（ROUTE B B1-2）：先流式写
  `<data_dir>/.tmp/<uuid>/data`，fsync，再原子 rename 覆盖到 final 对象路径（同卷保证原子；crash
  在 rename 前 -> final 保旧值/不存在，绝不撕裂；temp 可 GC）。rename busy（Windows reader 持文件打开）
  -> 有界重试后 {:error, :rename_busy}（铁律 3）。fsync 开关由 `config :maxio, :durability, fsync:` 控制。

  每个回调额外接受可选末参 `opts`（`:data_dir` 覆盖根目录，便于测试隔离），
  缺省时从 `config :maxio, :s3, :data_dir` 读取。
  """
  @behaviour Maxio.Storage.Backend

  alias Maxio.Cluster.ShardServer

  @chunk_size 1_048_576
  @tmp_root ".tmp"

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
  # <data_dir>/.uploads/<bucket>/<upload_id>/<part_number>.part；
  # assemble 按 part 升序拼到对象路径；abort 删整个 upload 临时目录。──

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

  defp do_put(bucket, key, version_id, chunks, opts) do
    with {:ok, path} <- object_path(bucket, key, version_id, opts) do
      # B1-2 原子提交：先流式写同卷 temp 文件，fsync，再原子 rename 覆盖 final（crash 前 final 保旧值/缺失）。
      {tmp_dir, tmp_path} = begin_tmp_file!(opts)
      {:ok, fd} = File.open(tmp_path, [:write, :binary, :raw])

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

      case ShardServer.commit_file(tmp_path, path, Keyword.take(opts, [:fsync])) do
        :ok ->
          _ = File.rm_rf(tmp_dir)
          {:ok, %{size: size, etag: etag, sha256: sha256}}

        {:error, reason} ->
          _ = File.rm_rf(tmp_dir)
          {:error, reason}
      end
    end
  end

  defp do_get(bucket, key, version_id, range, opts) do
    with {:ok, path} <- object_path(bucket, key, version_id, opts) do
      case File.stat(path) do
        {:ok, %File.Stat{size: total}} -> {:ok, stream_file(path, range, total)}
        {:error, :enoent} -> {:error, :enoent}
      end
    end
  end

  defp do_stat(bucket, key, version_id, opts) do
    with {:ok, path} <- object_path(bucket, key, version_id, opts) do
      case File.stat(path) do
        {:ok, %File.Stat{size: size}} -> {:ok, %{size: size}}
        {:error, :enoent} -> {:error, :enoent}
      end
    end
  end

  defp do_delete(bucket, key, version_id, opts) do
    with {:ok, path} <- object_path(bucket, key, version_id, opts) do
      case File.rm(path) do
        :ok -> :ok
        {:error, :enoent} -> :ok
        {:error, reason} -> {:error, reason}
      end
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

  defp do_assemble(bucket, key, upload_id, part_numbers, opts) do
    with {:ok, obj_path} <- object_path(bucket, key, "null", opts) do
      # B1-2 原子提交：拼到同卷 temp 文件，fsync，再原子 rename 覆盖 final（绝不就地写半截对象）。
      {tmp_dir, tmp_path} = begin_tmp_file!(opts)
      {:ok, out} = File.open(tmp_path, [:write, :binary, :raw])

      size =
        try do
          Enum.reduce(part_numbers, 0, fn pn, acc ->
            path = part_path(bucket, upload_id, pn, opts)
            {:ok, in_fd} = :file.open(String.to_charlist(path), [:read, :binary, :raw])

            try do
              acc + copy_fd(in_fd, out, 0)
            after
              :file.close(in_fd)
            end
          end)
        after
          File.close(out)
        end

      case ShardServer.commit_file(tmp_path, obj_path, Keyword.take(opts, [:fsync])) do
        :ok ->
          _ = File.rm_rf(tmp_dir)
          {:ok, %{size: size}}

        {:error, reason} ->
          _ = File.rm_rf(tmp_dir)
          {:error, reason}
      end
    end
  end

  defp do_abort_upload(bucket, _key, upload_id, opts) do
    dir = upload_dir(bucket, upload_id, opts)
    _ = File.rm_rf(dir)
    :ok
  end

  # 1MB 分块把 in_fd 全量拷到 out，返回拷贝字节数。
  defp copy_fd(in_fd, out, acc) do
    case :file.read(in_fd, @chunk_size) do
      {:ok, data} ->
        :ok = IO.binwrite(out, data)
        copy_fd(in_fd, out, acc + byte_size(data))

      :eof ->
        acc

      {:error, _} ->
        acc
    end
  end

  # 在 data_dir 下建同卷 temp 目录 + 返回其中的 data 文件路径（与 final 同卷 -> rename 原子）。
  defp begin_tmp_file!(opts) do
    tmp_dir = Path.join([data_dir(opts), @tmp_root, tmp_uuid()])
    File.mkdir_p!(tmp_dir)
    {tmp_dir, Path.join(tmp_dir, "data")}
  end

  defp tmp_uuid, do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)

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

  # version_id == "null"（无版本）→ 落原路径 <data_dir>/<bucket>/<key>（向后兼容既有对象）。
  # 否则落版本化路径 <data_dir>/.versions/<bucket>/<key>/<version_id>（与对象路径物理隔离，避免与 key 命名冲突）。
  defp object_path(bucket, key, "null", opts) do
    case safe_relative(key) do
      {:ok, rel} -> {:ok, Path.join([data_dir(opts), bucket, rel])}
      :error -> {:error, :invalid_key}
    end
  end

  defp object_path(bucket, key, version_id, opts) do
    case safe_relative(key) do
      {:ok, rel} ->
        {:ok, Path.join([data_dir(opts), ".versions", bucket, rel, version_id])}

      :error ->
        {:error, :invalid_key}
    end
  end

  defp safe_relative(key) do
    segments = key |> String.split("/", trim: true)

    cond do
      key == "" -> :error
      Enum.any?(segments, &(&1 in ["..", "."])) -> :error
      true -> {:ok, Path.join(segments)}
    end
  end
end
