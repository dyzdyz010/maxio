defmodule Maxio.Cluster.Paths do
  @moduledoc """
  分布式后端与 heal 共享的对象/part「盘内相对路径」构造（M7）。单一事实来源——
  与 M6 ErasureCoded 的 object_dirs/4 + safe_relative/1 语义逐字一致（避免后端漂移，铁律 2）。
  返回相对路径（相对每个 drive 根），调用方 Path.join(drive, rel) 得该端点该对象的目录。
  """

  # ROUTE B B5-3 R3 —— 盘上布局保留名（scanner 生产前置硬化）：key 任一段精确命中这些名字时，
  # 写入会与布局文件/内部目录冲突——list_dir 枚举不到（forward 永不收敛）、probe 误判 missing
  # （reverse-GC 会把有效 PG 行当孤儿删掉）。仅**精确**匹配（part.1 等不拦），大小写敏感（盘上布局是精确名）。
  @reserved_segments ["meta.json", "part.0", ".versions", ".uploads", ".tmp"]

  @doc """
  S3 API 层对象 key 守卫（ROUTE B B5-3 R3/R4）：按 "/" 分段，任一段为盘上布局保留名
  （meta.json/part.0/.versions/.uploads/.tmp 精确匹配）或 `.`/`..` 点段 → `{:error, :invalid_key}`
  （handler 映射 400 `XMinioInvalidObjectName`，对齐 MinIO ErrInvalidObjectName）。

  **不**拒绝空段——尾/连续斜杠 key（folder marker "dir/"、"a//b"）是合法 S3 key（铁律 5，
  既有端到端保真测试锁死），`:pg` 权威 + FS 后端忠实表达之；sidecar 盘上布局无法无碰撞表达空段，
  由 `object_rel/3`（盘路径层）单独拒绝。
  """
  @spec validate_key(String.t()) :: :ok | {:error, :invalid_key}
  def validate_key(key) when is_binary(key) do
    segments = String.split(key, "/")

    cond do
      key == "" ->
        {:error, :invalid_key}

      Enum.any?(segments, &(&1 in [".", ".."] or &1 in @reserved_segments)) ->
        {:error, :invalid_key}

      true ->
        :ok
    end
  end

  @doc """
  对象在某 drive 下的相对路径：null 版本 = "bucket/key"；
  否则 = ".versions/bucket/key/version_id"。`..`/`.`/空段/空 key/保留布局名段（B5-3 R3）
  拒绝（路径穿越 + 布局冲突守卫）。
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

  # 盘上相对路径层校验 = validate_key/1 的严格超集 + 空段拒绝：空段在盘上只能被折叠
  # （"a//b" 与 "a/b" 同一路径 = 静默碰撞），sidecar 布局后端必须结构化拒绝（铁律 3），绝不静默折叠。
  defp safe_relative(key) do
    segments = String.split(key, "/")

    cond do
      validate_key(key) == {:error, :invalid_key} -> :error
      Enum.any?(segments, &(&1 == "")) -> :error
      true -> {:ok, Path.join(segments)}
    end
  end

  # 路径分隔统一为 "/"（Windows 上 Path.join 产 "\\"；端点目录后续仍经 Path.join(drive, rel) 落地，
  # 但相对路径本身用 "/" 保证跨节点/跨平台一致，且单测断言稳定）。
  defp to_unix(path), do: String.replace(path, "\\", "/")
end
