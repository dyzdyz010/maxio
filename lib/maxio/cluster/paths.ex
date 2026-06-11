defmodule Maxio.Cluster.Paths do
  @moduledoc """
  分布式后端与 heal 共享的对象/part「盘内相对路径」构造（M7）。单一事实来源——
  FS / ErasureCoded / Distributed / heal / drive-walk 全部经本模块编码（避免后端漂移，铁律 2）。
  返回相对路径（相对每个 drive 根），调用方 Path.join(drive, rel) 得该端点该对象的目录。

  ## key ↔ 盘段编码（MinIO-fidelity 修复，取代 B5-3 R3 的 API 层保留名拒绝）

  MinIO/AWS 对 `meta.json`/`part.0`/`.versions`/`.uploads`/`.tmp` 这类「恰好撞上我们盘上布局名」
  的 key **不做任何拒绝**（MinIO 自己的布局名 xl.meta 也不拒，靠结构避碰；AWS key 是任意 UTF-8）。
  故 API 层绝不再 400 拒绝它们；碰撞改由**盘段编码**结构化消除（对齐 MinIO `__XLDIR__` 思路）：

    * 布局保留名段 / 以编码标记结尾的段 → 追加 `__MXESC__`（`meta.json` → `meta.json__MXESC__`），
      使盘上布局文件名（meta.json/part.0）与内部目录（.versions/.uploads/.tmp）永远不可能
      等于任何编码后的用户段；
    * 空段（`a//b` 的中段、`/lead` 的首段）→ `__MXEMPTY__`（盘上目录名不能为空，绝不静默折叠）；
    * 尾斜杠 folder marker（`dir/`）→ 末段追加 `__MXDIR__`（同 MinIO `dir__XLDIR__`：与对象
      `dir` 是**兄弟**路径，FS 后端文件/目录不互斥）。

  编码是单射（escape 规则同时覆盖「本身以标记结尾」的用户段），`decode_segment/1`/`decode_key/1`
  为精确逆变换——drive-walk（LIST/scanner/heal）据此把盘上目录名还原成原始 key。
  """

  # 盘上布局保留名：与编码后的用户段必须不相交（ShardServer @meta_file/@part_file、
  # 内部根 .versions/.uploads/.tmp、list_dir 的跳过名单同源）。仅精确匹配（part.1 等不在内）。
  @layout_reserved ["meta.json", "part.0", ".versions", ".uploads", ".tmp"]

  # 编码标记。互不为后缀（decode 按 @dir_suffix → @esc_suffix → @empty_seg 顺序判定无歧义）。
  @esc_suffix "__MXESC__"
  @empty_seg "__MXEMPTY__"
  @dir_suffix "__MXDIR__"

  @doc """
  S3 API 层对象 key 守卫：仅拒绝 S3/MinIO 都拒绝的形态——空 key 与 `.`/`..` 点段
  （MinIO cmd/object-api-utils.go IsValidObjectPrefix 的 hasBadPathComponent，路径穿越守卫）
  → `{:error, :invalid_key}`（handler 映射 400 `XMinioInvalidObjectName`）。

  **不**拒绝布局保留名段（meta.json/part.0/...）——MinIO/AWS 均接受这类普通 key
  （盘上碰撞由 `encode_key/1` 段编码结构化消除）；**不**拒绝空段——尾/连续/前导斜杠 key
  （"dir/"、"a//b"、"/lead"）是合法 AWS key（铁律 5，既有端到端保真测试锁死），空段经
  `__MXEMPTY__`/`__MXDIR__` 编码无碰撞落盘（MinIO 拒 `//`，maxio 此处取 AWS 上界，文档化差异）。
  """
  @spec validate_key(String.t()) :: :ok | {:error, :invalid_key}
  def validate_key(key) when is_binary(key) do
    cond do
      key == "" ->
        {:error, :invalid_key}

      key |> String.split("/") |> Enum.any?(&(&1 in [".", ".."])) ->
        {:error, :invalid_key}

      true ->
        :ok
    end
  end

  @doc """
  key → 盘上相对路径段（"/" 连接；恒为 unix 风格）。validate_key 通过后逐段编码
  （见 moduledoc），任何合法 key 都有无碰撞盘路径——validate_key 接受的 key 后端必可写
  （杜绝「可建不可达」不对称）。非法 key → `{:error, :invalid_key}`。
  """
  @spec encode_key(String.t()) :: {:ok, String.t()} | {:error, :invalid_key}
  def encode_key(key) do
    with :ok <- validate_key(key) do
      segments = String.split(key, "/")

      {segments, dir_marker?} =
        if List.last(segments) == "" do
          {Enum.drop(segments, -1), true}
        else
          {segments, false}
        end

      encoded = Enum.map(segments, &encode_segment/1)

      encoded =
        if dir_marker?,
          do: List.update_at(encoded, -1, &(&1 <> @dir_suffix)),
          else: encoded

      {:ok, Enum.join(encoded, "/")}
    end
  end

  @doc """
  盘上目录名 → 原始 key 段（`encode_segment` 的精确逆变换）。尾斜杠标记段还原为 `段 <> "/"`
  （`decode_key/1` 以 "/" join 后恰好重建 `dir/` 形态）。
  """
  @spec decode_segment(String.t()) :: String.t()
  def decode_segment(name) when is_binary(name) do
    if String.ends_with?(name, @dir_suffix) do
      inner = binary_part(name, 0, byte_size(name) - byte_size(@dir_suffix))
      decode_plain(inner) <> "/"
    else
      decode_plain(name)
    end
  end

  @doc "盘上目录名序列 → 原始 key（逐段 decode_segment 后以 \"/\" join）。"
  @spec decode_key([String.t()]) :: String.t()
  def decode_key(names) when is_list(names) do
    names |> Enum.map(&decode_segment/1) |> Enum.join("/")
  end

  @doc """
  对象在某 drive 下的相对路径：null 版本 = "bucket/<encoded-key>"；
  否则 = ".versions/bucket/<encoded-key>/version_id"。非法 key（空 key、`.`/`..` 点段）拒绝。
  """
  @spec object_rel(String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, :invalid_key}
  def object_rel(bucket, key, version_id) do
    case encode_key(key) do
      {:ok, rel} ->
        sub =
          if version_id == "null" do
            bucket <> "/" <> rel
          else
            Enum.join([".versions", bucket, rel, version_id], "/")
          end

        {:ok, sub}

      {:error, :invalid_key} ->
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

  # 段编码（单射）：空段 → @empty_seg；布局保留名 / 恰为 @empty_seg / 以 @esc_suffix 或
  # @dir_suffix 结尾的段 → 追加 @esc_suffix（保证三类输出——passthrough（不以任何标记结尾）、
  # escaped（以 @esc_suffix 结尾）、empty（== @empty_seg）——互不相交且可逆）。
  defp encode_segment(""), do: @empty_seg

  defp encode_segment(seg) do
    if seg in @layout_reserved or seg == @empty_seg or
         String.ends_with?(seg, @esc_suffix) or String.ends_with?(seg, @dir_suffix) do
      seg <> @esc_suffix
    else
      seg
    end
  end

  # encode_segment 的逆（不含 @dir_suffix 层）：剥一层 @esc_suffix / 还原空段 / 原样。
  defp decode_plain(name) do
    cond do
      String.ends_with?(name, @esc_suffix) ->
        binary_part(name, 0, byte_size(name) - byte_size(@esc_suffix))

      name == @empty_seg ->
        ""

      true ->
        name
    end
  end

  # 路径分隔统一为 "/"（Windows 上 Path.join 产 "\\"；端点目录后续仍经 Path.join(drive, rel) 落地，
  # 但相对路径本身用 "/" 保证跨节点/跨平台一致，且单测断言稳定）。
  defp to_unix(path), do: String.replace(path, "\\", "/")
end
