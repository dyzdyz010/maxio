defmodule Maxio.Sidecar do
  @moduledoc """
  ROUTE B sidecar v2 形态与编解码（纯函数，不写盘）。在 M6 既有 meta.json（ec/shards/size/etag/
  sha256/parts —— 耐久元数据，绝不被污染）之上加 `format:"maxio/2"` + versions 数组，使 sidecar
  自描述全部 S3 元数据（成为事实来源的前提）。方案 B：每版本独立目录 + 自描述 sidecar，故 versions
  通常单元素；保留数组形态兼容未来单 sidecar 多版本（MinIO xl.meta 式）。

  字段对齐 MinIO xl.meta v2：version_id / type(object|delete_marker) / is_latest（派生自 max modtime，
  存为缓存）/ modtime（int64 纳秒，latest 排序键）/ generation（单调，元数据变更冲突解析）/
  content_type / content_encoding / content_disposition / cache_control / expires / website_redirect_location / user_metadata
  / tags / sse / acl_canned / acl_grants / storage_class / data_dir / inline。

  铁律 3：latest 由 max(modtime) 派生（绝不让两版本都 latest）；signature 是版本体 hash（分歧检测）。
  铁律 5：modtime 纳秒、type、delete_marker 语义对齐 AWS/MinIO。

  ## 编解码

  `encode/1` / `decode!/1` 复用 `Maxio.Storage.Erasure.Meta`（Jason JSON）——v2 sidecar 仍是同一盘上
  meta.json 文件，只是结构升级；编解码器不变，保证 v1/v2 在盘上同格式（JSON），读侧统一。

  ## latest 语义（两个查询，不同用途）

    * `latest/1`：max(modtime) 的版本 entry（**任意 type**，含 delete_marker）——对应 S3「latest
      version」语义：若最新版本是 delete_marker，未带 versionId 的 GET/HEAD 应得 404（NoSuchKey）。
    * `latest_object/1`：max(modtime) 的**非 delete_marker** 版本 entry——「最近一个真实对象版本」，
      用于「删除最新 delete_marker 后 latest 退回到的对象」等场景。无对象版本 -> nil。

  本模块当前不被 backend/handler 调用（B2 才接线）；纯新增，无行为变更。
  """

  alias Maxio.Storage.Erasure.Meta

  @format "maxio/2"
  @sha256_pattern ~r/\A[0-9a-fA-F]{64}\z/

  @type version_entry :: %{optional(String.t()) => term()}

  @doc "把 sidecar map 编码为盘上 JSON（复用 Erasure.Meta 编码器）。"
  @spec encode(map()) :: binary()
  def encode(%{} = meta), do: Meta.encode(meta)

  @doc "把盘上 JSON 解码为 sidecar map（复用 Erasure.Meta 解码器）。"
  @spec decode!(binary()) :: map()
  def decode!(bin) when is_binary(bin), do: Meta.decode!(bin)

  @doc """
  Decodes and validates the durable ordinary-object envelope without raising.

  The returned core always comes from the top-level durable fields. The selected version entry
  is only used to prove that the requested object version exists exactly once; its S3-visible
  ETag and size are intentionally allowed to differ from the durable core.
  """
  @spec decode_durable_object(binary(), String.t()) ::
          {:ok,
           %{
             core: %{etag: String.t(), size: non_neg_integer(), sha256: String.t()},
             meta: map(),
             version: version_entry()
           }}
          | {:error,
             :invalid_request
             | :invalid_json
             | :invalid_envelope
             | :invalid_format
             | :invalid_etag
             | :invalid_size
             | :invalid_sha256
             | :invalid_versions
             | :missing_object_version
             | :duplicate_version_identity
             | :invalid_object_version}
  def decode_durable_object(raw, version_id)
      when is_binary(raw) and is_binary(version_id) and byte_size(version_id) > 0 do
    with {:ok, meta} <- decode_durable_json(raw),
         :ok <- validate_durable_format(meta),
         {:ok, core} <- durable_core(meta),
         {:ok, version} <- durable_object_version(meta, version_id) do
      {:ok, %{core: core, meta: meta, version: version}}
    end
  end

  def decode_durable_object(_raw, _version_id), do: {:error, :invalid_request}

  @doc "当前 sidecar format（用于读侧分流 v1/v2）。"
  @spec format() :: String.t()
  def format, do: @format

  @doc "该 meta 是否已是 maxio/2 形态。"
  @spec v2?(map()) :: boolean()
  def v2?(%{"format" => @format}), do: true
  def v2?(%{}), do: false

  @doc """
  把旧 v1 meta（或已 v2 的 meta）升级为 maxio/2 形态（**幂等**）。已 v2 直接原样返回。
  opts 提供版本头字段（version_id / modtime / generation / content_type / content_encoding /
  content_disposition / cache_control / expires / website_redirect_location / tags / sse / acl_canned / acl_grants / storage_class /
  user_metadata / data_dir / inline / etag / size）。耐久字段 ec/shards/size/etag/sha256/parts
  逐字保留（绝不污染）。

  `:etag`（B6-2a，可选）：versions entry 的 **S3 可见 ETag** 覆盖——多段完成对象的 entry etag
  必须是 `hex(MD5(concat part MD5s))-N` 形态（Multipart.complete 经 object_meta 透传），而耐久
  core 顶层 etag 仍是整体字节 MD5（完整性校验语义，绝不动）。未给（nil）→ entry etag 沿用
  v1 core etag（单次 PUT 两者本就同值）。

  `:size`（可选）：versions entry 的 **S3 可见明文字节数** 覆盖。SSE-S3 对象的耐久 core
  size 是密文帧长度，GET/HEAD/LIST 必须暴露明文长度，故只覆盖 versions entry，绝不改 core。
  """
  @spec migrate_v1(map(), keyword()) :: map()
  def migrate_v1(%{"format" => @format} = v2, _opts), do: v2

  def migrate_v1(%{} = v1, opts) do
    entry = %{
      "version_id" => Keyword.get(opts, :version_id, "null"),
      "type" => "object",
      "is_latest" => true,
      "modtime" => Keyword.get(opts, :modtime, now_ns()),
      "generation" => Keyword.get(opts, :generation, 0),
      "data_dir" => Keyword.get(opts, :data_dir),
      "size" => Keyword.get(opts, :size) || v1["size"],
      "etag" => Keyword.get(opts, :etag) || v1["etag"],
      "sha256" => v1["sha256"],
      "content_type" => Keyword.get(opts, :content_type, "binary/octet-stream"),
      "content_encoding" => Keyword.get(opts, :content_encoding),
      "content_disposition" => Keyword.get(opts, :content_disposition),
      "cache_control" => Keyword.get(opts, :cache_control),
      "expires" => Keyword.get(opts, :expires),
      "website_redirect_location" => Keyword.get(opts, :website_redirect_location),
      "user_metadata" => Keyword.get(opts, :user_metadata, %{}),
      "checksum" => Keyword.get(opts, :checksum, %{}),
      "object_parts" => Keyword.get(opts, :object_parts, %{}),
      "tags" => Keyword.get(opts, :tags, %{}),
      "sse" => Keyword.get(opts, :sse),
      "acl_canned" => Keyword.get(opts, :acl_canned, "private"),
      "acl_grants" => Keyword.get(opts, :acl_grants, %{"grants" => []}),
      "storage_class" => Keyword.get(opts, :storage_class, "STANDARD"),
      "object_lock_mode" => Keyword.get(opts, :object_lock_mode),
      "object_lock_retain_until" =>
        datetime_to_iso8601(Keyword.get(opts, :object_lock_retain_until)),
      "object_lock_legal_hold" => Keyword.get(opts, :object_lock_legal_hold),
      "restore_status" => Keyword.get(opts, :restore_status),
      "restore_expiry" => datetime_to_iso8601(Keyword.get(opts, :restore_expiry)),
      "replication_status" => Keyword.get(opts, :replication_status),
      "notification_outbox" => Keyword.get(opts, :notification_outbox, []),
      "inline" => Keyword.get(opts, :inline)
    }

    v1
    |> Map.put("format", @format)
    |> Map.put("versions", [entry])
  end

  @doc """
  把版本 entry merge 进 versions（同 version_id 覆盖），重算 is_latest（max modtime，并列按
  generation desc、version_id desc）。
  """
  @spec put_version_entry(map(), version_entry()) :: map()
  def put_version_entry(%{} = meta, %{} = entry) do
    vid = entry["version_id"]
    existing = Map.get(meta, "versions", [])
    merged = Enum.reject(existing, fn e -> e["version_id"] == vid end) ++ [entry]

    meta
    |> Map.put_new("format", @format)
    |> Map.put("versions", recompute_latest(merged))
  end

  @doc """
  当前 latest 版本 entry（max modtime；并列按 generation desc、version_id desc）——**任意 type**，
  含 delete_marker（对应 S3 latest-version 语义）。空 -> nil。
  """
  @spec latest(map()) :: version_entry() | nil
  def latest(%{"versions" => versions}) when is_list(versions) and versions != [] do
    versions |> Enum.sort_by(&sort_key/1, :desc) |> List.first()
  end

  def latest(_), do: nil

  @doc """
  当前 latest **真实对象**版本 entry（max modtime 的**非 delete_marker**版本）。无对象版本 -> nil。
  用于「删除最新 delete_marker 后 latest 退回到的对象版本」等场景（铁律 5 对齐 AWS 删除标记语义）。
  """
  @spec latest_object(map()) :: version_entry() | nil
  def latest_object(%{"versions" => versions}) when is_list(versions) do
    versions
    |> Enum.reject(fn e -> e["type"] == "delete_marker" end)
    |> case do
      [] -> nil
      objs -> objs |> Enum.sort_by(&sort_key/1, :desc) |> List.first()
    end
  end

  def latest_object(_), do: nil

  @doc "按 version_id 取版本 entry；无 -> nil。"
  @spec find_version(map(), String.t()) :: version_entry() | nil
  def find_version(%{"versions" => versions}, vid) when is_list(versions),
    do: Enum.find(versions, fn e -> e["version_id"] == vid end)

  def find_version(_, _), do: nil

  @doc """
  版本体内容签名（分歧检测；对身份字段做确定性 sha256 hash）。派生字段（如 is_latest 缓存）不计入，
  保证「同一版本体在不同 latest 缓存下签名一致」。
  """
  @spec signature(version_entry()) :: binary()
  def signature(%{} = entry) do
    canon =
      [
        "version_id",
        "type",
        "modtime",
        "generation",
        "etag",
        "size",
        "content_type",
        "content_encoding",
        "content_disposition",
        "cache_control",
        "expires",
        "website_redirect_location",
        "acl_canned",
        "acl_grants",
        "storage_class",
        "tags",
        "user_metadata",
        "checksum",
        "object_parts",
        "sse",
        "object_lock_mode",
        "object_lock_retain_until",
        "object_lock_legal_hold",
        "restore_status",
        "restore_expiry",
        "replication_status",
        "notification_outbox"
      ]
      |> Enum.map(fn k -> {k, Map.get(entry, k)} end)

    :crypto.hash(:sha256, :erlang.term_to_binary(canon))
  end

  @doc """
  ROUTE B B5-3 R1 —— 版本 entry 的 modtime（int64 纳秒）→ DateTime（对象**真实写入时刻**；
  客户端可见 Last-Modified 的单一语义来源）。缺失 / 非整数 / 越界 → `:error`，由调用方自决兜底
  （读路径回落 now —— `Maxio.ObjectMeta`；reconcile 保留既有行 updated_at —— `Maxio.Objects`），
  绝不在此静默猜一个时刻（铁律 3）。
  """
  @spec entry_modtime_datetime(version_entry()) :: {:ok, DateTime.t()} | :error
  def entry_modtime_datetime(%{"modtime" => ns}) when is_integer(ns) do
    case DateTime.from_unix(ns, :nanosecond) do
      {:ok, dt} -> {:ok, dt}
      {:error, _} -> :error
    end
  end

  def entry_modtime_datetime(_entry), do: :error

  @doc "把 sidecar 某版本 entry 翻成 Maxio.Objects 索引行 attrs（PG 派生用；B2 接线）。"
  @spec to_object_attrs(String.t(), String.t(), version_entry()) :: map()
  def to_object_attrs(_bucket, _key, %{} = e) do
    %{
      size: e["size"] || 0,
      etag: e["etag"] || "",
      content_type: e["content_type"] || "binary/octet-stream",
      content_encoding: e["content_encoding"],
      content_disposition: e["content_disposition"],
      cache_control: e["cache_control"],
      expires: e["expires"],
      website_redirect_location: e["website_redirect_location"],
      metadata: e["user_metadata"] || %{},
      checksum: e["checksum"] || %{},
      object_parts: e["object_parts"] || %{},
      storage_class: e["storage_class"] || "STANDARD",
      acl_canned: e["acl_canned"] || "private",
      acl_grants: e["acl_grants"] || %{"grants" => []},
      tags: e["tags"] || %{},
      object_lock_mode: e["object_lock_mode"],
      object_lock_retain_until: parse_datetime(e["object_lock_retain_until"]),
      object_lock_legal_hold: e["object_lock_legal_hold"],
      restore_status: e["restore_status"],
      restore_expiry: parse_datetime(e["restore_expiry"]),
      replication_status: e["replication_status"],
      sse_algorithm: get_in(e, ["sse", "algo"]),
      sse_envelope: e["sse"] && e["sse"]["envelope"],
      version_id: e["version_id"],
      is_latest: e["is_latest"] || false,
      is_delete_marker: e["type"] == "delete_marker"
    }
  end

  @doc """
  把 sidecar 某版本 entry 翻成「读路径可比视图」map（B2 shadow 比对用）。
  键与 `Maxio.Objects.Object` 的读相关字段对齐，便于 ObjectMeta 逐字段比对 PG 与 sidecar。
  与 `to_object_attrs/3` 取值一致，但固定输出读路径字段集。
  """
  @spec to_view(String.t(), String.t(), version_entry()) :: map()
  def to_view(_bucket, _key, %{} = e) do
    %{
      version_id: e["version_id"],
      size: e["size"] || 0,
      etag: e["etag"] || "",
      content_type: e["content_type"] || "binary/octet-stream",
      content_encoding: e["content_encoding"],
      content_disposition: e["content_disposition"],
      cache_control: e["cache_control"],
      expires: e["expires"],
      website_redirect_location: e["website_redirect_location"],
      metadata: e["user_metadata"] || %{},
      checksum: e["checksum"] || %{},
      object_parts: e["object_parts"] || %{},
      storage_class: e["storage_class"] || "STANDARD",
      acl_canned: e["acl_canned"] || "private",
      acl_grants: e["acl_grants"] || %{"grants" => []},
      tags: e["tags"] || %{},
      object_lock_mode: e["object_lock_mode"],
      object_lock_retain_until: parse_datetime(e["object_lock_retain_until"]),
      object_lock_legal_hold: e["object_lock_legal_hold"],
      restore_status: e["restore_status"],
      restore_expiry: parse_datetime(e["restore_expiry"]),
      replication_status: e["replication_status"],
      sse_algorithm: get_in(e, ["sse", "algo"]),
      # SSE-S3/-C 的封装信封（含 wrapped DEK）。必须随读视图携带——否则 sidecar 读权威下
      # 加密对象 GET 会拿到 sse_algorithm="AES256" 却缺信封，解密时 unwrap_dek(nil) 炸（铁律 3）。
      # 取值与 to_object_attrs/3 逐字一致，保证 sidecar 读视图与 PG 读视图对加密对象同构。
      sse_envelope: e["sse"] && e["sse"]["envelope"],
      is_latest: e["is_latest"] || false,
      is_delete_marker: e["type"] == "delete_marker"
    }
  end

  defp recompute_latest(versions) do
    case Enum.max_by(versions, &sort_key/1, fn -> nil end) do
      nil -> versions
      top -> Enum.map(versions, fn e -> Map.put(e, "is_latest", e == top) end)
    end
  end

  defp decode_durable_json(raw) do
    case Jason.decode(raw) do
      {:ok, %{} = meta} -> {:ok, meta}
      {:ok, _other} -> {:error, :invalid_envelope}
      {:error, _reason} -> {:error, :invalid_json}
    end
  end

  defp validate_durable_format(%{"format" => @format}), do: :ok
  defp validate_durable_format(_meta), do: {:error, :invalid_format}

  defp durable_core(meta) do
    with {:ok, etag} <- durable_etag(meta),
         {:ok, size} <- durable_size(meta),
         {:ok, sha256} <- durable_sha256(meta) do
      {:ok, %{etag: etag, size: size, sha256: sha256}}
    end
  end

  defp durable_etag(%{"etag" => etag}) when is_binary(etag) and byte_size(etag) > 0,
    do: {:ok, etag}

  defp durable_etag(_meta), do: {:error, :invalid_etag}

  defp durable_size(%{"size" => size}) when is_integer(size) and size >= 0, do: {:ok, size}
  defp durable_size(_meta), do: {:error, :invalid_size}

  defp durable_sha256(%{"sha256" => sha256}) when is_binary(sha256) do
    if Regex.match?(@sha256_pattern, sha256),
      do: {:ok, sha256},
      else: {:error, :invalid_sha256}
  end

  defp durable_sha256(_meta), do: {:error, :invalid_sha256}

  defp durable_object_version(%{"versions" => versions}, version_id)
       when is_list(versions) and versions != [] do
    with :ok <- validate_version_entries(versions) do
      case Enum.filter(versions, &(&1["version_id"] == version_id)) do
        [] -> {:error, :missing_object_version}
        [%{"type" => "object"} = version] -> {:ok, version}
        [_one] -> {:error, :invalid_object_version}
        _duplicates -> {:error, :duplicate_version_identity}
      end
    end
  end

  defp durable_object_version(_meta, _version_id), do: {:error, :invalid_versions}

  defp validate_version_entries(versions) do
    if Enum.all?(versions, fn
         %{"version_id" => version_id, "type" => type}
         when is_binary(version_id) and byte_size(version_id) > 0 and
                type in ["object", "delete_marker"] ->
           true

         _other ->
           false
       end) do
      :ok
    else
      {:error, :invalid_versions}
    end
  end

  defp sort_key(e), do: {e["modtime"] || 0, e["generation"] || 0, e["version_id"] || ""}
  defp datetime_to_iso8601(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp datetime_to_iso8601(nil), do: nil
  defp datetime_to_iso8601(value), do: value

  defp parse_datetime(nil), do: nil
  defp parse_datetime(%DateTime{} = dt), do: dt

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> dt
      _other -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp now_ns, do: System.os_time(:nanosecond)
end
