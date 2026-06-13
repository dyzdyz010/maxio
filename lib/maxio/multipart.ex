defmodule Maxio.Multipart do
  @moduledoc """
  分段上传元数据上下文：initiate/get/put_part(元数据)/list_parts/list_uploads/complete/abort
  + multipart ETag 算法。分块字节走 Maxio.Storage（FS parts 回调），本上下文管会话与分块元数据
  及 Complete 时的校验（InvalidPart/InvalidPartOrder/EntityTooSmall/NoSuchUpload，铁律 3）。
  """
  import Ecto.Query
  alias Maxio.Crypto.SSE, as: CryptoSSE
  alias Maxio.Repo
  alias Maxio.Multipart.{Upload, Part}
  alias Maxio.S3.SystemHeaders

  @default_min_part_size 5_242_880

  @doc "发起分段上传：生成 UploadId（UUID hex），落会话元数据。"
  @spec initiate(String.t(), String.t(), map()) ::
          {:ok, Upload.t()} | {:error, Ecto.Changeset.t()}
  def initiate(bucket_name, key, attrs \\ %{}) do
    upload_id = generate_upload_id()

    base =
      %{
        upload_id: upload_id,
        bucket_name: bucket_name,
        key: key,
        content_type: Map.get(attrs, :content_type, "binary/octet-stream"),
        storage_class: Map.get(attrs, :storage_class, "STANDARD"),
        sse_algorithm: Map.get(attrs, :sse_algorithm),
        owner: Map.get(attrs, :owner, "arn:aws:iam:::root"),
        acl_canned: Map.get(attrs, :acl_canned, "private"),
        acl_grants: Map.get(attrs, :acl_grants, %{"grants" => []}),
        metadata: Map.get(attrs, :metadata, %{})
      }
      |> Map.merge(SystemHeaders.take(attrs))

    %Upload{} |> Upload.changeset(base) |> Repo.insert()
  end

  @doc "按 (bucket, key, upload_id) 取会话。"
  @spec get_upload(String.t(), String.t(), String.t()) :: {:ok, Upload.t()} | {:error, :not_found}
  def get_upload(bucket_name, key, upload_id) do
    case Repo.get_by(Upload, bucket_name: bucket_name, key: key, upload_id: upload_id) do
      nil -> {:error, :not_found}
      upload -> {:ok, upload}
    end
  end

  @doc "写入/覆盖一个 part 的元数据（按 (upload_id, part_number) upsert）。"
  @spec put_part(Upload.t(), pos_integer(), %{etag: String.t(), size: non_neg_integer()}) ::
          {:ok, Part.t()} | {:error, Ecto.Changeset.t()}
  def put_part(%Upload{id: uid}, part_number, %{etag: etag, size: size}) do
    %Part{}
    |> Part.changeset(%{upload_id: uid, part_number: part_number, etag: etag, size: size})
    |> Repo.insert(
      on_conflict: {:replace, [:etag, :size, :updated_at]},
      conflict_target: [:upload_id, :part_number]
    )
  end

  @doc """
  列出会话已上传 part（升序）。opts: :max_parts(默认1000), :part_number_marker(仅列更大的)。
  返回 %{parts, is_truncated, next_part_number_marker}。
  """
  @spec list_parts(Upload.t(), map()) :: %{
          parts: [Part.t()],
          is_truncated: boolean(),
          next_part_number_marker: pos_integer() | nil
        }
  def list_parts(%Upload{id: uid}, opts \\ %{}) do
    max_parts = Map.get(opts, :max_parts, 1000)
    marker = Map.get(opts, :part_number_marker, 0) || 0

    query =
      from p in Part,
        where: p.upload_id == ^uid and p.part_number > ^marker,
        order_by: [asc: p.part_number],
        limit: ^(max_parts + 1)

    all = Repo.all(query)
    truncated = length(all) > max_parts
    parts = Enum.take(all, max_parts)

    next = if truncated, do: List.last(parts).part_number, else: nil
    %{parts: parts, is_truncated: truncated, next_part_number_marker: next}
  end

  @doc """
  列出桶内进行中分段上传（按 key 升序、再按 initiated 升序）。
  opts: :prefix, :delimiter, :max_uploads(默认1000), :key_marker, :upload_id_marker。
  返回 %{uploads, common_prefixes, is_truncated, next_key_marker, next_upload_id_marker}。
  """
  @spec list_uploads(String.t(), map()) :: map()
  def list_uploads(bucket_name, opts \\ %{}) do
    prefix = Map.get(opts, :prefix, "") || ""
    delimiter = Map.get(opts, :delimiter)
    max_uploads = Map.get(opts, :max_uploads, 1000)
    key_marker = Map.get(opts, :key_marker)

    base =
      from u in Upload,
        where: u.bucket_name == ^bucket_name,
        order_by: [asc: u.key, asc: u.inserted_at]

    base =
      if prefix != "",
        do: where(base, [u], like(u.key, ^(escape_like(prefix) <> "%"))),
        else: base

    base = if key_marker, do: where(base, [u], u.key > ^key_marker), else: base

    # ROUTE B B1-3 临时硬 LIMIT 闸（同 Objects.list_objects_v2）：有界 SQL 取数防大桶 DoS。
    # capped? 时候选被截断，须强制截断+续点（不能宣称完整）。
    fetch_limit = list_fetch_limit(max_uploads)
    candidates = Repo.all(limit(base, ^fetch_limit))
    capped? = length(candidates) == fetch_limit

    {uploads, common_prefixes, truncated, next_key} =
      collapse_uploads(candidates, prefix, delimiter, max_uploads, capped?)

    %{
      uploads: uploads,
      common_prefixes: common_prefixes,
      is_truncated: truncated,
      next_key_marker: if(truncated, do: next_key, else: nil),
      next_upload_id_marker:
        if(truncated, do: (List.last(uploads) || %{}) |> Map.get(:upload_id), else: nil)
    }
  end

  @doc """
  完成分段上传：按客户端给的 requested_parts（[%{part_number, etag}]，须升序）校验后组装。
  返回 {:ok, %{etag, size, sse_envelope, version_id}} | {:error, reason}，reason ∈
  :no_such_upload | :invalid_part | :invalid_part_order | :entity_too_small | :no_parts。
  opts: :min_part_size（默认 5_242_880；测试可注入小值）、:version_id（最终对象版本路径，缺省 "null"）。
  """
  @spec complete(Upload.t(), [%{part_number: pos_integer(), etag: String.t()}], keyword()) ::
          {:ok,
           %{
             etag: String.t(),
             size: non_neg_integer(),
             sse_envelope: map() | nil,
             version_id: String.t()
           }}
          | {:error, atom()}
  def complete(%Upload{} = upload, requested_parts, opts \\ []) do
    min_part_size = Keyword.get(opts, :min_part_size, min_part_size())
    version_id = Keyword.get(opts, :version_id, "null")
    stored = list_all_parts(upload) |> Map.new(fn p -> {p.part_number, p} end)

    with :ok <- ensure_nonempty(requested_parts),
         :ok <- ensure_ascending(requested_parts),
         {:ok, ordered} <- match_parts(requested_parts, stored),
         :ok <- ensure_min_size(ordered, min_part_size) do
      part_numbers = Enum.map(ordered, & &1.part_number)
      visible_size = Enum.reduce(ordered, 0, fn part, acc -> acc + part.size end)
      md5_raws = Enum.map(ordered, fn p -> Base.decode16!(p.etag, case: :mixed) end)
      etag = multipart_etag(md5_raws)

      # ROUTE B B4-6 D1/B4-14：从 upload 会话取真实 content_type/user_metadata/SSE 构造 object_meta，经
      # Storage.assemble 或 SSE 加密后的 Storage.put 透传给后端，使多段完成对象的 maxio/2 sidecar 自描述真实元数据
      # （消除 :sidecar 读多段对象 content-type 回落 binary/octet-stream 的偏离）。caller opts（如测试注入的
      # transport/topology）一并转发到后端，object_meta 覆盖任何同名键（会话才是元数据权威）。
      # version_id 由 handler 按桶版本化状态生成并贯穿字节路径、sidecar 与 PG/索引；缺省 "null"
      # 保持内部/未版本化调用语义。
      # B6-2a：S3 多段 ETag（"...-N"）随 object_meta 透传后端——sidecar versions entry 的 S3 可见
      # etag 必须是多段形态（耐久 core 顶层 etag 仍为整体字节 MD5，完整性校验语义不动）。
      assemble_final_object(upload, part_numbers, etag, visible_size, version_id, opts)
    end
  end

  @doc "中止分段上传：删会话（级联删 part 元数据）+ 清理 part 字节。幂等。"
  @spec abort(Upload.t()) :: :ok
  def abort(%Upload{} = upload) do
    _ = Maxio.Storage.abort_upload(upload.bucket_name, upload.key, upload.upload_id)
    Repo.delete_all(from u in Upload, where: u.id == ^upload.id)
    :ok
  end

  @doc """
  multipart ETag = hex(MD5(concat(part 的 16 字节原始 MD5...)))-N（无引号）。
  """
  @spec multipart_etag([binary()]) :: String.t()
  def multipart_etag(part_md5_raws) when is_list(part_md5_raws) do
    n = length(part_md5_raws)
    concat = IO.iodata_to_binary(part_md5_raws)
    digest = :crypto.hash(:md5, concat) |> Base.encode16(case: :lower)
    "#{digest}-#{n}"
  end

  # ── 内部 ──

  defp assemble_final_object(
         %Upload{sse_algorithm: "AES256"} = upload,
         part_numbers,
         s3_etag,
         visible_size,
         version_id,
         opts
       ) do
    with {:ok, part_streams} <- part_streams(upload, part_numbers, opts) do
      plain_stream = Stream.flat_map(part_streams, fn stream -> stream end)
      {cipher_stream, sse_envelope} = CryptoSSE.wrap_stream(plain_stream)

      put_opts =
        Keyword.put(
          opts,
          :object_meta,
          assemble_object_meta(upload, s3_etag, sse_envelope, visible_size)
        )

      case Maxio.Storage.put(upload.bucket_name, upload.key, version_id, cipher_stream, put_opts) do
        {:ok, %{size: _stored_size} = write_result} ->
          # part 字节清理 + 会话/分块元数据删除统一由调用方 handler 的 Multipart.abort/1 负责
          # （单一职责，不在此重复 abort_upload）。
          {:ok,
           %{
             etag: s3_etag,
             size: visible_size,
             sse_envelope: sse_envelope,
             version_id: version_id,
             placement_set_id: Map.get(write_result, :placement_set_id),
             placement_pool_id: Map.get(write_result, :placement_pool_id),
             placement_topology_hash: Map.get(write_result, :placement_topology_hash)
           }}

        {:error, _} = err ->
          err
      end
    end
  end

  defp assemble_final_object(
         %Upload{} = upload,
         part_numbers,
         s3_etag,
         _visible_size,
         version_id,
         opts
       ) do
    assemble_opts =
      opts
      |> Keyword.put(:version_id, version_id)
      |> Keyword.put(:object_meta, assemble_object_meta(upload, s3_etag, nil, nil))

    case Maxio.Storage.assemble(
           upload.bucket_name,
           upload.key,
           upload.upload_id,
           part_numbers,
           assemble_opts
         ) do
      {:ok, %{size: size} = write_result} ->
        # part 字节清理 + 会话/分块元数据删除统一由调用方 handler 的 Multipart.abort/1 负责
        # （单一职责，不在此重复 abort_upload）。
        {:ok,
         %{
           etag: s3_etag,
           size: size,
           sse_envelope: nil,
           version_id: version_id,
           placement_set_id: Map.get(write_result, :placement_set_id),
           placement_pool_id: Map.get(write_result, :placement_pool_id),
           placement_topology_hash: Map.get(write_result, :placement_topology_hash)
         }}

      {:error, _} = err ->
        err
    end
  end

  defp part_streams(%Upload{} = upload, part_numbers, opts) do
    Enum.reduce_while(part_numbers, {:ok, []}, fn part_number, {:ok, acc} ->
      case Maxio.Storage.get_part_stream(
             upload.bucket_name,
             upload.key,
             upload.upload_id,
             part_number,
             opts
           ) do
        {:ok, stream} -> {:cont, {:ok, [stream | acc]}}
        {:error, _reason} -> {:halt, {:error, :invalid_part}}
      end
    end)
    |> case do
      {:ok, streams} -> {:ok, Enum.reverse(streams)}
      {:error, _} = err -> err
    end
  end

  # ROUTE B B4-6 D1：从 upload 会话构造透传给 Storage.assemble/put 的 object_meta（形状对齐
  # Maxio.Storage.Backend 的 :object_meta 契约）。content_type/storage_class/user_metadata 取自
  # CreateMultipartUpload 落盘的会话行（handlers/multipart.ex initiate）；SSE-S3 会话在 Complete 时
  # 生成 envelope 后写入 sidecar/PG；per-key ACL 默认 private；会话表无 tags 列故 tags=%{}（多段 tagging 留后续里程碑）。
  # B6-2a：:etag = S3 多段 ETag（hex(MD5(concat part MD5s))-N）——后端 version_opts 据此让 sidecar
  # versions entry 的 S3 可见 etag 取多段形态（PG 路径早已如此；:read=:sidecar 下 GET/HEAD/LIST 的
  # ETag 头才与 AWS/MinIO 一致）；耐久 core 顶层 etag 仍由后端写整体字节 MD5（完整性校验语义不变）。
  defp assemble_object_meta(%Upload{} = upload, s3_etag, sse_envelope, visible_size) do
    %{
      size: visible_size,
      content_type: upload.content_type || "binary/octet-stream",
      content_encoding: upload.content_encoding,
      content_disposition: upload.content_disposition,
      cache_control: upload.cache_control,
      expires: upload.expires,
      tags: %{},
      sse: sse_meta(upload.sse_algorithm, sse_envelope),
      acl_canned: upload.acl_canned || "private",
      acl_grants: upload.acl_grants || %{"grants" => []},
      storage_class: upload.storage_class || "STANDARD",
      user_metadata: upload.metadata || %{},
      etag: s3_etag
    }
  end

  defp sse_meta(nil, _envelope), do: nil
  defp sse_meta("", _envelope), do: nil
  defp sse_meta(algo, envelope), do: %{"algo" => algo, "envelope" => envelope}

  defp list_all_parts(%Upload{id: uid}) do
    Repo.all(from p in Part, where: p.upload_id == ^uid, order_by: [asc: p.part_number])
  end

  defp ensure_nonempty([]), do: {:error, :no_parts}
  defp ensure_nonempty(_), do: :ok

  defp ensure_ascending(parts) do
    nums = Enum.map(parts, & &1.part_number)

    if nums == Enum.sort(nums) and length(Enum.uniq(nums)) == length(nums),
      do: :ok,
      else: {:error, :invalid_part_order}
  end

  # 把客户端请求 part 与存储 part 对齐：每个请求 part 必须存在且 ETag 匹配（规范化去引号比较）。
  defp match_parts(requested, stored) do
    Enum.reduce_while(requested, {:ok, []}, fn req, {:ok, acc} ->
      case Map.get(stored, req.part_number) do
        nil ->
          {:halt, {:error, :invalid_part}}

        %Part{} = p ->
          if normalize_etag(p.etag) == normalize_etag(req.etag) do
            {:cont, {:ok, [p | acc]}}
          else
            {:halt, {:error, :invalid_part}}
          end
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      err -> err
    end
  end

  # 非末 part 必须 ≥ min_part_size（末 part 任意）。
  defp ensure_min_size(ordered, min_part_size) do
    non_last = Enum.drop(ordered, -1)

    if Enum.all?(non_last, fn p -> p.size >= min_part_size end) do
      :ok
    else
      {:error, :entity_too_small}
    end
  end

  defp normalize_etag(etag), do: etag |> to_string() |> String.trim("\"") |> String.downcase()

  defp generate_upload_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end

  defp escape_like(str) do
    str
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  # ROUTE B B1-3 SQL LIST 临时硬 LIMIT 闸（同 Objects.list_fetch_limit/1）：
  # min(sql_hard_limit, max_uploads*4+1000)，折叠 delimiter 余量 *4+1000，上限防 DoS。
  defp list_fetch_limit(max_uploads) do
    hard_limit = Application.get_env(:maxio, :listing, [])[:sql_hard_limit] || 100_000
    min(hard_limit, max_uploads * 4 + 1000)
  end

  defp min_part_size do
    Application.get_env(:maxio, :multipart_min_part_size, @default_min_part_size)
  end

  # ListMultipartUploads 的 delimiter 折叠（与 Objects.list_objects_v2 同构）。
  # capped? = SQL 候选被 fetch_limit 截断；候选耗尽却未达 max 时不能宣称完整。
  defp collapse_uploads(candidates, prefix, delimiter, max, capped?) do
    do_collapse_uploads(candidates, prefix, delimiter, max, [], MapSet.new(), [], nil, capped?)
  end

  # 候选耗尽。capped? 为真说明 SQL LIMIT 可能在攒满 max 前就截断了候选——无法证明完整，
  # 强制 is_truncated=true + 续点（最后已折叠 key），否则才 false。
  defp do_collapse_uploads([], _prefix, _delim, _max, ups, _seen, cps, last, capped?) do
    if capped? do
      {Enum.reverse(ups), Enum.reverse(cps), true, last || previous_key(ups, cps)}
    else
      {Enum.reverse(ups), Enum.reverse(cps), false, nil}
    end
  end

  defp do_collapse_uploads([u | rest], prefix, delimiter, max, ups, seen, cps, _last, capped?) do
    count = length(ups) + MapSet.size(seen)

    cond do
      count >= max ->
        last_key = previous_key(ups, cps)
        {Enum.reverse(ups), Enum.reverse(cps), true, last_key}

      true ->
        case common_prefix_of(u.key, prefix, delimiter) do
          nil ->
            do_collapse_uploads(
              rest,
              prefix,
              delimiter,
              max,
              [u | ups],
              seen,
              cps,
              u.key,
              capped?
            )

          cp ->
            if MapSet.member?(seen, cp) do
              do_collapse_uploads(rest, prefix, delimiter, max, ups, seen, cps, cp, capped?)
            else
              do_collapse_uploads(
                rest,
                prefix,
                delimiter,
                max,
                ups,
                MapSet.put(seen, cp),
                [cp | cps],
                cp,
                capped?
              )
            end
        end
    end
  end

  defp common_prefix_of(_key, _prefix, nil), do: nil

  defp common_prefix_of(key, prefix, delimiter) do
    rest = String.replace_prefix(key, prefix, "")

    case :binary.match(rest, delimiter) do
      {pos, len} -> prefix <> binary_part(rest, 0, pos + len)
      :nomatch -> nil
    end
  end

  defp previous_key([u | _], _cps), do: u.key
  defp previous_key([], [cp | _]), do: cp
  defp previous_key([], []), do: nil
end
