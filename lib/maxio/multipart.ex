defmodule Maxio.Multipart do
  @moduledoc """
  分段上传元数据上下文：initiate/get/put_part(元数据)/list_parts/list_uploads/complete/abort
  + multipart ETag 算法。分块字节走 Maxio.Storage（FS parts 回调），本上下文管会话与分块元数据
  及 Complete 时的校验（InvalidPart/InvalidPartOrder/EntityTooSmall/NoSuchUpload，铁律 3）。
  """
  import Ecto.Query
  alias Maxio.Repo
  alias Maxio.Multipart.{Upload, Part}

  @default_min_part_size 5_242_880

  @doc "发起分段上传：生成 UploadId（UUID hex），落会话元数据。"
  @spec initiate(String.t(), String.t(), map()) :: {:ok, Upload.t()} | {:error, Ecto.Changeset.t()}
  def initiate(bucket_name, key, attrs \\ %{}) do
    upload_id = generate_upload_id()

    base = %{
      upload_id: upload_id,
      bucket_name: bucket_name,
      key: key,
      content_type: Map.get(attrs, :content_type, "binary/octet-stream"),
      storage_class: Map.get(attrs, :storage_class, "STANDARD"),
      owner: Map.get(attrs, :owner, "arn:aws:iam:::root"),
      metadata: Map.get(attrs, :metadata, %{})
    }

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

    candidates = Repo.all(base)

    {uploads, common_prefixes, truncated, next_key} =
      collapse_uploads(candidates, prefix, delimiter, max_uploads)

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
  返回 {:ok, %{etag, size}} | {:error, reason}，reason ∈
  :no_such_upload | :invalid_part | :invalid_part_order | :entity_too_small | :no_parts。
  opts: :min_part_size（默认 5_242_880；测试可注入小值）。
  """
  @spec complete(Upload.t(), [%{part_number: pos_integer(), etag: String.t()}], keyword()) ::
          {:ok, %{etag: String.t(), size: non_neg_integer()}} | {:error, atom()}
  def complete(%Upload{} = upload, requested_parts, opts \\ []) do
    min_part_size = Keyword.get(opts, :min_part_size, min_part_size())
    stored = list_all_parts(upload) |> Map.new(fn p -> {p.part_number, p} end)

    with :ok <- ensure_nonempty(requested_parts),
         :ok <- ensure_ascending(requested_parts),
         {:ok, ordered} <- match_parts(requested_parts, stored),
         :ok <- ensure_min_size(ordered, min_part_size) do
      part_numbers = Enum.map(ordered, & &1.part_number)
      md5_raws = Enum.map(ordered, fn p -> Base.decode16!(p.etag, case: :mixed) end)
      etag = multipart_etag(md5_raws)

      case Maxio.Storage.assemble(upload.bucket_name, upload.key, upload.upload_id, part_numbers) do
        {:ok, %{size: size}} ->
          # part 字节清理 + 会话/分块元数据删除统一由调用方 handler 的 Multipart.abort/1 负责
          # （单一职责，不在此重复 abort_upload）。
          {:ok, %{etag: etag, size: size}}

        {:error, _} = err ->
          err
      end
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
    str |> String.replace("\\", "\\\\") |> String.replace("%", "\\%") |> String.replace("_", "\\_")
  end

  defp min_part_size do
    Application.get_env(:maxio, :multipart_min_part_size, @default_min_part_size)
  end

  # ListMultipartUploads 的 delimiter 折叠（与 Objects.list_objects_v2 同构）。
  defp collapse_uploads(candidates, prefix, delimiter, max) do
    do_collapse_uploads(candidates, prefix, delimiter, max, [], MapSet.new(), [])
  end

  defp do_collapse_uploads([], _prefix, _delim, _max, ups, _seen, cps),
    do: {Enum.reverse(ups), Enum.reverse(cps), false, nil}

  defp do_collapse_uploads([u | rest], prefix, delimiter, max, ups, seen, cps) do
    count = length(ups) + MapSet.size(seen)

    cond do
      count >= max ->
        last_key = previous_key(ups, cps)
        {Enum.reverse(ups), Enum.reverse(cps), true, last_key}

      true ->
        case common_prefix_of(u.key, prefix, delimiter) do
          nil ->
            do_collapse_uploads(rest, prefix, delimiter, max, [u | ups], seen, cps)

          cp ->
            if MapSet.member?(seen, cp) do
              do_collapse_uploads(rest, prefix, delimiter, max, ups, seen, cps)
            else
              do_collapse_uploads(rest, prefix, delimiter, max, ups, MapSet.put(seen, cp), [
                cp | cps
              ])
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
