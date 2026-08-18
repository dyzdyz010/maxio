defmodule Maxio.S3.ObjectWriter do
  @moduledoc """
  Internal writer for server-generated S3 objects.

  This module is intentionally narrower than PutObject: it writes an enumerable
  produced by maxio itself, with explicit metadata and without reinterpreting
  the caller's request body headers.
  """

  alias Maxio.{Buckets, Lock, ObjectMeta, Objects, Storage}
  alias Maxio.Cluster.Placement
  alias Maxio.ObjectMutation.Commit, as: ObjectMutationCommit
  alias Maxio.Policy.ACL
  alias Maxio.S3.{Error, Log, ObjectMutationError, SSE}
  alias Maxio.Storage.ObjectCommit.Control

  @type write_opts :: [
          content_type: String.t(),
          storage_class: String.t(),
          metadata: map(),
          tags: map(),
          acl_canned: String.t(),
          acl_grants: map(),
          sse_target: SSE.target(),
          action: atom()
        ]

  @spec put_generated!(String.t(), String.t(), Enumerable.t(), write_opts()) :: Objects.Object.t()
  def put_generated!(bucket, key, chunks, opts \\ []) do
    ensure_bucket!(bucket)
    validate_object_key!(bucket, key)

    sse_target = Keyword.fetch!(opts, :sse_target)

    attrs = initial_attrs(opts)
    version_id = version_id_for(bucket)
    action = Keyword.get(opts, :action, :put_object)

    {chunks, visible_size, sse_attrs, sse_object_meta} = prepare_payload(chunks, sse_target)

    result =
      Lock.with_object_lock({bucket, key}, fn ->
        object_meta = object_meta(attrs, visible_size, sse_object_meta)

        # 元数据 attrs 构造对两条提交路径同源（published_result 携 placement 快照）。
        committed_attrs = fn write_info, published_result ->
          attrs
          |> Map.put(:size, committed_size(write_info.size, visible_size, sse_target))
          |> Map.put(:etag, write_info.etag)
          |> Map.merge(sse_attrs)
          |> Map.merge(Placement.attrs_from_result(published_result))
        end

        # ObjectMutation Phase 2A（C2）：PG 写权威（默认）下 server-generated put 全程
        # journal 化（operation="generated_put"，与 do_put 同构；外层已持对象锁，seam 在
        # 锁内直跑，D5）。:sidecar 写权威维持既有非协议路径逐字节不变（D1，协议化归
        # Phase 2B）。原「metadata 失败后 plain Storage.delete」回滚点随迁移删除——publish
        # 后 metadata 失败由 seam restore 收敛（unversioned 覆盖时旧对象逐字节恢复）。
        around_object_commit = fn write_info, publish ->
          case ObjectMeta.authoritative_source(:write) do
            :sidecar ->
              commit_sidecar_authority(
                bucket,
                key,
                version_id,
                object_meta,
                committed_attrs,
                action,
                write_info,
                publish
              )

            _pg ->
              commit_pg_authority(
                bucket,
                key,
                version_id,
                object_meta,
                committed_attrs,
                write_info,
                publish
              )
          end
        end

        case Storage.put(bucket, key, version_id, chunks,
               object_meta: object_meta,
               around_object_commit: around_object_commit
             ) do
          {:ok, %{} = write_result} ->
            {:ok, Map.fetch!(write_result, :around_object_commit_result)}

          {:error, reason} ->
            {:error, reason}
        end
      end)

    case result do
      {:ok, {:ok, object}} ->
        object

      {:ok, {:error, :invalid_key}} ->
        raise Error.new(:invalid_object_name, resource: "/#{bucket}/#{key}")

      {:ok, {:error, :key_too_long}} ->
        raise Error.new(:key_too_long, resource: "/#{bucket}/#{key}")

      # G4a-2W：write_quorum / rename_busy 不再在此提前分流——每一个剩余的 storage /
      # mutation 错误都必须经由 raise_storage_write_error/3 这个唯一的适配器边界，
      # 否则它们会绕过共享分类政策。legacy quorum 分类原样保留在该 helper 内。
      {:ok, {:error, reason}} ->
        raise_storage_write_error(reason, bucket, key)

      {:error, :locked} ->
        raise Error.new(:request_timeout, resource: "/#{bucket}/#{key}")
    end
  end

  defp initial_attrs(opts) do
    %{
      content_type: Keyword.get(opts, :content_type, "binary/octet-stream"),
      storage_class: Keyword.get(opts, :storage_class, "STANDARD"),
      metadata: Keyword.get(opts, :metadata, %{}),
      tags: Keyword.get(opts, :tags, %{}),
      acl_canned: Keyword.get(opts, :acl_canned, "private"),
      acl_grants: Keyword.get(opts, :acl_grants, ACL.empty_grants_doc()),
      checksum: %{},
      object_parts: %{},
      sse_algorithm: nil,
      sse_envelope: nil
    }
  end

  defp object_meta(attrs, visible_size, sse_object_meta) do
    %{
      size: visible_size,
      content_type: attrs.content_type,
      tags: attrs.tags,
      acl_canned: attrs.acl_canned,
      acl_grants: attrs.acl_grants,
      storage_class: attrs.storage_class,
      user_metadata: attrs.metadata,
      checksum: attrs.checksum,
      object_parts: attrs.object_parts,
      sse: nil
    }
    |> Map.merge(sse_object_meta)
  end

  defp committed_size(stored_size, visible_size, sse_target) do
    if SSE.encrypted?(sse_target), do: visible_size.(), else: stored_size
  end

  defp prepare_payload(stream, nil), do: {stream, nil, %{}, %{}}

  defp prepare_payload(stream, "AES256") do
    {counted_stream, visible_size} = counted_stream(stream)
    {cipher_stream, envelope} = Maxio.Crypto.SSE.wrap_stream(counted_stream)

    {cipher_stream, visible_size, %{sse_algorithm: "AES256", sse_envelope: envelope},
     sse_object_meta("AES256", envelope)}
  end

  defp prepare_payload(stream, {:kms, key_id, context_b64, bucket_key_enabled}) do
    {counted_stream, visible_size} = counted_stream(stream)

    {cipher_stream, envelope} =
      Maxio.Crypto.SSE.wrap_stream_with_kms_key(
        counted_stream,
        key_id,
        context_b64,
        bucket_key_enabled: bucket_key_enabled
      )

    {cipher_stream, visible_size, %{sse_algorithm: "aws:kms", sse_envelope: envelope},
     sse_object_meta("aws:kms", envelope)}
  end

  defp prepare_payload(stream, {:kms_dsse, key_id, context_b64}) do
    {counted_stream, visible_size} = counted_stream(stream)

    {cipher_stream, envelope} =
      Maxio.Crypto.SSE.wrap_stream_with_dsse_kms_key(counted_stream, key_id, context_b64)

    {cipher_stream, visible_size, %{sse_algorithm: "aws:kms:dsse", sse_envelope: envelope},
     sse_object_meta("aws:kms:dsse", envelope)}
  end

  defp prepare_payload(_stream, {:customer, _raw_key, _key_md5_b64}) do
    raise Error.new(:not_implemented,
            message: "Generated object SSE-C encryption is not implemented"
          )
  end

  defp prepare_payload(_stream, target) do
    raise Error.new(:not_implemented,
            message:
              "Generated object server-side encryption is not implemented: #{inspect(target)}"
          )
  end

  defp counted_stream(stream) do
    counter = :counters.new(1, [])

    counted =
      Stream.map(stream, fn chunk ->
        size = IO.iodata_length(chunk)
        :counters.add(counter, 1, size)
        chunk
      end)

    {counted, fn -> :counters.get(counter, 1) end}
  end

  defp sse_object_meta(algo, envelope), do: %{sse: %{"algo" => algo, "envelope" => envelope}}

  # :sidecar 写权威（D1）：publish 即权威提交（盘上 sidecar 为事实来源），PG index
  # best-effort——失败仅记日志、绝不回删字节；行为与迁移前逐字节一致（协议化归 Phase 2B）。
  defp commit_sidecar_authority(
         bucket,
         key,
         version_id,
         object_meta,
         committed_attrs,
         action,
         write_info,
         publish
       ) do
    case publish.(version_id: version_id, object_meta: object_meta) do
      {:ok, published_result} ->
        attrs = committed_attrs.(write_info, published_result)

        case Objects.put_version_index(bucket, key, version_id, attrs) do
          :ok ->
            :ok

          {:error, reason} ->
            Log.error("pg index update failed (generated object durably stored in sidecars)",
              action: action,
              bucket: bucket,
              key: key,
              reason: inspect(reason)
            )
        end

        accelerate_mark_committed(write_info, bucket, key, version_id)

        {:ok,
         Map.put(
           published_result,
           :around_object_commit_result,
           build_put_view(bucket, key, version_id, attrs)
         )}

      {:error, _reason} = error ->
        error
    end
  end

  # PG 写权威：ObjectMutation seam（协议 §0.2 序列）。metadata_tx = put_version_with_id +
  # Commit.transaction_hook(journal)——journal metadata_committed 与 PG row 同一事务，
  # CAS 失败整体回滚；publish 后 metadata 失败由 seam restore 收敛（旧对象恢复、backup
  # 保留），绝不 plain delete。
  defp commit_pg_authority(
         bucket,
         key,
         version_id,
         object_meta,
         committed_attrs,
         write_info,
         publish
       ) do
    plan = %{
      bucket: bucket,
      key: key,
      version_id: version_id,
      operation: "generated_put",
      authority_mode: "pg",
      storage_opts: Placement.storage_opts(write_info),
      write_info: write_info,
      publish: fn extra_commit_opts ->
        publish.(
          Keyword.merge([version_id: version_id, object_meta: object_meta], extra_commit_opts)
        )
      end,
      metadata_tx: fn journal, published_result ->
        case Objects.put_version_with_id(
               bucket,
               key,
               version_id,
               committed_attrs.(write_info, published_result),
               transaction_hook: ObjectMutationCommit.transaction_hook(journal)
             ) do
          {:ok, {%Objects.Object{} = object, :ok}} -> {:ok, object}
          {:error, _reason} = error -> error
        end
      end
    }

    case ObjectMutationCommit.run(plan) do
      {:ok, %{published: published_result, metadata: %Objects.Object{} = object}} ->
        {:ok, Map.put(published_result, :around_object_commit_result, object)}

      {:error, _reason} = error ->
        error
    end
  end

  # 与 do_put :sidecar 分支同构：metadata（best-effort index）完成后立即关闭进程内提交
  # 窗口——此后 publisher DOWN 不再触发字节回滚（sidecar 权威下 publish 已是提交点）。
  defp accelerate_mark_committed(write_info, bucket, key, version_id) do
    case write_info
         |> Map.fetch!(:object_commit_control)
         |> Control.mark_committed() do
      :ok ->
        :ok

      {:error, reason} ->
        Log.error("object commit finalize failed after metadata commit",
          action: :object_commit_finalize,
          bucket: bucket,
          key: key,
          version_id: version_id,
          commit_identity: Map.fetch!(write_info, :object_commit_identity),
          reason: inspect(reason)
        )
    end
  end

  defp build_put_view(bucket, key, version_id, attrs) do
    %Objects.Object{
      bucket_name: bucket,
      key: key,
      version_id: version_id,
      size: Map.fetch!(attrs, :size),
      etag: Map.fetch!(attrs, :etag),
      content_type: Map.get(attrs, :content_type, "binary/octet-stream"),
      content_encoding: Map.get(attrs, :content_encoding),
      content_disposition: Map.get(attrs, :content_disposition),
      cache_control: Map.get(attrs, :cache_control),
      expires: Map.get(attrs, :expires),
      website_redirect_location: Map.get(attrs, :website_redirect_location),
      storage_class: Map.get(attrs, :storage_class, "STANDARD"),
      acl_canned: Map.get(attrs, :acl_canned, "private"),
      acl_grants: Map.get(attrs, :acl_grants, ACL.empty_grants_doc()),
      metadata: Map.get(attrs, :metadata, %{}),
      tags: Map.get(attrs, :tags, %{}),
      sse_algorithm: Map.get(attrs, :sse_algorithm),
      sse_envelope: Map.get(attrs, :sse_envelope),
      checksum: Map.get(attrs, :checksum, %{}),
      object_parts: Map.get(attrs, :object_parts, %{}),
      placement_set_id: Map.get(attrs, :placement_set_id),
      placement_pool_id: Map.get(attrs, :placement_pool_id),
      placement_topology_hash: Map.get(attrs, :placement_topology_hash),
      is_latest: true,
      is_delete_marker: false,
      updated_at: DateTime.utc_now()
    }
  end

  defp ensure_bucket!(bucket) do
    case Buckets.lookup(bucket) do
      {:ok, bucket} -> bucket
      {:error, :not_found} -> raise Error.new(:no_such_bucket, resource: "/" <> bucket)
    end
  end

  defp version_id_for(bucket) do
    case Buckets.lookup(bucket) do
      {:ok, %{versioning: "Enabled"}} -> Maxio.Versioning.VersionId.generate()
      _other -> "null"
    end
  end

  defp validate_object_key!(bucket, key) do
    case Maxio.Cluster.Paths.validate_key(key) do
      :ok ->
        :ok

      {:error, :invalid_key} ->
        raise Error.new(:invalid_object_name, resource: "/#{bucket}/#{key}")

      {:error, :key_too_long} ->
        raise Error.new(:key_too_long, resource: "/#{bucket}/#{key}")
    end
  end

  # ObjectWriter 自身的对象 mutation 外部边界（G4a-2W 修正案 §2.1）：
  #
  #   * resource 只构造一次，所有 `Error.new/2` 复用它；
  #   * 恰好一次调用共享纯适配器 `ObjectMutationError.to_error/2`——类别决策只能来自
  #     它，本 helper 绝不匹配稳定信封、绝不 inspect opaque summary、绝不直连
  #     Commit / Recovery / storage 层；
  #   * `{:ok, error}` 即适配器投影结果，原样 raise；
  #   * 只有 `:unrelated`（与 G4 语义无关）才落回既有 legacy 分类：quorum/rename busy →
  #     SlowDownWrite，placement 不可用 → SlowDownWrite，placement 内部错误 → InternalError；
  #   * 最终未知项走目录默认 `InternalError`——**不带 message**，由 catalog 提供默认文案，
  #     绝不把 raw reason `inspect` 进公共 message。
  defp raise_storage_write_error(reason, bucket, key) do
    resource = "/#{bucket}/#{key}"

    case ObjectMutationError.to_error(reason, resource) do
      {:ok, error} ->
        raise error

      :unrelated ->
        raise legacy_write_error(reason, resource)
    end
  end

  defp legacy_write_error(reason, resource) do
    cond do
      reason in [:write_quorum, :rename_busy] ->
        Error.new(:slow_down_write, resource: resource)

      placement_unavailable?(reason) ->
        Error.new(:slow_down_write, resource: resource)

      placement_internal_error?(reason) ->
        Error.new(:internal_error, resource: resource)

      true ->
        Error.new(:internal_error, resource: resource)
    end
  end

  defp placement_unavailable?({:pool_telemetry_incomplete, _candidates}), do: true
  defp placement_unavailable?({:no_eligible_pool, _candidates}), do: true
  defp placement_unavailable?({:drive_stats_crashed, _message}), do: true
  defp placement_unavailable?({:drive_stats_caught, _kind, _reason}), do: true
  defp placement_unavailable?({:invalid_drive_stats, _stats}), do: true
  defp placement_unavailable?({:write_routing_unavailable, _reason}), do: true
  defp placement_unavailable?(:no_topology), do: true
  defp placement_unavailable?(_reason), do: false

  defp placement_internal_error?({:unknown_set_id, _set_id, _known}), do: true
  defp placement_internal_error?({:invalid_decommission_write_route, _route}), do: true
  defp placement_internal_error?({:invalid_decommission_write_routes, _routes}), do: true

  defp placement_internal_error?({:decommission_write_route_cycle, _set_id, _destination}),
    do: true

  defp placement_internal_error?(
         {:invalid_decommission_write_destination, _set_id, _destination}
       ),
       do: true

  defp placement_internal_error?(_reason), do: false
end
