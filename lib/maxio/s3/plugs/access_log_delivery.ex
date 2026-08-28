defmodule Maxio.S3.Plugs.AccessLogDelivery do
  @moduledoc """
  Best-effort S3 server access log object delivery.

  The plug observes the final response through `register_before_send/2` and
  writes one text log object when the source bucket has BucketLogging enabled.
  Delivery failures are logged but never change the original S3 response.
  """

  @behaviour Plug

  import Plug.Conn

  alias Maxio.{BucketConfigs, BucketQuota, Buckets, Lock, ObjectMeta, Objects, Repo, Storage}
  alias Maxio.Cluster.Placement
  alias Maxio.ObjectMutation.Commit, as: ObjectMutationCommit
  alias Maxio.Policy.ACL
  alias Maxio.S3.{Error, Log, Logging, ObjectLock, OwnershipControls, RawPath, RequestPayment}
  alias Maxio.Storage.ObjectCommit.Control
  alias Maxio.Versioning.VersionId

  @default_account_id "000000000000"
  @default_region "us-east-1"
  @log_content_type "text/plain"

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%{assigns: %{maxio_surface: :admin}} = conn, _opts), do: conn

  def call(conn, _opts) do
    conn
    |> put_private(:maxio_access_log_event_time, event_time(conn))
    |> put_private(:maxio_access_log_started_at, System.monotonic_time(:microsecond))
    |> register_before_send(&deliver/1)
  end

  defp deliver(conn) do
    try do
      maybe_deliver(conn)
    rescue
      err ->
        Log.error("server access log delivery crashed",
          action: :server_access_log_delivery,
          bucket: conn.assigns[:s3_bucket],
          key: conn.assigns[:s3_key],
          status: conn.status,
          reason: Exception.message(err)
        )
    catch
      kind, reason ->
        Log.error("server access log delivery caught",
          action: :server_access_log_delivery,
          bucket: conn.assigns[:s3_bucket],
          key: conn.assigns[:s3_key],
          status: conn.status,
          reason: inspect({kind, reason})
        )
    end

    conn
  end

  defp maybe_deliver(%{method: "OPTIONS"}), do: :ok

  defp maybe_deliver(conn) do
    source_bucket = conn.assigns[:s3_bucket]

    with true <- is_binary(source_bucket) and source_bucket != "",
         {:ok, %{"LoggingEnabled" => enabled}} when is_map(enabled) <-
           logging_config(source_bucket),
         {:ok, target_bucket} <- target_bucket(enabled),
         {:ok, target_info} <- Buckets.lookup(target_bucket),
         source_info = source_bucket_info(source_bucket),
         {:ok, grants} <- target_grants(enabled),
         :ok <- validate_target_delivery(grants, source_info, target_info) do
      delivery_time = DateTime.utc_now()

      key =
        log_object_key(
          enabled,
          source_bucket,
          source_info.region,
          event_time(conn),
          delivery_time
        )

      line = log_line(conn, source_bucket)

      write_log_object(target_info, key, line, source_bucket, grants)
    else
      false ->
        :ok

      {:ok, %{"LoggingEnabled" => nil}} ->
        :ok

      {:error, :not_found} ->
        Log.warn("server access log target bucket missing",
          action: :server_access_log_delivery,
          bucket: source_bucket,
          reason: :target_bucket_missing
        )

      {:error, reason} ->
        Log.warn("server access log delivery skipped",
          action: :server_access_log_delivery,
          bucket: source_bucket,
          reason: inspect(reason)
        )

      {:skip, reason} ->
        Log.warn("server access log delivery skipped",
          action: :server_access_log_delivery,
          bucket: source_bucket,
          reason: inspect(reason)
        )

      _other ->
        :ok
    end
  end

  defp logging_config(bucket) do
    Logging.get_config(bucket)
  rescue
    err in Error ->
      {:error, {:invalid_logging_config, err.code}}
  end

  defp target_bucket(%{"TargetBucket" => bucket}) when is_binary(bucket) and bucket != "",
    do: {:ok, bucket}

  defp target_bucket(_enabled), do: {:error, :invalid_logging_config}

  defp source_bucket_info(bucket) do
    case Buckets.lookup(bucket) do
      {:ok, info} ->
        %{region: info.region || @default_region}

      {:error, :not_found} ->
        %{region: @default_region}
    end
  end

  defp validate_target_delivery(grants, source_info, target_info) do
    target_region = target_info.region || @default_region

    cond do
      target_region != source_info.region ->
        {:skip, {:target_region_mismatch, source_info.region, target_region}}

      grants != [] and OwnershipControls.bucket_owner_enforced?(target_info.name) ->
        {:skip, :target_grants_with_bucket_owner_enforced}

      requester_pays?(target_info.name) ->
        {:skip, :target_requester_pays_enabled}

      object_lock_enabled?(target_info.name) ->
        {:skip, :target_object_lock_enabled}

      true ->
        :ok
    end
  end

  # ObjectMutation Phase 2A（C4）：PG 写权威（默认）下 access log delivery 全程 journal 化
  # （operation="generated_put"）。AccessLog 是无锁 caller——around 回调内取
  # `Lock.with_object_lock`（与 do_put 完全同构，D5；log key 含时间戳+随机后缀，锁近零竞争）。
  # :sidecar 写权威维持既有非协议路径逐字节不变（D1，协议化归 Phase 2B）。原「metadata
  # 失败后 plain Storage.delete」回滚点（cleanup_log_object）随迁移删除——publish 后
  # metadata 失败由 seam restore（pg）/ ObjectCommit rollback（sidecar）收敛，旧对象保留。
  #
  # D2 裁决（照常 journal 化，正确性优先，禁止采样/批量/旁路）：每个启用 BucketLogging 的
  # 请求 +1 journal 行生命周期（1 INSERT + ~4 次 phase UPDATE）+ 每 endpoint 2 次 epoch
  # CAS fsync。该 feature 按桶 opt-in，短期可接受；正确的性能出路是 AWS 原生的批量聚合
  # 投递重设计（产品行为变更，非 2A 范围，已记 STATUS 遗留）；journal 终态行 GC 归 Phase 2C。
  #
  # 公开仅为测试可直接驱动（构造同 key 覆盖 + metadata 失败注入 + 锁存在性断言，
  # Phase 2A C4 验收断言 2/4）；生产路径唯一调用者是 maybe_deliver/1。
  @doc false
  def write_log_object(target_bucket, key, line, source_bucket, grants) do
    body = line <> "\n"
    bucket = target_bucket.name
    version_id = version_id_for(target_bucket)
    acl_canned = ACL.classify_grants(grants)
    acl_grants = ACL.grants_doc(grants)
    user_metadata = %{"maxio-log-source-bucket" => source_bucket}

    with {:ok, chunks, visible_size, sse_attrs, sse_object_meta} <-
           prepare_log_payload(bucket, body) do
      object_meta =
        %{
          size: visible_size,
          content_type: @log_content_type,
          acl_canned: acl_canned,
          acl_grants: acl_grants,
          storage_class: "STANDARD",
          user_metadata: user_metadata,
          tags: %{}
        }
        |> Map.merge(sse_object_meta)

      # 元数据 attrs 构造对两条提交路径同源（published_result 携 placement 快照）。
      committed_attrs = fn write_info, published_result ->
        %{
          size: visible_size,
          etag: write_info.etag,
          content_type: @log_content_type,
          acl_canned: acl_canned,
          acl_grants: acl_grants,
          storage_class: "STANDARD",
          metadata: user_metadata,
          tags: %{}
        }
        |> Map.merge(sse_attrs)
        |> Map.merge(Placement.attrs_from_result(published_result))
      end

      around_object_commit = fn write_info, publish ->
        case ObjectMeta.authoritative_source(:write) do
          :sidecar ->
            commit_log_sidecar_authority(
              bucket,
              key,
              version_id,
              object_meta,
              committed_attrs,
              write_info,
              publish
            )

          _pg ->
            case Lock.with_object_lock({bucket, key}, fn ->
                   commit_log_pg_authority(
                     bucket,
                     key,
                     version_id,
                     visible_size,
                     object_meta,
                     committed_attrs,
                     write_info,
                     publish
                   )
                 end) do
              {:ok, result} -> result
              {:error, :locked} = error -> error
            end
        end
      end

      case Storage.put(bucket, key, version_id, chunks,
             object_meta: object_meta,
             around_object_commit: around_object_commit
           ) do
        {:ok, %{}} ->
          log_delivered(bucket, key, visible_size)

        {:error, %Error{} = err} ->
          # S3 语义错误（如 target bucket hard quota）：metadata 提交层失败，字节已由
          # seam restore / ObjectCommit rollback 收敛——仅记日志（best-effort），
          # 绝不影响原 S3 响应。
          Log.error("server access log metadata commit failed",
            action: :server_access_log_delivery,
            destination_bucket: bucket,
            key: key,
            reason: Exception.message(err)
          )

        {:error, reason} ->
          # best-effort（D2）：投递失败仅记日志、绝不影响原 S3 响应；publish 后的
          # journal 收敛已由 Commit.run 内部 rollback + recovery 兜底，此处只吞请求层错误。
          Log.warn("server access log storage write failed",
            action: :server_access_log_delivery,
            bucket: source_bucket,
            destination_bucket: bucket,
            key: key,
            reason: inspect(reason)
          )
      end
    else
      {:skip, reason} ->
        Log.warn("server access log storage write failed",
          action: :server_access_log_delivery,
          bucket: source_bucket,
          destination_bucket: bucket,
          key: key,
          reason: inspect(reason)
        )
    end
  end

  # :sidecar 写权威（D1）：publish 即权威提交（盘上 sidecar 为事实来源），PG index
  # best-effort——失败仅记日志、绝不回删字节；行为与迁移前逐字节一致（协议化归 Phase 2B）。
  # S3 语义错误（如 bucket hard quota）由 put_version_index 重抛：转 {:error, err} 交
  # ObjectCommit rollback 恢复先前状态（不再 plain delete），投递保持 best-effort。
  defp commit_log_sidecar_authority(
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
          attrs = committed_attrs.(write_info, published_result)

          case Objects.put_version_index(bucket, key, version_id, attrs) do
            :ok ->
              :ok

            {:error, reason} ->
              Log.error(
                "server access log pg index update failed (object durably stored in sidecars)",
                action: :server_access_log_delivery,
                destination_bucket: bucket,
                key: key,
                reason: inspect(reason)
              )
          end

          accelerate_mark_committed(write_info, bucket, key, version_id)

          {:ok, Map.put(published_result, :around_object_commit_result, :delivered)}
        rescue
          err -> {:error, err}
        catch
          kind, reason -> {:error, {kind, reason}}
        end

      {:error, _reason} = error ->
        error
    end
  end

  # PG 写权威：ObjectMutation seam（协议 §0.2 序列）。metadata_tx = put_version_with_id +
  # Commit.transaction_hook(journal)——journal metadata_committed 与 PG row 同一事务，
  # CAS 失败整体回滚；publish 后 metadata 失败由 seam restore 收敛（unversioned 覆盖时
  # 旧对象逐字节恢复、backup 保留），绝不 plain delete。metadata_tx 内 rescue/catch 转
  # {:error, err}（协议契约：closure 不 raise），维持投递 best-effort 值语义。
  defp commit_log_pg_authority(
         bucket,
         key,
         version_id,
         visible_size,
         object_meta,
         committed_attrs,
         write_info,
         publish
       ) do
    # do_put 同构的锁内 quota 预检：超限在 claim/publish 之前以 {:error, %Error{}} 收敛
    # （fail-closed、零 journal、无孤儿字节）——publish 后再失败只能 seam restore，而
    # fresh key 的 rollback 会留下 API 不可见的已发布字节（Phase 1 遗留，2C 读屏障）。
    with :ok <- ensure_log_write_allowed(bucket, key, version_id, visible_size) do
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
          try do
            case Objects.put_version_with_id(
                   bucket,
                   key,
                   version_id,
                   committed_attrs.(write_info, published_result),
                   transaction_hook: ObjectMutationCommit.transaction_hook(journal)
                 ) do
              {:ok, {%Objects.Object{}, :ok}} -> {:ok, :committed}
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
        {:ok, %{published: published_result}} ->
          {:ok, Map.put(published_result, :around_object_commit_result, :delivered)}

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp ensure_log_write_allowed(bucket, key, version_id, visible_size) do
    :ok = BucketQuota.ensure_write_allowed!(Repo, bucket, key, version_id, visible_size)
  rescue
    err in Error -> {:error, err}
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

  defp log_delivered(bucket, key, size) do
    Log.info("server access log delivered",
      action: :server_access_log_delivery,
      destination_bucket: bucket,
      key: key,
      size: size
    )
  end

  defp prepare_log_payload(target_bucket, body) do
    case BucketConfigs.get(target_bucket, :encryption) do
      :none ->
        {:ok, [body], byte_size(body), %{}, %{}}

      {:ok, %{"algorithm" => "AES256"}} ->
        {cipher_stream, envelope} = Maxio.Crypto.SSE.wrap_stream([body])

        {:ok, cipher_stream, byte_size(body), %{sse_algorithm: "AES256", sse_envelope: envelope},
         %{sse: %{"algo" => "AES256", "envelope" => envelope}}}

      {:ok, %{"algorithm" => algorithm}} ->
        {:skip, {:unsupported_target_encryption, algorithm}}

      {:ok, _config} ->
        {:skip, :invalid_target_encryption}
    end
  rescue
    err in Error ->
      {:skip, {:invalid_target_encryption, err.code}}

    err ->
      {:skip, {:invalid_target_encryption, Exception.message(err)}}
  end

  defp requester_pays?(bucket) do
    case RequestPayment.get_config(bucket) do
      {:ok, %{"Payer" => "Requester"}} -> true
      {:ok, _config} -> false
    end
  rescue
    _err -> true
  end

  defp object_lock_enabled?(bucket) do
    case ObjectLock.get_config(bucket) do
      {:ok, %{"ObjectLockEnabled" => "Enabled"}} -> true
      :none -> false
      {:ok, _config} -> false
    end
  rescue
    _err -> true
  end

  defp version_id_for(%{versioning: "Enabled"}), do: VersionId.generate()
  defp version_id_for(_bucket), do: "null"

  defp log_object_key(enabled, source_bucket, source_region, event_time, delivery_time) do
    prefix = Map.get(enabled, "TargetPrefix", "")
    format = Map.get(enabled, "TargetObjectKeyFormat", %{"type" => "simple"})

    case format do
      %{"type" => "partitioned"} ->
        partition_time =
          if Map.get(format, "partition_date_source") == "DeliveryTime",
            do: delivery_time,
            else: event_time

        prefix <>
          Enum.join(
            [
              account_id(),
              source_region,
              source_bucket,
              Calendar.strftime(partition_time, "%Y"),
              Calendar.strftime(partition_time, "%m"),
              Calendar.strftime(partition_time, "%d"),
              log_file_name(delivery_time)
            ],
            "/"
          )

      _simple ->
        prefix <> log_file_name(delivery_time)
    end
  end

  defp log_file_name(time) do
    Calendar.strftime(time, "%Y-%m-%d-%H-%M-%S") <>
      "-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false) <> ".log"
  end

  defp log_line(conn, bucket) do
    total_time = elapsed_ms(conn)
    turnaround_time = total_time

    [
      account_id(),
      bucket,
      "[" <> Calendar.strftime(event_time(conn), "%d/%b/%Y:%H:%M:%S +0000") <> "]",
      remote_ip(conn),
      requester(conn),
      request_id(conn),
      operation(conn),
      token_field(conn.assigns[:s3_key]),
      quote_field(request_line(conn)),
      status(conn),
      error_code(conn),
      bytes_sent(conn),
      object_size(conn),
      Integer.to_string(total_time),
      Integer.to_string(turnaround_time),
      quote_field(header(conn, "referer")),
      quote_field(header(conn, "user-agent")),
      version_id(conn),
      "-",
      signature_version(conn),
      "-",
      auth_type(conn),
      host_header(conn),
      tls_version(conn),
      "-",
      "-"
    ]
    |> Enum.join(" ")
  end

  defp event_time(conn) do
    case conn.private[:maxio_access_log_event_time] || conn.private[:maxio_now] do
      %DateTime{} = time -> time
      _other -> DateTime.utc_now()
    end
  end

  defp elapsed_ms(conn) do
    case conn.private[:maxio_access_log_started_at] do
      started when is_integer(started) ->
        max(System.monotonic_time(:microsecond) - started, 0)
        |> div(1000)

      _other ->
        0
    end
  end

  defp account_id do
    Application.get_env(:maxio, :sts, [])
    |> Keyword.get(:account_id, @default_account_id)
  end

  defp requester(%{assigns: %{principal: :anonymous}}), do: "-"

  defp requester(conn) do
    case conn.assigns[:principal] do
      %{access_key: access_key} when is_binary(access_key) -> access_key
      %{session_access_key: access_key} when is_binary(access_key) -> access_key
      %{arn: arn} when is_binary(arn) -> arn
      %{"access_key" => access_key} when is_binary(access_key) -> access_key
      %{"session_access_key" => access_key} when is_binary(access_key) -> access_key
      %{"arn" => arn} when is_binary(arn) -> arn
      _other -> "-"
    end
  end

  defp request_id(conn) do
    header(conn, "x-request-id") ||
      response_header(conn, "x-request-id") ||
      "-"
  end

  defp operation(conn) do
    case conn.assigns[:s3_action] do
      action when is_atom(action) -> Atom.to_string(action)
      action when is_binary(action) and action != "" -> action
      _other -> fallback_operation(conn)
    end
  end

  defp fallback_operation(conn), do: String.downcase(conn.method || "unknown")

  defp request_line(conn) do
    path = RawPath.decoded_path(conn)
    path = if conn.query_string in [nil, ""], do: path, else: path <> "?" <> conn.query_string
    (conn.method || "UNKNOWN") <> " " <> path <> " HTTP/1.1"
  end

  defp status(%{status: status}) when is_integer(status), do: Integer.to_string(status)
  defp status(_conn), do: "-"

  defp error_code(%{status: status}) when is_integer(status) and status < 400, do: "-"

  defp error_code(conn) do
    conn.resp_body
    |> response_body_binary()
    |> xml_error_code()
    |> case do
      nil -> "-"
      code -> token_field(code)
    end
  end

  defp response_body_binary(body) when is_binary(body), do: body
  defp response_body_binary(body) when is_list(body), do: IO.iodata_to_binary(body)
  defp response_body_binary(_body), do: ""

  defp xml_error_code(body) when is_binary(body) do
    case Regex.run(~r/<Code>([^<]+)<\/Code>/, body) do
      [_match, code] -> code
      _other -> nil
    end
  end

  defp bytes_sent(conn) do
    case response_header(conn, "content-length") do
      nil -> body_length(conn.resp_body)
      value -> token_field(value)
    end
  end

  defp body_length(nil), do: "-"
  defp body_length(body) when is_binary(body), do: Integer.to_string(byte_size(body))
  defp body_length(body) when is_list(body), do: Integer.to_string(IO.iodata_length(body))
  defp body_length(_body), do: "-"

  defp object_size(conn) do
    case header(conn, "content-length") || response_header(conn, "content-length") do
      nil -> "-"
      value -> token_field(value)
    end
  end

  defp version_id(conn), do: response_header(conn, "x-amz-version-id") || "-"

  defp signature_version(conn) do
    case conn.assigns[:auth_type] do
      :header -> "SigV4"
      :presigned -> "SigV4"
      :post -> "SigV4"
      :sigv4_header -> "SigV4"
      :sigv4_presigned -> "SigV4"
      :post_policy -> "SigV4"
      :anonymous -> "-"
      nil -> "-"
      other -> token_field(other)
    end
  end

  defp auth_type(conn) do
    case conn.assigns[:auth_type] do
      nil -> "-"
      auth -> token_field(auth)
    end
  end

  defp host_header(conn), do: token_field(header(conn, "host") || conn.host)
  defp tls_version(_conn), do: "-"

  defp remote_ip(%{remote_ip: remote_ip}) when is_tuple(remote_ip) do
    remote_ip |> :inet.ntoa() |> to_string()
  rescue
    _err -> "-"
  end

  defp remote_ip(_conn), do: "-"

  defp target_grants(%{"TargetGrants" => grants}) when is_list(grants) do
    case Logging.target_grants_to_acl(grants) do
      {:ok, normalized} -> {:ok, normalized}
      {:error, reason} -> {:error, {:invalid_target_grants, reason}}
    end
  end

  defp target_grants(_enabled), do: {:ok, []}

  defp token_field(nil), do: "-"
  defp token_field(""), do: "-"

  defp token_field(value) do
    value
    |> to_string()
    |> URI.encode(&token_char?/1)
  end

  defp token_char?(?/), do: true
  defp token_char?(char), do: URI.char_unreserved?(char)

  defp quote_field(nil), do: "-"
  defp quote_field(""), do: "-"

  defp quote_field(value) do
    escaped =
      value
      |> to_string()
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")
      |> String.replace("\r", " ")
      |> String.replace("\n", " ")

    "\"" <> escaped <> "\""
  end

  defp header(conn, name), do: conn |> get_req_header(name) |> List.first()
  defp response_header(conn, name), do: conn |> get_resp_header(name) |> List.first()
end
