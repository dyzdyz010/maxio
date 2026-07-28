defmodule Maxio.Console.ObjectUpload do
  @moduledoc """
  Console object upload orchestration.

  LiveView file uploads arrive as server-side temporary files. This module keeps
  the UI layer out of storage details and chooses between a single streaming PUT
  and an internal multipart upload without buffering the full object in memory.
  """

  require Logger

  alias Maxio.{BucketQuota, Lock, Multipart, ObjectMeta, Objects, Repo, Storage}
  alias Maxio.Cluster.Placement
  alias Maxio.ObjectMutation.Commit, as: ObjectMutationCommit
  alias Maxio.Objects.Object
  alias Maxio.Storage.ObjectCommit.Control
  alias Maxio.Versioning.VersionId

  @single_put_chunk_size 1_048_576
  @max_object_size 5 * 1_024 * 1_024 * 1_024 * 1_024
  @max_multipart_parts 10_000
  @s3_min_part_size 5_242_880
  @default_multipart_part_size 8 * 1_024 * 1_024
  @default_multipart_threshold @default_multipart_part_size

  @type upload_opts :: [
          multipart_threshold: pos_integer(),
          multipart_part_size: pos_integer(),
          max_multipart_parts: pos_integer(),
          min_part_size: pos_integer(),
          storage_opts: keyword()
        ]

  @doc """
  Upload a LiveView temporary file into object storage and commit object metadata.

  `versioning` follows bucket versioning state: only `"Enabled"` gets a fresh
  version id; all other states write the `"null"` version.
  """
  @spec upload_tmp_file(
          String.t(),
          String.t(),
          String.t(),
          Path.t(),
          map(),
          upload_opts()
        ) ::
          {:ok, Object.t()} | {:error, term()}
  def upload_tmp_file(bucket, key, versioning, tmp_path, attrs \\ %{}, opts \\ []) do
    attrs = normalize_attrs(attrs)

    with {:ok, %{size: file_size}} <- File.stat(tmp_path),
         :ok <- ensure_max_object_size(file_size) do
      version_id = if versioning == "Enabled", do: VersionId.generate(), else: "null"

      result =
        if multipart_upload?(file_size, opts) do
          upload_multipart(bucket, key, version_id, tmp_path, file_size, attrs, opts)
        else
          upload_single_put(bucket, key, version_id, tmp_path, attrs, opts)
        end

      case result do
        {:ok, %Object{} = object} ->
          {:ok, object}

        {:error, reason} = err ->
          log_upload_error(bucket, key, version_id, reason)
          err
      end
    else
      {:error, reason} = err ->
        log_upload_error(bucket, key, nil, reason)
        err
    end
  end

  # ObjectMutation Phase 2A（C4）：PG 写权威（默认）下 console single put 全程 journal 化
  # （operation="put"）。Console 是无锁 caller——around 回调内取 `Lock.with_object_lock`
  # （与 do_put 完全同构，D5），quota 预检同构前置到锁内、claim 之前（超限在 publish 前
  # fail-closed，零 journal、无孤儿字节）。:sidecar 写权威维持既有「put_version_with_id
  # 致命提交」值语义逐字节不变（D1，协议化归 Phase 2B）。原「metadata 失败后 plain
  # Storage.delete」回滚点（cleanup_uploaded_object 的 single-put 调用分支）随迁移删除
  # ——publish 后 metadata 失败由 seam restore（pg）/ ObjectCommit rollback（sidecar）
  # 收敛，unversioned 覆盖时旧对象逐字节恢复。
  defp upload_single_put(bucket, key, version_id, tmp_path, attrs, opts) do
    storage_opts = storage_opts(opts)
    object_meta = storage_object_meta(attrs)

    # 元数据 attrs 构造对两条提交路径同源（published_result 携 placement 快照）。
    committed_attrs = fn write_info, published_result ->
      attrs
      |> Map.merge(%{size: write_info.size, etag: write_info.etag})
      |> merge_if_present(published_result, :checksum)
      |> merge_if_present(published_result, :object_parts)
      |> merge_if_present(published_result, :sse_envelope)
      |> Map.merge(Placement.attrs_from_result(published_result))
    end

    around_object_commit = fn write_info, publish ->
      case ObjectMeta.authoritative_source(:write, storage_opts) do
        :sidecar ->
          commit_single_put_sidecar_authority(
            bucket,
            key,
            version_id,
            object_meta,
            committed_attrs,
            write_info,
            publish
          )

        _pg ->
          lock_result =
            Lock.with_object_lock({bucket, key}, fn ->
              commit_single_put_pg_authority(
                bucket,
                key,
                version_id,
                object_meta,
                committed_attrs,
                write_info,
                publish,
                storage_opts
              )
            end)

          case lock_result do
            {:ok, result} -> result
            {:error, :locked} = error -> error
          end
      end
    end

    put_opts =
      storage_opts
      |> Keyword.put(:object_meta, object_meta)
      |> Keyword.put(:around_object_commit, around_object_commit)

    try do
      case Storage.put(
             bucket,
             key,
             version_id,
             File.stream!(tmp_path, [], @single_put_chunk_size),
             put_opts
           ) do
        {:ok, %{} = write_result} ->
          %Object{} = object = Map.fetch!(write_result, :around_object_commit_result)

          Logger.info("[maxio][Console] upload stored",
            action: :console_object_upload,
            bucket: bucket,
            key: key,
            version_id: version_id,
            size: object.size,
            strategy: :single_put
          )

          {:ok, object}

        {:error, _reason} = err ->
          err
      end
    rescue
      # S3 语义错误（quota 预检等）保持迁移前 {:error, %Maxio.S3.Error{}} 值语义
      # （console caller 契约不变，不 raise 穿透 LiveView）。
      err in Maxio.S3.Error -> {:error, err}
    end
  end

  # PG 写权威：ObjectMutation seam（协议 §0.2 序列）。metadata_tx = put_version_with_id +
  # Commit.transaction_hook(journal)——journal metadata_committed 与 PG row 同一事务，
  # CAS 失败整体回滚；publish 后 metadata 失败由 seam restore 收敛（旧对象恢复、backup
  # 保留），绝不 plain delete。metadata_tx 内 rescue/catch 转 {:error, err}（协议契约：
  # closure 不 raise），维持迁移前「metadata 失败 → {:error, reason}」值语义。
  defp commit_single_put_pg_authority(
         bucket,
         key,
         version_id,
         object_meta,
         committed_attrs,
         write_info,
         publish,
         storage_opts
       ) do
    # do_put 同构的锁内 quota 预检：超限在 claim/publish 之前抛 S3.Error，经
    # upload_single_put 的 rescue 转 {:error, err}（fail-closed、无孤儿字节）。
    :ok = BucketQuota.ensure_write_allowed!(Repo, bucket, key, version_id, write_info.size)

    plan = %{
      bucket: bucket,
      key: key,
      version_id: version_id,
      operation: "put",
      authority_mode: "pg",
      storage_opts: Keyword.merge(storage_opts, Placement.storage_opts(write_info)),
      write_info: write_info,
      publish: fn extra_commit_opts ->
        publish.(
          Keyword.merge([version_id: version_id, object_meta: object_meta], extra_commit_opts)
        )
      end,
      metadata_tx: fn journal, published_result ->
        try do
          case Objects.put_version_with_id(
                 bucket,
                 key,
                 version_id,
                 committed_attrs.(write_info, published_result),
                 transaction_hook: ObjectMutationCommit.transaction_hook(journal)
               ) do
            {:ok, {%Object{} = object, :ok}} -> {:ok, object}
            {:error, _reason} = error -> error
          end
        rescue
          err -> {:error, err}
        catch
          kind, reason -> {:error, {kind, reason}}
        end
      end
    }

    case ObjectMutationCommit.run(plan) do
      {:ok, %{published: published_result, metadata: %Object{} = object}} ->
        {:ok, Map.put(published_result, :around_object_commit_result, object)}

      {:error, _reason} = error ->
        error
    end
  end

  # :sidecar 写权威（D1）：console 迁移前即以 put_version_with_id 作致命 PG 提交（无
  # best-effort index 分支），维持该值语义：PG 失败/异常 → {:error, err} 交 ObjectCommit
  # rollback 恢复先前状态（不再 plain delete），错误面与迁移前一致。
  defp commit_single_put_sidecar_authority(
         bucket,
         key,
         version_id,
         object_meta,
         committed_attrs,
         write_info,
         publish
       ) do
    case publish.(version_id: version_id, object_meta: object_meta) do
      {:ok, published_result} ->
        try do
          case Objects.put_version_with_id(
                 bucket,
                 key,
                 version_id,
                 committed_attrs.(write_info, published_result)
               ) do
            {:ok, %Object{} = object} ->
              accelerate_mark_committed(write_info, bucket, key, version_id)
              {:ok, Map.put(published_result, :around_object_commit_result, object)}

            {:error, _reason} = error ->
              error
          end
        rescue
          err -> {:error, err}
        catch
          kind, reason -> {:error, {kind, reason}}
        end

      {:error, _reason} = error ->
        error
    end
  end

  # 与 do_put :sidecar 分支同构：metadata 提交后立即关闭进程内提交窗口——此后
  # publisher DOWN 不再触发字节回滚（sidecar 权威下 publish 已是提交点）。
  defp accelerate_mark_committed(write_info, bucket, key, version_id) do
    case write_info
         |> Map.fetch!(:object_commit_control)
         |> Control.mark_committed() do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("[maxio][Console] object commit finalize failed after metadata commit",
          action: :console_object_upload,
          bucket: bucket,
          key: key,
          version_id: version_id,
          commit_identity: Map.fetch!(write_info, :object_commit_identity),
          reason: inspect(reason)
        )
    end
  end

  defp upload_multipart(bucket, key, version_id, tmp_path, file_size, attrs, opts) do
    with {:ok, upload} <-
           Multipart.initiate(bucket, key, multipart_attrs(attrs), storage_opts(opts)) do
      case put_multipart_parts(upload, tmp_path, file_size, opts) do
        {:ok, requested_parts} ->
          complete_multipart(upload, requested_parts, version_id, attrs, opts)

        {:error, reason} ->
          _ = Multipart.abort(upload, storage_opts(opts))
          {:error, reason}
      end
    end
  end

  defp put_multipart_parts(upload, tmp_path, file_size, opts) do
    part_size = multipart_part_size(file_size, opts)
    part_storage_opts = Keyword.merge(storage_opts(opts), Placement.upload_storage_opts(upload))

    file_size
    |> multipart_part_specs(part_size)
    |> Enum.reduce_while({:ok, []}, fn {part_number, offset, size}, {:ok, acc} ->
      case Storage.put_part(
             upload.bucket_name,
             upload.key,
             upload.upload_id,
             part_number,
             part_file_stream(tmp_path, offset, size),
             part_storage_opts
           ) do
        {:ok, part_result} ->
          case Multipart.put_part(upload, part_number, %{
                 etag: part_result.etag,
                 size: part_result.size
               }) do
            {:ok, _part} ->
              requested = %{part_number: part_number, etag: part_result.etag}
              {:cont, {:ok, [requested | acc]}}

            {:error, reason} ->
              {:halt, {:error, reason}}
          end

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, requested_parts} -> {:ok, Enum.reverse(requested_parts)}
      {:error, _reason} = err -> err
    end
  end

  defp complete_multipart(upload, requested_parts, version_id, attrs, opts) do
    complete_opts =
      opts
      |> storage_opts()
      |> Keyword.put(:version_id, version_id)
      |> Keyword.put(:min_part_size, multipart_min_part_size(opts))
      |> Keyword.put(:object_meta_extra, multipart_object_meta_extra(attrs))

    case Multipart.complete(upload, requested_parts, complete_opts) do
      {:ok, complete_result} ->
        case commit_metadata(
               upload.bucket_name,
               upload.key,
               version_id,
               attrs,
               complete_result,
               storage_opts(opts),
               :multipart
             ) do
          {:ok, %Object{} = object} ->
            cleanup_terminal_upload(upload, opts)
            {:ok, object}

          {:error, reason} ->
            cleanup_terminal_upload(upload, opts)
            {:error, reason}
        end

      {:error, reason} ->
        _ = Multipart.abort(upload, storage_opts(opts))
        {:error, reason}
    end
  end

  defp cleanup_terminal_upload(upload, opts) do
    case Multipart.cleanup_after_terminal(upload, storage_opts(opts)) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("[maxio][Console] multipart terminal cleanup failed",
          action: :console_object_upload_multipart_cleanup,
          bucket: upload.bucket_name,
          key: upload.key,
          upload_id: upload.upload_id,
          reason: inspect(reason)
        )
    end
  end

  # 仅 multipart 路径仍走本函数（single put 已迁 ObjectMutation seam，C4）；multipart
  # complete 及其 cleanup_uploaded_object 回滚点的 seam 迁移归 Phase 2A C8。
  defp commit_metadata(bucket, key, version_id, attrs, write_result, storage_opts, strategy) do
    object_attrs =
      attrs
      |> Map.merge(%{
        size: write_result.size,
        etag: write_result.etag
      })
      |> merge_if_present(write_result, :checksum)
      |> merge_if_present(write_result, :object_parts)
      |> merge_if_present(write_result, :sse_envelope)
      |> Map.merge(Placement.attrs_from_result(write_result))

    try do
      case Objects.put_version_with_id(bucket, key, version_id, object_attrs) do
        {:ok, %Object{} = object} ->
          Logger.info("[maxio][Console] upload stored",
            action: :console_object_upload,
            bucket: bucket,
            key: key,
            version_id: version_id,
            size: object.size,
            strategy: strategy
          )

          {:ok, object}

        {:error, reason} ->
          cleanup_uploaded_object(bucket, key, version_id, write_result, storage_opts, reason)
          {:error, reason}
      end
    rescue
      err ->
        cleanup_uploaded_object(bucket, key, version_id, write_result, storage_opts, err)
        {:error, err}
    end
  end

  defp cleanup_uploaded_object(bucket, key, version_id, write_result, storage_opts, error) do
    delete_opts = Keyword.merge(storage_opts, Placement.storage_opts(write_result))

    case Storage.delete(bucket, key, version_id, delete_opts) do
      :ok ->
        Logger.warning("[maxio][Console] upload rolled back orphan bytes",
          action: :console_object_upload_cleanup,
          bucket: bucket,
          key: key,
          version_id: version_id,
          reason: :metadata_commit_failed,
          original_error: inspect(error)
        )

      {:error, reason} ->
        Logger.error(
          "[maxio][Console] upload orphan bytes cleanup failed after metadata rollback",
          action: :console_object_upload_cleanup,
          bucket: bucket,
          key: key,
          version_id: version_id,
          reason: inspect(reason),
          original_error: inspect(error)
        )
    end

    :ok
  end

  defp log_upload_error(bucket, key, version_id, reason) do
    Logger.error("[maxio][Console] upload failed",
      action: :console_object_upload,
      bucket: bucket,
      key: key,
      version_id: version_id,
      reason: inspect(reason)
    )
  end

  defp normalize_attrs(attrs) do
    %{
      content_type: Map.get(attrs, :content_type) || "binary/octet-stream",
      storage_class: Map.get(attrs, :storage_class) || "STANDARD",
      metadata: Map.get(attrs, :metadata, %{}),
      acl_canned: Map.get(attrs, :acl_canned, "private"),
      acl_grants: Map.get(attrs, :acl_grants, %{"grants" => []}),
      tags: Map.get(attrs, :tags, %{}),
      owner: Map.get(attrs, :owner, "arn:aws:iam:::root")
    }
  end

  defp multipart_attrs(attrs) do
    %{
      content_type: attrs.content_type,
      storage_class: attrs.storage_class,
      owner: attrs.owner,
      metadata: attrs.metadata,
      acl_canned: attrs.acl_canned,
      acl_grants: attrs.acl_grants
    }
  end

  defp storage_object_meta(attrs) do
    %{
      content_type: attrs.content_type,
      storage_class: attrs.storage_class,
      user_metadata: attrs.metadata,
      acl_canned: attrs.acl_canned,
      acl_grants: attrs.acl_grants,
      tags: attrs.tags
    }
  end

  defp multipart_object_meta_extra(attrs), do: %{tags: attrs.tags}

  defp multipart_upload?(0, _opts), do: false

  defp multipart_upload?(file_size, opts) do
    file_size >= multipart_threshold(opts)
  end

  defp ensure_max_object_size(file_size) when file_size <= @max_object_size, do: :ok
  defp ensure_max_object_size(_file_size), do: {:error, :entity_too_large}

  defp multipart_threshold(opts) do
    opts
    |> Keyword.get(
      :multipart_threshold,
      console_integer(:multipart_threshold, @default_multipart_threshold)
    )
    |> positive_integer(@default_multipart_threshold)
  end

  defp multipart_part_size(file_size, opts) do
    requested =
      opts
      |> Keyword.get(
        :multipart_part_size,
        console_integer(:multipart_part_size, @default_multipart_part_size)
      )
      |> positive_integer(@default_multipart_part_size)

    max_parts = max_multipart_parts(opts)
    required_by_part_count = div(file_size + max_parts - 1, max_parts)

    requested
    |> max(multipart_min_part_size(opts))
    |> max(required_by_part_count)
  end

  defp multipart_min_part_size(opts) do
    opts
    |> Keyword.get(
      :min_part_size,
      Application.get_env(:maxio, :multipart_min_part_size, @s3_min_part_size)
    )
    |> positive_integer(@s3_min_part_size)
  end

  defp max_multipart_parts(opts) do
    requested =
      opts
      |> Keyword.get(:max_multipart_parts, @max_multipart_parts)
      |> positive_integer(@max_multipart_parts)

    min(requested, @max_multipart_parts)
  end

  defp storage_opts(opts), do: Keyword.get(opts, :storage_opts, [])

  defp multipart_part_specs(file_size, part_size) do
    Stream.unfold({1, 0}, fn
      {_part_number, offset} when offset >= file_size ->
        nil

      {part_number, offset} ->
        size = min(part_size, file_size - offset)
        {{part_number, offset, size}, {part_number + 1, offset + size}}
    end)
  end

  defp part_file_stream(path, offset, size) do
    Stream.resource(
      fn ->
        {:ok, file} = :file.open(String.to_charlist(path), [:read, :binary, :raw])
        {:ok, ^offset} = :file.position(file, offset)
        {file, size}
      end,
      fn
        {file, 0} ->
          {:halt, {file, 0}}

        {file, remaining} ->
          read_size = min(@single_put_chunk_size, remaining)

          case :file.read(file, read_size) do
            {:ok, chunk} -> {[chunk], {file, remaining - byte_size(chunk)}}
            :eof -> {:halt, {file, 0}}
            {:error, reason} -> raise File.Error, reason: reason, action: "read", path: path
          end
      end,
      fn {file, _remaining} -> :file.close(file) end
    )
  end

  defp console_integer(key, default) do
    :maxio
    |> Application.get_env(:console, [])
    |> Keyword.get(key, default)
  end

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value, default), do: default

  defp merge_if_present(attrs, source, key) do
    case Map.fetch(source, key) do
      {:ok, nil} -> attrs
      {:ok, value} -> Map.put(attrs, key, value)
      :error -> attrs
    end
  end
end
