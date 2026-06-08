defmodule Maxio.Cluster.Paths do
  @moduledoc """
  分布式后端与 heal 共享的对象/part「盘内相对路径」构造（M7）。单一事实来源——
  与 M6 ErasureCoded 的 object_dirs/4 + safe_relative/1 语义逐字一致（避免后端漂移，铁律 2）。
  返回相对路径（相对每个 drive 根），调用方 Path.join(drive, rel) 得该端点该对象的目录。
  """

  @doc """
  对象在某 drive 下的相对路径：null 版本 = "bucket/key"；
  否则 = ".versions/bucket/key/version_id"。`..`/`.`/空 key 拒绝（路径穿越守卫）。
  """
  @spec object_rel(String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, :invalid_key}
  def object_rel(bucket, key, version_id) do
    case safe_relative(key) do
      {:ok, rel} ->
        sub =
          if version_id == "null" do
            Path.join([bucket, rel])
          else
            Path.join([".versions", bucket, rel, version_id])
          end

        {:ok, to_unix(sub)}

      :error ->
        {:error, :invalid_key}
    end
  end

  @doc "part 在某 drive 下的相对路径：.uploads/bucket/upload_id/part_number。"
  @spec part_rel(String.t(), String.t(), pos_integer()) :: String.t()
  def part_rel(bucket, upload_id, part_number) do
    Path.join([".uploads", bucket, upload_id, Integer.to_string(part_number)]) |> to_unix()
  end

  @doc "upload 在某 drive 下的相对路径：.uploads/bucket/upload_id。"
  @spec upload_rel(String.t(), String.t()) :: String.t()
  def upload_rel(bucket, upload_id) do
    Path.join([".uploads", bucket, upload_id]) |> to_unix()
  end

  defp safe_relative(key) do
    segments = key |> String.split("/", trim: true)

    cond do
      key == "" -> :error
      Enum.any?(segments, &(&1 in ["..", "."])) -> :error
      true -> {:ok, Path.join(segments)}
    end
  end

  # 路径分隔统一为 "/"（Windows 上 Path.join 产 "\\"；端点目录后续仍经 Path.join(drive, rel) 落地，
  # 但相对路径本身用 "/" 保证跨节点/跨平台一致，且单测断言稳定）。
  defp to_unix(path), do: String.replace(path, "\\", "/")
end
