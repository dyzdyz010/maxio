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

  ## 字节级 escape（MinIO-fidelity 修复：Windows 禁用文件名字节绝不裸落盘）

  Windows/NTFS 对 `\\ : * ? " < > |` 与控制字节（0x00–0x1F）有路径语义（`a:b` 的 `:` 被吞成
  NTFS 流/盘符语义 → 两个不同 S3 key 静默别名同一盘路径 = 跨 key 字节覆写）。MinIO 在 Windows
  上直接 400 拒绝这些字符（cmd/object-api-utils.go checkObjectNameForLengthAndSlash）；AWS
  接受并忠实存储。maxio 取 AWS 上界：段内这些字节一律 `%XX`（大写十六进制）escape（`%` 自身
  也 escape，保证单射——编码输出中每个 `%` 必来自 escape），**跨平台恒 escape**（相对路径
  跨节点/跨 OS 字节一致，铁律 2），任何 UTF-8 key 在任何 OS 上都有唯一、可逆的盘路径。

  编码是单射（escape 规则同时覆盖「本身以标记结尾」的用户段），`decode_segment/1`/`decode_key/1`
  为精确逆变换——drive-walk（LIST/scanner/heal）据此把盘上目录名还原成原始 key。

  ## 盘上段长硬限（对齐 MinIO checkPathLength）

  编码后的单个盘段 >255 字节（POSIX NAME_MAX / NTFS 单组件硬限）→ `validate_key/1` 返回
  `{:error, :key_too_long}`（handler 映射 400 KeyTooLongError）。对齐 MinIO
  cmd/xl-storage.go checkPathLength：单段超 255 → errFileNameTooLong → ObjectNameTooLong →
  400 KeyTooLongError——在触 OS 之前结构化拒绝，绝不让 mkdir 的 :enametoolong 冒成 500。
  """

  # 盘上布局保留名：与编码后的用户段必须不相交（ShardServer @meta_file/@part_file、
  # 内部根 .versions/.uploads/.tmp、list_dir 的跳过名单同源——ShardServer @internal_prefixes
  # 两处必须同步改）。仅精确匹配（part.1 等不在内）。.maxio-object-epochs /
  # .maxio-object-mutations 为 ObjectMutation 协议根（B1：durable epoch 与备份 manifest）。
  @layout_reserved [
    "meta.json",
    "part.0",
    ".versions",
    ".uploads",
    ".tmp",
    ".maxio-notification-ledger",
    ".maxio-object-epochs",
    ".maxio-object-mutations",
    ".maxio-removal-quarantine"
  ]

  @notification_ledger_root ".maxio-notification-ledger"

  # 编码标记。互不为后缀（decode 按 @dir_suffix → @esc_suffix → @empty_seg 顺序判定无歧义）。
  @esc_suffix "__MXESC__"
  @empty_seg "__MXEMPTY__"
  @dir_suffix "__MXDIR__"

  # 字节 escape 集：Windows 文件名禁用字节（MinIO checkObjectNameForLengthAndSlash 的
  # `\:*?"|<>` 同集合；控制字节 0x00-0x1F 由 escape_byte/1 的范围守卫覆盖）+ escape 引导符 `%`。
  @escape_bytes [?%, ?\\, ?:, ?*, ??, ?", ?<, ?>, ?|]

  # 盘上单个路径段（编码后目录名）字节硬限：POSIX NAME_MAX / NTFS 单组件 255。对齐 MinIO
  # cmd/xl-storage.go checkPathLength（>255 → errFileNameTooLong → 400 KeyTooLongError）。
  @max_segment_bytes 255

  @doc """
  S3 API 层对象 key 守卫：仅拒绝 S3/MinIO 都拒绝的形态——
    * 空 key 与 `.`/`..` 点段（MinIO cmd/object-api-utils.go IsValidObjectPrefix 的
      hasBadPathComponent，路径穿越守卫）→ `{:error, :invalid_key}`
      （handler 映射 400 `XMinioInvalidObjectName`）；
    * **原始 key**（编码前）超 1024 字节（AWS/MinIO 对象 key 长度硬上限，MinIO
      IsValidObjectName 的 len > 1024 检查）→ `{:error, :key_too_long}`
      （handler 映射 400 `KeyTooLongError`，与 :invalid_key 分流，B5-4）；
    * **编码后**任一盘段超 255 字节（POSIX NAME_MAX / NTFS 单组件硬限）→ 同样
      `{:error, :key_too_long}`（对齐 MinIO checkPathLength → errFileNameTooLong →
      400 KeyTooLongError；在触 OS 之前拒绝，杜绝 mkdir :enametoolong 冒成 500 并
      泄露服务器盘路径）。

  **不**拒绝布局保留名段（meta.json/part.0/...）——MinIO/AWS 均接受这类普通 key
  （盘上碰撞由 `encode_key/1` 段编码结构化消除）；**不**拒绝空段——尾/连续/前导斜杠 key
  （"dir/"、"a//b"、"/lead"）是合法 AWS key（铁律 5，既有端到端保真测试锁死），空段经
  `__MXEMPTY__`/`__MXDIR__` 编码无碰撞落盘（MinIO 拒 `//`，maxio 此处取 AWS 上界，文档化差异）。
  """
  @spec validate_key(String.t()) :: :ok | {:error, :invalid_key | :key_too_long}
  def validate_key(key) when is_binary(key) do
    cond do
      key == "" ->
        {:error, :invalid_key}

      byte_size(key) > 1024 ->
        {:error, :key_too_long}

      key |> String.split("/") |> Enum.any?(&(&1 in [".", ".."])) ->
        {:error, :invalid_key}

      key |> encoded_segments() |> Enum.any?(&(byte_size(&1) > @max_segment_bytes)) ->
        {:error, :key_too_long}

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
    case validate_key(key) do
      :ok ->
        {:ok, key |> encoded_segments() |> Enum.join("/")}

      {:error, _reason} ->
        # 长度闸（:key_too_long）是 API 入口语义——精确错误 Code（KeyTooLongError vs
        # XMinioInvalidObjectName）由 handler 入口守卫分流映射；盘路径层只需「不可表达即结构化
        # 拒绝」单一契约，统一折叠为 :invalid_key——后端/backstop（FS/EC/Distributed/scanner/heal
        # 全部匹配 {:error, :invalid_key}）契约不变。入口守卫已先行拦截，此处仅兜底（绝不静默）。
        {:error, :invalid_key}
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

  @doc """
  Bucket-scoped retained notification ledger root.

  The retained ledger is deliberately outside the user object namespace and the
  `.versions` tree, so object overwrites, delete markers, and hard deletes
  cannot remove the evidence carrier for post-commit notification replay.
  """
  @spec notification_ledger_bucket_rel(String.t()) :: String.t()
  def notification_ledger_bucket_rel(bucket) do
    Path.join([@notification_ledger_root, bucket]) |> to_unix()
  end

  @doc """
  Retained notification ledger key directory.

  The object key is represented by a SHA-256 digest, not by encoded key
  segments, to avoid path-length coupling and layout-name collisions. The
  original key remains inside each ledger entry payload.
  """
  @spec notification_ledger_key_rel(String.t(), String.t()) :: String.t()
  def notification_ledger_key_rel(bucket, key) when is_binary(key) do
    hash = :crypto.hash(:sha256, key) |> Base.encode16(case: :lower)

    Path.join([notification_ledger_bucket_rel(bucket), binary_part(hash, 0, 2), hash])
    |> to_unix()
  end

  @doc "Retained notification ledger entry directory for one stable event id."
  @spec notification_ledger_entry_rel(String.t(), String.t(), String.t()) :: String.t()
  def notification_ledger_entry_rel(bucket, key, id) do
    Path.join([notification_ledger_key_rel(bucket, key), id]) |> to_unix()
  end

  # key → 编码后盘段序列（validate_key 与 encode_key 共用的单一来源：长度闸与实际落盘
  # 路径对同一字节序列计量——validate_key 接受的 key 后端必可写，可建即可达）。
  defp encoded_segments(key) do
    segments = String.split(key, "/")

    {segments, dir_marker?} =
      if List.last(segments) == "" do
        {Enum.drop(segments, -1), true}
      else
        {segments, false}
      end

    encoded = Enum.map(segments, &encode_segment/1)

    if dir_marker?,
      do: List.update_at(encoded, -1, &(&1 <> @dir_suffix)),
      else: encoded
  end

  # 段编码（单射）：空段 → @empty_seg；先字节级 escape（Windows 禁用字节/控制字节/`%` →
  # `%XX`），再对布局保留名 / 恰为 @empty_seg / 以 @esc_suffix 或 @dir_suffix 结尾的段
  # 追加 @esc_suffix（保证三类输出——passthrough（不以任何标记结尾）、escaped（以 @esc_suffix
  # 结尾）、empty（== @empty_seg）——互不相交且可逆；escape 单射 + escape("meta.json") ==
  # "meta.json" 等不动点性质使保留名判定在 escape 后做仍正确）。
  defp encode_segment(""), do: @empty_seg

  defp encode_segment(raw_seg) do
    seg = escape_bytes(raw_seg)

    if seg in @layout_reserved or seg == @empty_seg or
         String.ends_with?(seg, @esc_suffix) or String.ends_with?(seg, @dir_suffix) do
      seg <> @esc_suffix
    else
      seg
    end
  end

  # encode_segment 的逆（不含 @dir_suffix 层）：剥一层 @esc_suffix / 还原空段，再做字节级
  # unescape（与 encode 的「先 escape 后追加后缀」恰好相反序）。
  defp decode_plain(name) do
    cond do
      String.ends_with?(name, @esc_suffix) ->
        name
        |> binary_part(0, byte_size(name) - byte_size(@esc_suffix))
        |> unescape_bytes()

      name == @empty_seg ->
        ""

      true ->
        unescape_bytes(name)
    end
  end

  # 字节级 escape：@escape_bytes 与控制字节（0x00-0x1F）→ `%XX`（大写十六进制）。单射：
  # 输出中每个 `%` 必来自 escape（原始 `%` 自身也被 escape）。UTF-8 多字节序列高位 ≥ 0x80，
  # 永不命中 escape 集——逐字节处理对任意 UTF-8 key 安全。
  defp escape_bytes(seg) do
    if escape_needed?(seg) do
      for <<b <- seg>>, into: "", do: escape_byte(b)
    else
      seg
    end
  end

  defp escape_needed?(<<b, _rest::binary>>) when b <= 0x1F or b in @escape_bytes, do: true
  defp escape_needed?(<<_b, rest::binary>>), do: escape_needed?(rest)
  defp escape_needed?(<<>>), do: false

  defp escape_byte(b) when b <= 0x1F or b in @escape_bytes,
    do: <<?%>> <> Base.encode16(<<b>>, case: :upper)

  defp escape_byte(b), do: <<b>>

  # escape_bytes 的精确逆（在 encode 像集上）：`%` + 两位大写十六进制 → 原字节；其余原样。
  # 非 encode 像集的盘名（pre-escape 遗留数据中的裸 `%`，P7 B7-1 backfill 迁移）宽容透传。
  defp unescape_bytes(name) do
    if String.contains?(name, "%"), do: do_unescape(name, <<>>), else: name
  end

  defp do_unescape(<<?%, h1, h2, rest::binary>>, acc)
       when (h1 in ?0..?9 or h1 in ?A..?F) and (h2 in ?0..?9 or h2 in ?A..?F) do
    do_unescape(rest, <<acc::binary, hex_val(h1) * 16 + hex_val(h2)>>)
  end

  defp do_unescape(<<b, rest::binary>>, acc), do: do_unescape(rest, <<acc::binary, b>>)
  defp do_unescape(<<>>, acc), do: acc

  defp hex_val(c) when c in ?0..?9, do: c - ?0
  defp hex_val(c) when c in ?A..?F, do: c - ?A + 10

  # 路径分隔统一为 "/"（Windows 上 Path.join 产 "\\"；端点目录后续仍经 Path.join(drive, rel) 落地，
  # 但相对路径本身用 "/" 保证跨节点/跨平台一致，且单测断言稳定）。
  defp to_unix(path), do: String.replace(path, "\\", "/")
end
