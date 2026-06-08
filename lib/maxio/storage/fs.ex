defmodule Maxio.Storage.FS do
  @moduledoc """
  单机文件系统存储后端（MVP）。对象落在 `<data_dir>/<bucket>/<key>`，key 中的 `/`
  自然映射为子目录。put 流式写入并边写边算 MD5（绝不全缓冲，铁律 4）；
  get 支持 Range，按区间用 :file.pread 分块发出；防 `..` 路径穿越。

  每个回调额外接受可选末参 `opts`（`:data_dir` 覆盖根目录，便于测试隔离），
  缺省时从 `config :maxio, :s3, :data_dir` 读取。
  """
  @behaviour Maxio.Storage.Backend

  @chunk_size 1_048_576

  @impl true
  def put(bucket, key, chunks, opts \\ []), do: do_put(bucket, key, chunks, opts)

  @impl true
  def get(bucket, key, range \\ nil, opts \\ []), do: do_get(bucket, key, range, opts)

  @impl true
  def stat(bucket, key, opts \\ []), do: do_stat(bucket, key, opts)

  @impl true
  def delete(bucket, key, opts \\ []), do: do_delete(bucket, key, opts)

  @impl true
  def put_bucket(bucket, opts \\ []), do: do_put_bucket(bucket, opts)

  @impl true
  def delete_bucket(bucket, opts \\ []), do: do_delete_bucket(bucket, opts)

  defp do_put(bucket, key, chunks, opts) do
    with {:ok, path} <- object_path(bucket, key, opts) do
      File.mkdir_p!(Path.dirname(path))
      {:ok, fd} = File.open(path, [:write, :binary, :raw])

      try do
        md5_0 = :crypto.hash_init(:md5)
        sha_0 = :crypto.hash_init(:sha256)

        {md5_ctx, sha_ctx, size} =
          Enum.reduce(chunks, {md5_0, sha_0, 0}, fn chunk, {m, s, acc} ->
            :ok = IO.binwrite(fd, chunk)
            {:crypto.hash_update(m, chunk), :crypto.hash_update(s, chunk), acc + byte_size(chunk)}
          end)

        etag = md5_ctx |> :crypto.hash_final() |> Base.encode16(case: :lower)
        sha256 = sha_ctx |> :crypto.hash_final() |> Base.encode16(case: :lower)
        {:ok, %{size: size, etag: etag, sha256: sha256}}
      after
        File.close(fd)
      end
    end
  end

  defp do_get(bucket, key, range, opts) do
    with {:ok, path} <- object_path(bucket, key, opts) do
      case File.stat(path) do
        {:ok, %File.Stat{size: total}} -> {:ok, stream_file(path, range, total)}
        {:error, :enoent} -> {:error, :enoent}
      end
    end
  end

  defp do_stat(bucket, key, opts) do
    with {:ok, path} <- object_path(bucket, key, opts) do
      case File.stat(path) do
        {:ok, %File.Stat{size: size}} -> {:ok, %{size: size}}
        {:error, :enoent} -> {:error, :enoent}
      end
    end
  end

  defp do_delete(bucket, key, opts) do
    with {:ok, path} <- object_path(bucket, key, opts) do
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
      (Application.fetch_env!(:maxio, :s3) |> Keyword.fetch!(:data_dir))
  end

  defp bucket_path(bucket, opts), do: Path.join(data_dir(opts), bucket)

  defp object_path(bucket, key, opts) do
    case safe_relative(key) do
      {:ok, rel} -> {:ok, Path.join([data_dir(opts), bucket, rel])}
      :error -> {:error, :invalid_key}
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
