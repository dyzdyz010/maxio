defmodule Maxio.Multipart do
  @moduledoc """
  分段上传元数据上下文：initiate/get/put_part(元数据)/list_parts/list_uploads/complete/abort
  + multipart ETag 算法。分块字节走 Maxio.Storage（FS parts 回调），本上下文管会话与分块元数据
  及 Complete 时的校验（InvalidPart/InvalidPartOrder/EntityTooSmall/NoSuchUpload，铁律 3）。
  """
  import Ecto.Query
  alias Maxio.Cluster.Placement
  alias Maxio.Crypto.SSE, as: CryptoSSE
  alias Maxio.Repo
  alias Maxio.Multipart.{Upload, Part}
  alias Maxio.S3.Checksum
  alias Maxio.S3.SSE
  alias Maxio.S3.SystemHeaders

  @default_min_part_size 5_242_880
  @max_uploads_limit 1000
  @part_checksum_fields ~w(
    ChecksumCRC32
    ChecksumCRC32C
    ChecksumCRC64NVME
    ChecksumMD5
    ChecksumSHA1
    ChecksumSHA256
    ChecksumSHA512
    ChecksumXXHASH128
    ChecksumXXHASH3
    ChecksumXXHASH64
  )

  @doc "发起分段上传：生成 UploadId（UUID hex），落会话元数据。"
  @spec initiate(String.t(), String.t(), map(), keyword()) ::
          {:ok, Upload.t()} | {:error, Ecto.Changeset.t() | term()}
  def initiate(bucket_name, key, attrs \\ %{}, opts \\ []) do
    do_initiate(bucket_name, key, attrs, opts, nil)
  end

  @doc """
  Initiates a multipart upload and runs `after_insert` in the same DB transaction.

  Storage placement is resolved before the DB transaction because it has no DB
  side effect. The upload row and the hook's DB writes commit or rollback as a
  single unit.
  """
  @spec initiate_with(String.t(), String.t(), map(), (Upload.t() -> term()), keyword()) ::
          {:ok, Upload.t()} | {:error, Ecto.Changeset.t() | term()}
  def initiate_with(bucket_name, key, attrs, after_insert, opts \\ [])
      when is_function(after_insert, 1) do
    do_initiate(bucket_name, key, attrs, opts, after_insert)
  end

  defp do_initiate(bucket_name, key, attrs, opts, after_insert) do
    upload_id = generate_upload_id()

    with {:ok, placement} <- Placement.resolve_write(bucket_name, upload_key(upload_id), opts) do
      base =
        %{
          upload_id: upload_id,
          bucket_name: bucket_name,
          key: key,
          content_type: Map.get(attrs, :content_type, "binary/octet-stream"),
          storage_class: Map.get(attrs, :storage_class, "STANDARD"),
          sse_algorithm: Map.get(attrs, :sse_algorithm),
          sse_envelope: Map.get(attrs, :sse_envelope),
          owner: Map.get(attrs, :owner, "arn:aws:iam:::root"),
          acl_canned: Map.get(attrs, :acl_canned, "private"),
          acl_grants: Map.get(attrs, :acl_grants, %{"grants" => []}),
          metadata: Map.get(attrs, :metadata, %{}),
          tags: Map.get(attrs, :tags, %{}),
          checksum_algorithm: Map.get(attrs, :checksum_algorithm),
          checksum_type: Map.get(attrs, :checksum_type)
        }
        |> Map.merge(SystemHeaders.take(attrs))
        |> Map.merge(Placement.attrs_from_result(placement))

      changeset = Upload.changeset(%Upload{}, base)

      case after_insert do
        nil -> Repo.insert(changeset)
        callback -> insert_with_after_insert(changeset, callback)
      end
    end
  end

  defp insert_with_after_insert(changeset, callback) do
    Repo.transaction(fn ->
      case Repo.insert(changeset) do
        {:ok, upload} -> run_after_insert!(callback, upload)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp run_after_insert!(callback, upload) do
    case callback.(upload) do
      :ok -> upload
      {:ok, _result} -> upload
      {:error, reason} -> Repo.rollback(reason)
      other -> Repo.rollback({:invalid_after_insert_result, other})
    end
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
  def put_part(%Upload{id: uid} = upload, part_number, %{etag: etag, size: size} = attrs) do
    stored_checksum =
      attrs
      |> Map.get(:checksum, %{})
      |> SSE.checksum_for_storage(upload.sse_algorithm, upload.sse_envelope)

    result =
      %Part{}
      |> Part.changeset(%{upload_id: uid, part_number: part_number, etag: etag, size: size})
      |> Ecto.Changeset.put_change(:checksum, stored_checksum)
      |> Repo.insert(
        on_conflict: {:replace, [:etag, :size, :checksum, :updated_at]},
        conflict_target: [:upload_id, :part_number]
      )

    case result do
      {:ok, %Part{} = part} -> {:ok, part_with_visible_checksum(upload, part)}
      other -> other
    end
  end

  @doc "Count active multipart upload sessions persisted on the given placement set."
  @spec count_uploads_with_placement_set(integer()) :: non_neg_integer()
  def count_uploads_with_placement_set(set_id) when is_integer(set_id) do
    query =
      from u in Upload,
        where: u.placement_set_id == ^set_id

    Repo.aggregate(query, :count, :id)
  end

  @doc "Count all active multipart upload sessions."
  @spec count_uploads() :: non_neg_integer()
  def count_uploads, do: Repo.aggregate(Upload, :count, :id)

  @doc "Count active multipart upload sessions that lack a persisted placement set."
  @spec count_uploads_missing_placement_set() :: non_neg_integer()
  def count_uploads_missing_placement_set do
    query =
      from u in Upload,
        where: is_nil(u.placement_set_id)

    Repo.aggregate(query, :count, :id)
  end

  @doc "Count active multipart upload sessions pointing outside the configured topology."
  @spec count_uploads_with_unknown_placement_set([integer()]) :: non_neg_integer()
  def count_uploads_with_unknown_placement_set(set_ids) when is_list(set_ids) do
    query =
      from u in Upload,
        where: not is_nil(u.placement_set_id) and u.placement_set_id not in ^set_ids

    Repo.aggregate(query, :count, :id)
  end

  @doc "Count active multipart upload sessions written under another topology hash."
  @spec count_uploads_with_placement_topology_hash_mismatch(String.t()) :: non_neg_integer()
  def count_uploads_with_placement_topology_hash_mismatch(topology_hash)
      when is_binary(topology_hash) do
    query =
      from u in Upload,
        where: is_nil(u.placement_topology_hash) or u.placement_topology_hash != ^topology_hash

    Repo.aggregate(query, :count, :id)
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
  def list_parts(%Upload{id: uid} = upload, opts \\ %{}) do
    max_parts = Map.get(opts, :max_parts, 1000)
    marker = Map.get(opts, :part_number_marker, 0) || 0

    query =
      from p in Part,
        where: p.upload_id == ^uid and p.part_number > ^marker,
        order_by: [asc: p.part_number],
        limit: ^(max_parts + 1)

    all = Repo.all(query)
    truncated = length(all) > max_parts

    parts =
      all
      |> Enum.take(max_parts)
      |> Enum.map(&part_with_visible_checksum(upload, &1))

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
    max_uploads = normalize_max_uploads(Map.get(opts, :max_uploads, @max_uploads_limit))
    key_marker = Map.get(opts, :key_marker)
    upload_id_marker = Map.get(opts, :upload_id_marker)

    base =
      from u in Upload,
        where: u.bucket_name == ^bucket_name,
        order_by: [asc: u.key, asc: u.inserted_at, asc: u.upload_id]

    base =
      if prefix != "",
        do: where(base, [u], like(u.key, ^(escape_like(prefix) <> "%"))),
        else: base

    marker_upload =
      if key_marker && upload_id_marker do
        Repo.get_by(Upload,
          bucket_name: bucket_name,
          key: key_marker,
          upload_id: upload_id_marker
        )
      end

    base =
      cond do
        key_marker && upload_id_marker && marker_upload ->
          marker_inserted_at = marker_upload.inserted_at

          where(
            base,
            [u],
            u.key > ^key_marker or
              (u.key == ^key_marker and
                 (u.inserted_at > ^marker_inserted_at or
                    (u.inserted_at == ^marker_inserted_at and
                       u.upload_id > ^upload_id_marker)))
          )

        key_marker ->
          where(base, [u], u.key > ^key_marker)

        true ->
          base
      end

    # ROUTE B B1-3 临时硬 LIMIT 闸（同 Objects.list_objects_v2）：有界 SQL 取数防大桶 DoS。
    # capped? 时候选被截断，须强制截断+续点（不能宣称完整）。
    fetch_limit = list_fetch_limit(max_uploads)
    candidates = Repo.all(limit(base, ^fetch_limit))
    capped? = length(candidates) == fetch_limit

    {uploads, common_prefixes, truncated, next_key, next_upload_id} =
      collapse_uploads(candidates, prefix, delimiter, max_uploads, capped?, key_marker)

    %{
      uploads: uploads,
      common_prefixes: common_prefixes,
      is_truncated: truncated,
      next_key_marker: if(truncated, do: next_key, else: nil),
      next_upload_id_marker: if(truncated, do: next_upload_id, else: nil)
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
    complete_checksum_request = Keyword.get(opts, :complete_checksum_request, %{})

    stored =
      upload
      |> list_all_parts()
      |> Enum.map(&part_with_visible_checksum(upload, &1))
      |> Map.new(fn p -> {p.part_number, p} end)

    with :ok <- ensure_nonempty(requested_parts),
         :ok <- ensure_ascending(requested_parts),
         :ok <- ensure_consecutive_checksum_parts(requested_parts),
         {:ok, ordered} <- match_parts(requested_parts, stored),
         :ok <- ensure_consecutive_checksum_parts(ordered),
         :ok <- ensure_upload_checksum_intent(upload, ordered),
         :ok <- ensure_supported_complete_checksum(upload, ordered),
         :ok <- ensure_min_size(ordered, min_part_size) do
      part_numbers = Enum.map(ordered, & &1.part_number)
      visible_size = Enum.reduce(ordered, 0, fn part, acc -> acc + part.size end)
      md5_raws = Enum.map(ordered, fn p -> Base.decode16!(p.etag, case: :mixed) end)
      etag = multipart_etag(md5_raws)
      object_parts = completed_object_parts(ordered)

      with {:ok, checksum} <- complete_object_checksum(upload, object_parts),
           :ok <-
             ensure_complete_checksum_request(
               upload,
               complete_checksum_request,
               visible_size,
               checksum
             ) do
        object_meta_extra_info = %{
          size: visible_size,
          etag: etag,
          version_id: version_id,
          checksum: checksum,
          object_parts: object_parts
        }

        # ROUTE B B4-6 D1/B4-14：从 upload 会话取真实 content_type/user_metadata/SSE 构造 object_meta，经
        # Storage.assemble 或 SSE 加密后的 Storage.put 透传给后端，使多段完成对象的 maxio/2 sidecar 自描述真实元数据
        # （消除 :sidecar 读多段对象 content-type 回落 binary/octet-stream 的偏离）。caller opts（如测试注入的
        # transport/topology）一并转发到后端，object_meta 覆盖任何同名键（会话才是元数据权威）。
        # version_id 由 handler 按桶版本化状态生成并贯穿字节路径、sidecar 与 PG/索引；缺省 "null"
        # 保持内部/未版本化调用语义。
        # B6-2a：S3 多段 ETag（"...-N"）随 object_meta 透传后端——sidecar versions entry 的 S3 可见
        # etag 必须是多段形态（耐久 core 顶层 etag 仍为整体字节 MD5，完整性校验语义不动）。
        assemble_final_object(
          upload,
          part_numbers,
          etag,
          visible_size,
          version_id,
          object_parts,
          checksum,
          opts
          |> Keyword.put(:complete_checksum_request, complete_checksum_request)
          |> Keyword.put(:object_meta_extra_info, object_meta_extra_info)
        )
      end
    end
  end

  @doc "中止分段上传：删会话（级联删 part 元数据）+ 清理 part 字节。幂等。"
  @spec abort(Upload.t(), keyword()) :: :ok | {:error, term()}
  def abort(%Upload{} = upload, opts \\ []) do
    with :ok <-
           storage_abort_upload(upload, opts) do
      Repo.delete_all(from u in Upload, where: u.id == ^upload.id)
      :ok
    end
  end

  @doc """
  Cleans up multipart session metadata after a terminal operation has already
  committed its authority elsewhere.

  Unlike explicit abort, DB session removal is unconditional so a successfully
  completed upload cannot remain listable as active when byte cleanup fails.
  The storage cleanup result is returned for structured logging / later GC.
  """
  @spec cleanup_after_terminal(Upload.t(), keyword()) :: :ok | {:error, term()}
  def cleanup_after_terminal(%Upload{} = upload, opts \\ []) do
    result = safe_storage_abort_upload(upload, opts)
    Repo.delete_all(from u in Upload, where: u.id == ^upload.id)
    result
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
         %Upload{checksum_type: "FULL_OBJECT"} = upload,
         part_numbers,
         s3_etag,
         visible_size,
         version_id,
         object_parts,
         :full_object,
         opts
       ) do
    safe_opts = storage_safe_opts(opts)

    with {:ok, part_streams} <-
           plaintext_part_streams(
             upload,
             part_numbers,
             with_upload_opts(upload, safe_opts),
             Keyword.get(opts, :sse_customer_key)
           ) do
      plain_stream = Stream.flat_map(part_streams, fn stream -> stream end)

      checksum =
        Checksum.full_object_multipart_context!(
          upload.checksum_algorithm,
          Keyword.get(opts, :complete_checksum_request, %{})
        )

      {checksummed_stream, get_checksum, discard_checksum} =
        Checksum.wrap_stream(plain_stream, checksum)

      {payload_stream, sse_envelope} =
        case upload.sse_algorithm do
          "AES256" ->
            CryptoSSE.wrap_stream(checksummed_stream)

          "aws:kms" ->
            CryptoSSE.wrap_stream_with_kms_key(
              checksummed_stream,
              kms_key_id(upload),
              kms_context_b64(upload),
              bucket_key_enabled: kms_bucket_key_enabled?(upload)
            )

          "aws:kms:dsse" ->
            CryptoSSE.wrap_stream_with_dsse_kms_key(
              checksummed_stream,
              kms_key_id(upload),
              kms_context_b64(upload)
            )

          "SSE-C" ->
            CryptoSSE.wrap_stream_with_customer_key(
              checksummed_stream,
              Keyword.fetch!(opts, :sse_customer_key),
              customer_key_md5_b64(upload)
            )

          _ ->
            {checksummed_stream, nil}
        end

      put_opts =
        upload
        |> with_upload_opts(safe_opts)
        |> Keyword.put(
          :object_meta,
          assemble_object_meta(
            upload,
            s3_etag,
            sse_envelope,
            visible_size,
            object_parts,
            %{},
            safe_opts
          )
        )
        |> Keyword.put(:before_object_commit, fn write_result ->
          checksum = get_checksum.()
          :ok = checksum.verify!.()
          checksum_metadata = Checksum.object_metadata(checksum)
          extra = complete_object_meta_extra(safe_opts, write_result)

          object_meta =
            Map.merge(Map.get(extra, :object_meta, %{}) || %{}, %{
              checksum:
                SSE.checksum_for_storage(
                  checksum_metadata,
                  upload.sse_algorithm,
                  sse_envelope
                )
            })

          extra
          |> Map.merge(%{
            checksum_metadata: checksum_metadata,
            object_meta: object_meta
          })
        end)

      put_result =
        try do
          Maxio.Storage.put(upload.bucket_name, upload.key, version_id, payload_stream, put_opts)
        rescue
          err ->
            discard_checksum.()
            reraise(err, __STACKTRACE__)
        catch
          kind, reason ->
            discard_checksum.()
            :erlang.raise(kind, reason, __STACKTRACE__)
        end

      case put_result do
        {:ok, %{size: _stored_size} = write_result} ->
          checksum = Map.get(write_result, :checksum_metadata, %{})

          {:ok,
           %{
             etag: s3_etag,
             size: visible_size,
             checksum: checksum,
             object_parts: object_parts,
             sse_envelope: sse_envelope,
             version_id: version_id,
             placement_set_id: Map.get(write_result, :placement_set_id),
             placement_pool_id: Map.get(write_result, :placement_pool_id),
             placement_topology_hash: Map.get(write_result, :placement_topology_hash),
             notification_outbox: notification_outbox(write_result),
             notification_retained_ledger: notification_retained_ledger(write_result)
           }}

        {:error, _} = err ->
          discard_checksum.()
          err
      end
    end
  end

  defp assemble_final_object(
         %Upload{sse_algorithm: "SSE-C"} = upload,
         part_numbers,
         s3_etag,
         visible_size,
         version_id,
         object_parts,
         checksum,
         opts
       ) do
    customer_key = Keyword.fetch!(opts, :sse_customer_key)
    safe_opts = storage_safe_opts(opts)

    with {:ok, part_streams} <-
           plaintext_part_streams(
             upload,
             part_numbers,
             with_upload_opts(upload, safe_opts),
             customer_key
           ) do
      plain_stream = Stream.flat_map(part_streams, fn stream -> stream end)

      {cipher_stream, sse_envelope} =
        CryptoSSE.wrap_stream_with_customer_key(
          plain_stream,
          customer_key,
          customer_key_md5_b64(upload)
        )

      put_opts =
        Keyword.put(
          safe_opts,
          :object_meta,
          assemble_object_meta(
            upload,
            s3_etag,
            sse_envelope,
            visible_size,
            object_parts,
            checksum,
            safe_opts
          )
        )
        |> Keyword.put(:before_object_commit, fn write_result ->
          complete_object_meta_extra(safe_opts, write_result)
        end)

      case Maxio.Storage.put(upload.bucket_name, upload.key, version_id, cipher_stream, put_opts) do
        {:ok, %{size: _stored_size} = write_result} ->
          {:ok,
           %{
             etag: s3_etag,
             size: visible_size,
             checksum: checksum,
             object_parts: object_parts,
             sse_envelope: sse_envelope,
             version_id: version_id,
             placement_set_id: Map.get(write_result, :placement_set_id),
             placement_pool_id: Map.get(write_result, :placement_pool_id),
             placement_topology_hash: Map.get(write_result, :placement_topology_hash),
             notification_outbox: notification_outbox(write_result),
             notification_retained_ledger: notification_retained_ledger(write_result)
           }}

        {:error, _} = err ->
          err
      end
    end
  end

  defp assemble_final_object(
         %Upload{sse_algorithm: "aws:kms"} = upload,
         part_numbers,
         s3_etag,
         visible_size,
         version_id,
         object_parts,
         checksum,
         opts
       ) do
    safe_opts = storage_safe_opts(opts)

    with {:ok, part_streams} <-
           plaintext_part_streams(
             upload,
             part_numbers,
             with_upload_opts(upload, safe_opts),
             nil
           ) do
      plain_stream = Stream.flat_map(part_streams, fn stream -> stream end)

      {cipher_stream, sse_envelope} =
        CryptoSSE.wrap_stream_with_kms_key(
          plain_stream,
          kms_key_id(upload),
          kms_context_b64(upload),
          bucket_key_enabled: kms_bucket_key_enabled?(upload)
        )

      put_opts =
        Keyword.put(
          safe_opts,
          :object_meta,
          assemble_object_meta(
            upload,
            s3_etag,
            sse_envelope,
            visible_size,
            object_parts,
            checksum,
            safe_opts
          )
        )
        |> Keyword.put(:before_object_commit, fn write_result ->
          complete_object_meta_extra(safe_opts, write_result)
        end)

      case Maxio.Storage.put(upload.bucket_name, upload.key, version_id, cipher_stream, put_opts) do
        {:ok, %{size: _stored_size} = write_result} ->
          {:ok,
           %{
             etag: s3_etag,
             size: visible_size,
             checksum: checksum,
             object_parts: object_parts,
             sse_envelope: sse_envelope,
             version_id: version_id,
             placement_set_id: Map.get(write_result, :placement_set_id),
             placement_pool_id: Map.get(write_result, :placement_pool_id),
             placement_topology_hash: Map.get(write_result, :placement_topology_hash),
             notification_outbox: notification_outbox(write_result),
             notification_retained_ledger: notification_retained_ledger(write_result)
           }}

        {:error, _} = err ->
          err
      end
    end
  end

  defp assemble_final_object(
         %Upload{sse_algorithm: "aws:kms:dsse"} = upload,
         part_numbers,
         s3_etag,
         visible_size,
         version_id,
         object_parts,
         checksum,
         opts
       ) do
    safe_opts = storage_safe_opts(opts)

    with {:ok, part_streams} <-
           plaintext_part_streams(
             upload,
             part_numbers,
             with_upload_opts(upload, safe_opts),
             nil
           ) do
      plain_stream = Stream.flat_map(part_streams, fn stream -> stream end)

      {cipher_stream, sse_envelope} =
        CryptoSSE.wrap_stream_with_dsse_kms_key(
          plain_stream,
          kms_key_id(upload),
          kms_context_b64(upload)
        )

      put_opts =
        Keyword.put(
          safe_opts,
          :object_meta,
          assemble_object_meta(
            upload,
            s3_etag,
            sse_envelope,
            visible_size,
            object_parts,
            checksum,
            safe_opts
          )
        )
        |> Keyword.put(:before_object_commit, fn write_result ->
          complete_object_meta_extra(safe_opts, write_result)
        end)

      case Maxio.Storage.put(upload.bucket_name, upload.key, version_id, cipher_stream, put_opts) do
        {:ok, %{size: _stored_size} = write_result} ->
          {:ok,
           %{
             etag: s3_etag,
             size: visible_size,
             checksum: checksum,
             object_parts: object_parts,
             sse_envelope: sse_envelope,
             version_id: version_id,
             placement_set_id: Map.get(write_result, :placement_set_id),
             placement_pool_id: Map.get(write_result, :placement_pool_id),
             placement_topology_hash: Map.get(write_result, :placement_topology_hash),
             notification_outbox: notification_outbox(write_result),
             notification_retained_ledger: notification_retained_ledger(write_result)
           }}

        {:error, _} = err ->
          err
      end
    end
  end

  defp assemble_final_object(
         %Upload{sse_algorithm: "AES256"} = upload,
         part_numbers,
         s3_etag,
         visible_size,
         version_id,
         object_parts,
         checksum,
         opts
       ) do
    with {:ok, part_streams} <- part_streams(upload, part_numbers, with_upload_opts(upload, opts)) do
      plain_stream = Stream.flat_map(part_streams, fn stream -> stream end)
      {cipher_stream, sse_envelope} = CryptoSSE.wrap_stream(plain_stream)

      put_opts =
        Keyword.put(
          opts,
          :object_meta,
          assemble_object_meta(
            upload,
            s3_etag,
            sse_envelope,
            visible_size,
            object_parts,
            checksum,
            opts
          )
        )
        |> Keyword.put(:before_object_commit, fn write_result ->
          complete_object_meta_extra(opts, write_result)
        end)

      case Maxio.Storage.put(upload.bucket_name, upload.key, version_id, cipher_stream, put_opts) do
        {:ok, %{size: _stored_size} = write_result} ->
          # part 字节清理 + 会话/分块元数据删除统一由调用方 handler 的 Multipart.abort/1 负责
          # （单一职责，不在此重复 abort_upload）。
          {:ok,
           %{
             etag: s3_etag,
             size: visible_size,
             checksum: checksum,
             object_parts: object_parts,
             sse_envelope: sse_envelope,
             version_id: version_id,
             placement_set_id: Map.get(write_result, :placement_set_id),
             placement_pool_id: Map.get(write_result, :placement_pool_id),
             placement_topology_hash: Map.get(write_result, :placement_topology_hash),
             notification_outbox: notification_outbox(write_result),
             notification_retained_ledger: notification_retained_ledger(write_result)
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
         object_parts,
         checksum,
         opts
       ) do
    assemble_opts =
      opts
      |> with_upload_opts(upload)
      |> Keyword.put(:version_id, version_id)
      |> Keyword.put(:before_object_commit, fn write_result ->
        complete_object_meta_extra(opts, write_result)
      end)
      |> Keyword.put(
        :object_meta,
        assemble_object_meta(upload, s3_etag, nil, nil, object_parts, checksum, opts)
      )

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
           checksum: checksum,
           object_parts: object_parts,
           sse_envelope: nil,
           version_id: version_id,
           placement_set_id: Map.get(write_result, :placement_set_id),
           placement_pool_id: Map.get(write_result, :placement_pool_id),
           placement_topology_hash: Map.get(write_result, :placement_topology_hash),
           notification_outbox: notification_outbox(write_result),
           notification_retained_ledger: notification_retained_ledger(write_result)
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

  defp plaintext_part_streams(
         %Upload{sse_algorithm: "SSE-C"} = upload,
         part_numbers,
         opts,
         customer_key
       )
       when is_binary(customer_key) and byte_size(customer_key) == 32 do
    with {:ok, streams} <- part_streams(upload, part_numbers, opts) do
      {:ok,
       Enum.map(streams, fn stream ->
         CryptoSSE.unwrap_stream_with_customer_key(stream, upload.sse_envelope, customer_key)
       end)}
    end
  end

  defp plaintext_part_streams(%Upload{sse_algorithm: "SSE-C"}, _part_numbers, _opts, _key),
    do: {:error, :invalid_part}

  defp plaintext_part_streams(
         %Upload{sse_algorithm: "aws:kms", sse_envelope: %{} = envelope} = upload,
         part_numbers,
         opts,
         _customer_key
       ) do
    with {:ok, streams} <- part_streams(upload, part_numbers, opts) do
      {:ok,
       Enum.map(streams, fn stream ->
         CryptoSSE.unwrap_stream_with_kms_key(stream, envelope)
       end)}
    end
  end

  defp plaintext_part_streams(%Upload{sse_algorithm: "aws:kms"}, _part_numbers, _opts, _key),
    do: {:error, :invalid_part}

  defp plaintext_part_streams(
         %Upload{sse_algorithm: "aws:kms:dsse", sse_envelope: %{} = envelope} = upload,
         part_numbers,
         opts,
         _customer_key
       ) do
    with {:ok, streams} <- part_streams(upload, part_numbers, opts) do
      {:ok,
       Enum.map(streams, fn stream ->
         CryptoSSE.unwrap_stream_with_dsse_kms_key(stream, envelope)
       end)}
    end
  end

  defp plaintext_part_streams(%Upload{sse_algorithm: "aws:kms:dsse"}, _part_numbers, _opts, _key),
    do: {:error, :invalid_part}

  defp plaintext_part_streams(%Upload{} = upload, part_numbers, opts, _customer_key),
    do: part_streams(upload, part_numbers, opts)

  defp customer_key_md5_b64(%Upload{sse_envelope: %{} = envelope}) do
    Map.get(envelope, :customer_key_md5_b64) || Map.get(envelope, "customer_key_md5_b64")
  end

  defp kms_key_id(%Upload{sse_envelope: %{} = envelope}),
    do: SSE.kms_key_id(envelope) || Maxio.KMS.default_key_id()

  defp kms_context_b64(%Upload{sse_envelope: %{} = envelope}),
    do: SSE.kms_encryption_context(envelope)

  defp kms_bucket_key_enabled?(%Upload{sse_envelope: %{} = envelope}),
    do: SSE.kms_bucket_key_enabled?(envelope)

  # ROUTE B B4-6 D1：从 upload 会话构造透传给 Storage.assemble/put 的 object_meta（形状对齐
  # Maxio.Storage.Backend 的 :object_meta 契约）。content_type/storage_class/user_metadata 取自
  # CreateMultipartUpload 落盘的会话行（handlers/multipart.ex initiate）；SSE-S3 会话在 Complete 时
  # 生成 envelope 后写入 sidecar/PG；per-key ACL 默认 private；tag-set 取自 CreateMultipartUpload 会话。
  # B6-2a：:etag = S3 多段 ETag（hex(MD5(concat part MD5s))-N）——后端 version_opts 据此让 sidecar
  # versions entry 的 S3 可见 etag 取多段形态（PG 路径早已如此；:read=:sidecar 下 GET/HEAD/LIST 的
  # ETag 头才与 AWS/MinIO 一致）；耐久 core 顶层 etag 仍由后端写整体字节 MD5（完整性校验语义不变）。
  defp assemble_object_meta(
         %Upload{} = upload,
         s3_etag,
         sse_envelope,
         visible_size,
         object_parts,
         checksum,
         opts
       ) do
    %{
      size: visible_size,
      content_type: upload.content_type || "binary/octet-stream",
      content_encoding: upload.content_encoding,
      content_disposition: upload.content_disposition,
      cache_control: upload.cache_control,
      expires: upload.expires,
      website_redirect_location: upload.website_redirect_location,
      tags: upload.tags || %{},
      sse: sse_meta(upload.sse_algorithm, sse_envelope),
      acl_canned: upload.acl_canned || "private",
      acl_grants: upload.acl_grants || %{"grants" => []},
      storage_class: upload.storage_class || "STANDARD",
      user_metadata: upload.metadata || %{},
      checksum: SSE.checksum_for_storage(checksum, upload.sse_algorithm, sse_envelope),
      object_parts:
        SSE.object_parts_for_storage(object_parts, upload.sse_algorithm, sse_envelope),
      etag: s3_etag
    }
    |> Map.merge(object_meta_extra(opts))
  end

  defp complete_object_meta_extra(opts, write_result) do
    info =
      opts
      |> Keyword.get(:object_meta_extra_info, %{})
      |> Map.merge(Placement.attrs_from_result(write_result))

    case Keyword.get(opts, :object_meta_extra) do
      fun when is_function(fun, 1) -> fun.(info) || %{}
      extra when is_map(extra) -> extra
      _other -> %{}
    end
  end

  defp object_meta_extra(opts) do
    case Keyword.get(opts, :object_meta_extra) do
      extra when is_map(extra) -> extra
      _other -> %{}
    end
  end

  defp notification_outbox(result) do
    Map.get(result, :notification_outbox, [])
  end

  defp notification_retained_ledger(result) do
    Map.get(result, :notification_retained_ledger, [])
  end

  defp storage_abort_upload(upload, opts) do
    Maxio.Storage.abort_upload(
      upload.bucket_name,
      upload.key,
      upload.upload_id,
      Keyword.merge(opts, Placement.upload_storage_opts(upload))
    )
  end

  defp safe_storage_abort_upload(upload, opts) do
    storage_abort_upload(upload, opts)
  rescue
    exception -> {:error, {:exception, exception.__struct__, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp completed_object_parts(parts) do
    %{
      "Parts" =>
        Enum.map(parts, fn %Part{} = part ->
          %{
            "PartNumber" => part.part_number,
            "Size" => part.size
          }
          |> Map.merge(part.checksum || %{})
        end),
      "PartsCount" => length(parts)
    }
  end

  defp sse_meta(nil, _envelope), do: nil
  defp sse_meta("", _envelope), do: nil
  defp sse_meta(algo, envelope), do: %{"algo" => algo, "envelope" => envelope}

  defp list_all_parts(%Upload{id: uid}) do
    Repo.all(from p in Part, where: p.upload_id == ^uid, order_by: [asc: p.part_number])
  end

  defp part_with_visible_checksum(%Upload{} = upload, %Part{} = part) do
    %{
      part
      | checksum:
          SSE.visible_checksum_metadata(
            part.checksum || %{},
            upload.sse_algorithm,
            upload.sse_envelope
          )
    }
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
          if normalize_etag(p.etag) == normalize_etag(req.etag) and part_checksums_match?(p, req) do
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

  defp ensure_consecutive_checksum_parts(parts) do
    if Enum.any?(parts, &part_checksum_metadata?/1) do
      nums = Enum.map(parts, & &1.part_number)

      if nums == Enum.to_list(1..length(nums)),
        do: :ok,
        else: {:error, :invalid_part_order}
    else
      :ok
    end
  end

  defp ensure_supported_complete_checksum(%Upload{checksum_type: "FULL_OBJECT"}, _parts), do: :ok

  defp ensure_supported_complete_checksum(_upload, parts) do
    if Enum.any?(parts, &part_crc64nvme_metadata?/1) do
      {:error, :checksum_not_implemented}
    else
      :ok
    end
  end

  defp ensure_upload_checksum_intent(%Upload{checksum_algorithm: nil}, _parts), do: :ok

  defp ensure_upload_checksum_intent(
         %Upload{checksum_type: "FULL_OBJECT", checksum_algorithm: algorithm},
         _parts
       ) do
    if Checksum.full_object_multipart_algorithm?(algorithm),
      do: :ok,
      else: {:error, :checksum_not_implemented}
  end

  defp ensure_upload_checksum_intent(%Upload{checksum_algorithm: algorithm}, parts) do
    field = Checksum.multipart_algorithm_field!(algorithm)

    if Enum.all?(parts, fn %Part{checksum: checksum} ->
         is_map(checksum) and is_binary(Map.get(checksum, field))
       end) do
      :ok
    else
      {:error, :invalid_part}
    end
  end

  defp normalize_etag(etag), do: etag |> to_string() |> String.trim("\"") |> String.downcase()

  defp part_crc64nvme_metadata?(%Part{checksum: checksum}) when is_map(checksum),
    do: Map.has_key?(checksum, "ChecksumCRC64NVME")

  defp part_crc64nvme_metadata?(%Part{}), do: false

  defp part_checksum_metadata?(%Part{checksum: checksum}) when is_map(checksum) do
    Enum.any?(@part_checksum_fields, &Map.has_key?(checksum, &1))
  end

  defp part_checksum_metadata?(%Part{}), do: false

  defp part_checksum_metadata?(req) when is_map(req) do
    Enum.any?(@part_checksum_fields, &Map.has_key?(req, &1))
  end

  defp part_checksums_match?(%Part{} = part, req) do
    stored = part.checksum || %{}

    Enum.all?(@part_checksum_fields, fn field ->
      case Map.fetch(req, field) do
        {:ok, requested} -> Map.get(stored, field) == requested
        :error -> true
      end
    end)
  end

  defp complete_object_checksum(%Upload{checksum_type: "FULL_OBJECT"}, _object_parts),
    do: {:ok, :full_object}

  defp complete_object_checksum(_upload, object_parts),
    do: Checksum.composite_object_metadata(Map.fetch!(object_parts, "Parts"))

  defp ensure_complete_checksum_request(
         %Upload{checksum_type: "FULL_OBJECT", checksum_algorithm: algorithm},
         request,
         visible_size,
         _checksum
       ) do
    with :ok <- ensure_complete_checksum_type(request, "FULL_OBJECT"),
         :ok <- ensure_complete_full_object_checksum_algorithm(request, algorithm),
         :ok <- ensure_complete_object_size(request, visible_size) do
      :ok
    end
  end

  defp ensure_complete_checksum_request(
         %Upload{checksum_algorithm: algorithm},
         request,
         visible_size,
         checksum
       )
       when is_binary(algorithm) do
    with :ok <- ensure_complete_checksum_type(request, "COMPOSITE"),
         :ok <- ensure_complete_checksum_algorithm(request, algorithm),
         :ok <- ensure_complete_checksum_value(request, checksum),
         :ok <- ensure_complete_object_size(request, visible_size) do
      :ok
    end
  end

  defp ensure_complete_checksum_request(_upload, request, visible_size, _checksum) do
    with :ok <- ensure_no_complete_checksum_header(request),
         :ok <- ensure_complete_object_size(request, visible_size) do
      :ok
    end
  end

  defp ensure_complete_checksum_type(request, expected) do
    case Map.get(request, :checksum_type) do
      nil -> :ok
      ^expected -> :ok
      _other -> {:error, :bad_digest}
    end
  end

  defp ensure_complete_checksum_algorithm(request, expected) do
    case Map.get(request, :checksum_algorithm) do
      nil -> :ok
      ^expected -> :ok
      _other -> {:error, :bad_digest}
    end
  end

  defp ensure_complete_full_object_checksum_algorithm(request, expected) do
    case Map.get(request, :checksum_algorithm) do
      nil -> :ok
      ^expected -> :ok
      _other -> {:error, :invalid_request}
    end
  end

  defp ensure_no_complete_checksum_header(request) do
    if is_nil(Map.get(request, :checksum_algorithm)) and is_nil(Map.get(request, :checksum_type)),
      do: :ok,
      else: {:error, :checksum_not_implemented}
  end

  defp ensure_complete_checksum_value(%{checksum_algorithm: nil}, _checksum), do: :ok

  defp ensure_complete_checksum_value(
         %{checksum_algorithm: algorithm, checksum_value: value},
         checksum
       )
       when is_binary(algorithm) and is_binary(value) do
    case Map.fetch(checksum, Checksum.multipart_algorithm_field!(algorithm)) do
      {:ok, ^value} -> :ok
      _ -> {:error, :bad_digest}
    end
  end

  defp ensure_complete_checksum_value(_request, _checksum), do: {:error, :bad_digest}

  defp ensure_complete_object_size(request, visible_size) do
    case Map.get(request, :object_size) do
      nil -> :ok
      ^visible_size -> :ok
      _other -> {:error, :invalid_request}
    end
  end

  defp generate_upload_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end

  defp upload_key(upload_id), do: ".uploads/" <> upload_id

  defp with_upload_opts(opts, %Upload{} = upload),
    do: Keyword.merge(opts, Placement.upload_storage_opts(upload))

  defp with_upload_opts(%Upload{} = upload, opts),
    do: with_upload_opts(opts, upload)

  defp storage_safe_opts(opts), do: Keyword.delete(opts, :sse_customer_key)

  defp escape_like(str) do
    str
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  # ROUTE B B1-3 SQL LIST 临时硬 LIMIT 闸（同 Objects.list_fetch_limit/1）：
  # min(sql_hard_limit, max_uploads*4+1000)，折叠 delimiter 余量 *4+1000，上限防 DoS。
  defp list_fetch_limit(max_uploads) do
    # 经 Maxio.Config 门面读（config store 白名单键，可热改），同 Objects.list_fetch_limit/1。
    hard_limit = Maxio.Config.get(:listing, :sql_hard_limit, 100_000)
    min(hard_limit, max_uploads * 4 + 1000)
  end

  defp normalize_max_uploads(n) when is_integer(n) and n > 0,
    do: min(n, @max_uploads_limit)

  defp normalize_max_uploads(_), do: @max_uploads_limit

  defp min_part_size do
    Application.get_env(:maxio, :multipart_min_part_size, @default_min_part_size)
  end

  # ListMultipartUploads 的 delimiter 折叠（与 Objects.list_objects_v2 同构）。
  # capped? = SQL 候选被 fetch_limit 截断；候选耗尽却未达 max 时不能宣称完整。
  defp collapse_uploads(candidates, prefix, delimiter, max, capped?, key_marker) do
    do_collapse_uploads(
      candidates,
      prefix,
      delimiter,
      max,
      [],
      MapSet.new(),
      [],
      nil,
      nil,
      capped?,
      key_marker
    )
  end

  # 候选耗尽。capped? 为真说明 SQL LIMIT 可能在攒满 max 前就截断了候选——无法证明完整，
  # 强制 is_truncated=true + 续点（最后已折叠 key），否则才 false。
  defp do_collapse_uploads(
         [],
         _prefix,
         _delim,
         _max,
         ups,
         _seen,
         cps,
         last_scanned,
         last_result,
         capped?,
         _key_marker
       ) do
    if capped? do
      {next_key, next_upload_id} = last_scanned || last_result || previous_marker(ups, cps)
      {Enum.reverse(ups), Enum.reverse(cps), true, next_key, next_upload_id}
    else
      {Enum.reverse(ups), Enum.reverse(cps), false, nil, nil}
    end
  end

  defp do_collapse_uploads(
         [u | rest],
         prefix,
         delimiter,
         max,
         ups,
         seen,
         cps,
         last_scanned,
         last_result,
         capped?,
         key_marker
       ) do
    count = length(ups) + MapSet.size(seen)

    cond do
      count >= max ->
        {next_key, next_upload_id} = last_result || last_scanned || previous_marker(ups, cps)
        {Enum.reverse(ups), Enum.reverse(cps), true, next_key, next_upload_id}

      true ->
        scanned = upload_marker(u)

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
              scanned,
              scanned,
              capped?,
              key_marker
            )

          cp ->
            if MapSet.member?(seen, cp) or not common_prefix_after_marker?(cp, key_marker) do
              do_collapse_uploads(
                rest,
                prefix,
                delimiter,
                max,
                ups,
                seen,
                cps,
                scanned,
                last_result,
                capped?,
                key_marker
              )
            else
              do_collapse_uploads(
                rest,
                prefix,
                delimiter,
                max,
                ups,
                MapSet.put(seen, cp),
                [cp | cps],
                scanned,
                {cp, nil},
                capped?,
                key_marker
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

  defp common_prefix_after_marker?(_cp, nil), do: true
  defp common_prefix_after_marker?(cp, marker), do: cp > marker

  defp upload_marker(u), do: {u.key, u.upload_id}

  defp previous_marker([u | _], _cps), do: upload_marker(u)
  defp previous_marker([], [cp | _]), do: {cp, nil}
  defp previous_marker([], []), do: {nil, nil}
end
