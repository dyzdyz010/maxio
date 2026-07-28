defmodule Maxio.S3.Handlers.Restore do
  @moduledoc """
  RestoreObject control-plane handler.

  maxio does not yet move bytes to a real archive tier. For cold storage classes,
  RestoreObject records S3-visible restore metadata so HEAD/GET can expose
  `x-amz-restore` and GET can fail closed until a restore request succeeds.
  """

  import Plug.Conn

  alias Maxio.{Buckets, KMS, Lock, Metadata, ObjectRestoreSidecar, Objects, Tags}
  alias Maxio.Cluster.Placement
  alias Maxio.Policy.ACL

  alias Maxio.S3.{
    Authz,
    ControlBody,
    Error,
    ExpectedBucketOwner,
    Log,
    NotificationDelivery,
    NotificationRetainedLedger,
    ObjectWriter,
    OwnershipControls,
    PublicAccessBlock,
    RequestPayer,
    SSE
  }

  alias Maxio.S3.RequestParsers.Restore, as: Parser
  alias Maxio.S3.SelectRunner
  alias Maxio.Versioning.VersionId

  @limit 131_072
  @select_output_chunk_size 64 * 1024
  @owner_id "maxio"

  @spec post(Plug.Conn.t()) :: Plug.Conn.t()
  def post(conn) do
    bucket = conn.assigns.s3_bucket
    key = conn.assigns.s3_key
    conn = fetch_query_params(conn)
    _ = ensure_bucket!(bucket)
    :ok = ExpectedBucketOwner.verify!(conn, bucket, resource: "/#{bucket}/#{key}")
    charge = RequestPayer.require!(conn, bucket, resource: "/#{bucket}/#{key}")
    :ok = validate_object_key!(bucket, key)

    version_id =
      conn.query_params
      |> Map.get("versionId")
      |> VersionId.normalize_param()

    :ok = validate_version_id!(bucket, key, version_id)
    {conn, xml} = read_small_body!(conn)

    request =
      case Parser.parse(xml) do
        {:ok, request} ->
          request

        {:error, :malformed_xml} ->
          raise Error.new(:malformed_xml, resource: "/#{bucket}/#{key}")
      end

    if select_restore?(request) do
      restore_select_object(conn, bucket, key, version_id, request, charge)
    else
      restore_archive_object(conn, bucket, key, version_id, request, charge)
    end
  end

  defp restore_archive_object(conn, bucket, key, version_id, request, charge) do
    case restore_object_authoritative(conn, bucket, key, version_id, request) do
      {:ok, object, status, _attrs, notification_delivery} ->
        Log.info("restore object metadata updated",
          action: :restore_object,
          bucket: bucket,
          key: key,
          version_id: object.version_id,
          storage_class: object.storage_class,
          days: request["Days"],
          tier: request["Tier"],
          status: status
        )

        deliver_committed_notification(notification_delivery)

        conn
        |> maybe_put_version_id(object.version_id)
        |> RequestPayer.put_charged_header(charge)
        |> send_resp(status, "")

      {:error, :not_found} ->
        raise Error.new(:no_such_key, resource: "/#{bucket}/#{key}")

      {:error, reason} when reason in [:write_quorum, :read_quorum, :no_topology] ->
        raise Error.new(:slow_down_write, resource: "/#{bucket}/#{key}")

      {:error, :locked} ->
        raise Error.new(:request_timeout, resource: "/#{bucket}/#{key}")

      {:error, _reason} ->
        raise Error.new(:internal_error, resource: "/#{bucket}/#{key}")
    end
  end

  defp restore_select_object(conn, bucket, key, version_id, request, source_charge) do
    :ok = Authz.authorize(conn, :get_object)
    object = restore_object_or_raise(bucket, key, version_id)
    :ok = SelectRunner.validate_sse_read_headers!(conn, object, bucket, key)

    select_request = Map.fetch!(request, "SelectParameters")
    output = Map.fetch!(request, "OutputLocation")
    :ok = reject_unsupported_output_location!(output, bucket, key)

    output_bucket = Map.fetch!(output, "BucketName")
    {output_prefix, output_key} = restore_output_paths(Map.fetch!(output, "Prefix"))
    output_storage_class = Map.fetch!(output, "StorageClass")

    _ = ensure_bucket!(output_bucket)

    output_charge =
      RequestPayer.require!(conn, output_bucket, resource: "/#{output_bucket}/#{output_key}")

    output_acl_input = output_acl_input!(output)
    {output_tag_list, output_tags} = validate_output_tags!(output, output_bucket, output_key)
    output_metadata = validate_output_metadata!(output)

    :ok = validate_output_acl!(output_bucket, output_key, output_acl_input)

    output_sse_target =
      output_encryption_target!(output_bucket, Map.get(output, "Encryption"), bucket, key)

    output_conn = output_write_conn(conn, output_bucket, output_key, output)
    :ok = authorize_output_tags!(output_conn, output_bucket, output_key, output_tag_list)
    :ok = authorize_output_put!(output_conn)

    stream =
      SelectRunner.stage_object!(conn, object, select_request,
        bucket: bucket,
        key: key,
        allow_archive?: true
      )

    written =
      try do
        output_stream = File.stream!(stream.path, @select_output_chunk_size, [:read, :binary])

        ObjectWriter.put_generated!(output_bucket, output_key, output_stream,
          content_type: restore_select_content_type(select_request),
          storage_class: output_storage_class,
          metadata: output_metadata,
          tags: output_tags,
          acl_canned: output_acl_input.canned,
          acl_grants: output_acl_input.grants_doc,
          sse_target: output_sse_target,
          action: :restore_object_select
        )
      after
        SelectRunner.cleanup_stream(stream)
      end

    Log.info("restore object select output written",
      action: :restore_object_select,
      bucket: bucket,
      key: key,
      version_id: object.version_id,
      output_bucket: output_bucket,
      output_key: output_key,
      output_version_id: written.version_id,
      bytes_scanned: stream.bytes_scanned,
      bytes_processed: stream.bytes_processed,
      bytes_returned: stream.bytes_returned
    )

    conn
    |> maybe_put_version_id(object.version_id)
    |> put_resp_header("x-amz-restore-output-path", output_prefix)
    |> RequestPayer.put_charged_header(RequestPayer.merge(source_charge, output_charge))
    |> send_resp(200, "")
  end

  defp restore_response_and_attrs(object, %{"Days" => days}) do
    attrs = %{
      restore_status: "restored",
      restore_expiry: DateTime.add(DateTime.utc_now(), days * 86_400, :second)
    }

    if restore_active?(object), do: {200, attrs}, else: {202, attrs}
  end

  defp select_restore?(%{"Type" => "SELECT"}), do: true
  defp select_restore?(_request), do: false

  defp reject_unsupported_output_location!(%{"Unsupported" => unsupported}, bucket, key)
       when is_list(unsupported) and unsupported != [] do
    raise Error.new(:not_implemented,
            message:
              "RestoreObject SELECT OutputLocation elements are not implemented: " <>
                Enum.join(unsupported, ","),
            resource: "/#{bucket}/#{key}"
          )
  end

  defp reject_unsupported_output_location!(_output, _bucket, _key), do: :ok

  defp validate_output_tags!(output, output_bucket, output_key) do
    tags = Map.get(output, "Tagging", [])

    case Tags.validate(tags, :object) do
      :ok ->
        {tags, Tags.list_to_map(tags)}

      {:error, :invalid_tag} ->
        raise Error.new(:invalid_tag, resource: "/#{output_bucket}/#{output_key}")
    end
  end

  defp authorize_output_tags!(_conn, _bucket, _key, []), do: :ok

  defp authorize_output_tags!(conn, bucket, key, tags),
    do: Authz.authorize_put_object_tagging(conn, bucket, key, nil, tags)

  defp validate_output_metadata!(output) do
    metadata = Map.get(output, "UserMetadata", %{})
    :ok = Metadata.validate_size!(metadata)
    metadata
  end

  defp output_acl_input!(%{"AccessControlList" => grants}) when is_list(grants) do
    stored_grants = ACL.drop_owner_grants(grants, @owner_id)

    %{
      canned: ACL.classify_grants(stored_grants),
      grants_doc: ACL.grants_doc(stored_grants),
      explicit?: true,
      grant_list?: true,
      original_grants: grants
    }
  end

  defp output_acl_input!(%{"CannedACL" => canned}) do
    %{
      canned: canned,
      grants_doc: ACL.empty_grants_doc(),
      explicit?: true,
      grant_list?: false,
      original_grants: []
    }
  end

  defp output_acl_input!(_output) do
    %{
      canned: "private",
      grants_doc: ACL.empty_grants_doc(),
      explicit?: false,
      grant_list?: false,
      original_grants: []
    }
  end

  defp validate_output_acl!(output_bucket, output_key, acl_input) do
    if acl_input.explicit? and OwnershipControls.bucket_owner_enforced?(output_bucket) and
         not bucket_owner_enforced_acl_allowed?(acl_input) do
      raise Error.new(:access_control_list_not_supported,
              resource: "/#{output_bucket}/#{output_key}"
            )
    end

    PublicAccessBlock.reject_public_acl_write!(output_bucket, acl_input)
  end

  defp bucket_owner_enforced_acl_allowed?(%{grant_list?: false, canned: canned}) do
    canned == "bucket-owner-full-control"
  end

  defp bucket_owner_enforced_acl_allowed?(%{grant_list?: true, original_grants: grants}) do
    grants != [] and Enum.all?(grants, &owner_full_control_grant?/1)
  end

  defp owner_full_control_grant?(%{
         "grantee" => %{"type" => "CanonicalUser", "id" => @owner_id},
         "permission" => "FULL_CONTROL"
       }),
       do: true

  defp owner_full_control_grant?(_grant), do: false

  defp output_encryption_target!(output_bucket, nil, _bucket, _key) do
    SSE.resolve_target!([], output_bucket)
  end

  defp output_encryption_target!(
         _output_bucket,
         %{"EncryptionType" => "AES256"} = encryption,
         bucket,
         key
       ) do
    reject_kms_encryption_fields!(encryption, bucket, key)
    "AES256"
  end

  defp output_encryption_target!(
         _output_bucket,
         %{"EncryptionType" => "aws:kms"} = encryption,
         _bucket,
         _key
       ) do
    {:kms, kms_key_id(encryption), normalize_kms_context!(Map.get(encryption, "KMSContext")),
     false}
  end

  defp output_encryption_target!(
         _output_bucket,
         %{"EncryptionType" => "aws:kms:dsse"} = encryption,
         _bucket,
         _key
       ) do
    {:kms_dsse, kms_key_id(encryption), normalize_kms_context!(Map.get(encryption, "KMSContext"))}
  end

  defp output_encryption_target!(_output_bucket, %{"EncryptionType" => "aws:fsx"}, bucket, key) do
    raise Error.new(:not_implemented,
            message: "RestoreObject SELECT OutputLocation aws:fsx encryption is not implemented",
            resource: "/#{bucket}/#{key}"
          )
  end

  defp reject_kms_encryption_fields!(encryption, bucket, key) do
    if Map.has_key?(encryption, "KMSKeyId") or Map.has_key?(encryption, "KMSContext") do
      raise Error.new(:invalid_argument,
              message: "KMSKeyId and KMSContext require aws:kms or aws:kms:dsse encryption",
              resource: "/#{bucket}/#{key}"
            )
    end

    :ok
  end

  defp kms_key_id(encryption) do
    case Map.get(encryption, "KMSKeyId") do
      key_id when is_binary(key_id) and key_id != "" -> key_id
      _other -> KMS.default_key_id()
    end
  end

  defp normalize_kms_context!(nil), do: nil
  defp normalize_kms_context!(""), do: nil

  defp normalize_kms_context!(context_b64) do
    with {:ok, decoded} <- Base.decode64(context_b64),
         {:ok, %{} = _json} <- Jason.decode(decoded) do
      Base.encode64(decoded)
    else
      {:ok, _not_object} ->
        raise Error.new(:invalid_argument,
                message: "KMSContext must decode to a JSON object"
              )

      _other ->
        raise Error.new(:invalid_argument,
                message: "RestoreObject SELECT OutputLocation encryption is invalid"
              )
    end
  end

  defp restore_output_paths(prefix) when is_binary(prefix) do
    base = if String.ends_with?(prefix, "/"), do: prefix, else: prefix <> "/"
    output_prefix = base <> VersionId.generate() <> "/"
    {output_prefix, output_prefix <> "part-00000"}
  end

  defp restore_select_content_type(%{output: %{format: "CSV"}}), do: "text/csv"
  defp restore_select_content_type(%{output: %{format: "JSON"}}), do: "application/json"
  defp restore_select_content_type(_request), do: "binary/octet-stream"

  defp output_write_conn(conn, bucket, key, output) do
    %{
      conn
      | method: "PUT",
        query_params: %{},
        query_string: "",
        req_headers: output_write_headers(output),
        assigns:
          conn.assigns
          |> Map.put(:s3_bucket, bucket)
          |> Map.put(:s3_key, key)
          |> Map.put(:s3_action, :put_object)
    }
  end

  defp output_write_headers(output) do
    []
    |> maybe_output_acl_header(output)
    |> maybe_output_tagging_header(Map.get(output, "Tagging", []))
    |> maybe_output_encryption_headers(Map.get(output, "Encryption"))
  end

  defp maybe_output_acl_header(headers, output) do
    cond do
      Map.has_key?(output, "CannedACL") ->
        [{"x-amz-acl", Map.fetch!(output, "CannedACL")} | headers]

      Map.has_key?(output, "AccessControlList") ->
        output
        |> Map.fetch!("AccessControlList")
        |> grant_headers()
        |> Enum.concat(headers)

      true ->
        headers
    end
  end

  defp grant_headers(grants) do
    grants
    |> Enum.group_by(& &1["permission"], &grant_header_value/1)
    |> Enum.map(fn {permission, values} ->
      {grant_header_name(permission), Enum.join(values, ", ")}
    end)
    |> Enum.reject(fn {name, _value} -> is_nil(name) end)
  end

  defp grant_header_name("READ"), do: "x-amz-grant-read"
  defp grant_header_name("WRITE"), do: "x-amz-grant-write"
  defp grant_header_name("READ_ACP"), do: "x-amz-grant-read-acp"
  defp grant_header_name("WRITE_ACP"), do: "x-amz-grant-write-acp"
  defp grant_header_name("FULL_CONTROL"), do: "x-amz-grant-full-control"
  defp grant_header_name(_permission), do: nil

  defp grant_header_value(%{"grantee" => %{"type" => "CanonicalUser", "id" => id}}),
    do: ~s(id="#{id}")

  defp grant_header_value(%{"grantee" => %{"type" => "Group", "uri" => uri}}),
    do: ~s(uri="#{uri}")

  defp maybe_output_tagging_header(headers, []), do: headers

  defp maybe_output_tagging_header(headers, tags) do
    [{"x-amz-tagging", tagging_header(tags)} | headers]
  end

  defp maybe_output_encryption_headers(headers, nil), do: headers

  defp maybe_output_encryption_headers(headers, %{"EncryptionType" => "AES256"}) do
    [{"x-amz-server-side-encryption", "AES256"} | headers]
  end

  defp maybe_output_encryption_headers(headers, %{"EncryptionType" => type} = encryption)
       when type in ["aws:kms", "aws:kms:dsse"] do
    headers
    |> maybe_prepend_header(
      "x-amz-server-side-encryption-context",
      Map.get(encryption, "KMSContext")
    )
    |> maybe_prepend_header(
      "x-amz-server-side-encryption-aws-kms-key-id",
      Map.get(encryption, "KMSKeyId")
    )
    |> prepend_header("x-amz-server-side-encryption", type)
  end

  defp maybe_output_encryption_headers(headers, %{"EncryptionType" => type}) do
    [{"x-amz-server-side-encryption", type} | headers]
  end

  defp tagging_header(tags) do
    tags
    |> Enum.map(fn {key, value} ->
      URI.encode_www_form(key) <> "=" <> URI.encode_www_form(value)
    end)
    |> Enum.join("&")
  end

  defp maybe_prepend_header(headers, _name, nil), do: headers
  defp maybe_prepend_header(headers, _name, ""), do: headers
  defp maybe_prepend_header(headers, name, value), do: prepend_header(headers, name, value)
  defp prepend_header(headers, name, value), do: [{name, value} | headers]

  defp authorize_output_put!(conn) do
    Authz.authorize(conn, :put_object)
  end

  defp restore_object_authoritative(conn, bucket, key, version_id, request) do
    case Maxio.ObjectMeta.authoritative_source(:write) do
      :sidecar ->
        update_restore_state_sidecar(conn, bucket, key, version_id, request)

      _pg ->
        object = restore_object_or_raise(bucket, key, version_id)
        {status, attrs} = restore_response_and_attrs(object, request)
        notifications = restore_notifications(conn, bucket, key, object, attrs, status)

        case update_restore_state_pg(bucket, key, object.version_id, attrs, notifications) do
          {:ok, notification_delivery} -> {:ok, object, status, attrs, notification_delivery}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp update_restore_state_sidecar(conn, bucket, key, version_id, request) do
    case Lock.with_object_lock({bucket, key}, fn ->
           object = restore_object_or_raise(bucket, key, version_id)
           {status, attrs} = restore_response_and_attrs(object, request)
           notifications = restore_notifications(conn, bucket, key, object, attrs, status)

           case do_update_restore_state_sidecar(bucket, key, object, attrs, notifications) do
             {:ok, notification_delivery} ->
               {:ok, object, status, attrs, notification_delivery}

             {:error, reason} ->
               {:error, reason}
           end
         end) do
      {:ok, result} -> result
      {:error, :locked} -> {:error, :locked}
    end
  end

  defp do_update_restore_state_sidecar(bucket, key, object, attrs, notifications) do
    recover_retained_notifications!(bucket, key)

    notification_outbox = sidecar_notification_ledger(notifications)
    storage_opts = Placement.storage_opts(object)

    notification_retained_ledger =
      retained_notification_ledger(
        notification_outbox,
        bucket,
        key,
        object,
        attrs,
        notifications,
        storage_opts
      )

    persist_retained_notification_ledger!(
      bucket,
      key,
      notification_retained_ledger,
      storage_opts
    )

    sidecar_opts = Keyword.merge(storage_opts, notification_outbox: notification_outbox)

    case ObjectRestoreSidecar.update(bucket, key, object.version_id, attrs, sidecar_opts) do
      {:ok, generation} ->
        best_effort_restore_index_update(bucket, key, object.version_id, attrs, generation)

        {:ok,
         notification_after_sidecar_commit(
           notifications,
           notification_outbox,
           bucket,
           key,
           notification_retained_ledger,
           storage_opts
         )}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp update_restore_state_pg(bucket, key, version_id, attrs, notifications) do
    case Objects.put_restore_state(
           bucket,
           key,
           version_id,
           attrs,
           notification_transaction_opts(notifications)
         ) do
      {:ok, {_object, enqueued_notifications}} ->
        mirror_restore_sidecar(bucket, key, version_id, attrs)
        {:ok, {:enqueued, enqueued_notifications}}

      {:ok, _object} ->
        mirror_restore_sidecar(bucket, key, version_id, attrs)
        {:ok, :none}

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  defp restore_notifications(conn, bucket, key, object, attrs, status) do
    base_attrs = notification_attrs(conn, bucket, key, object, attrs)
    post = {"s3:ObjectRestore:Post", base_attrs}

    case status do
      202 -> [post, {"s3:ObjectRestore:Completed", base_attrs}]
      _already_active -> [post]
    end
  end

  defp notification_attrs(conn, bucket, key, object, attrs) do
    %{
      bucket: bucket,
      key: key,
      size: object.size,
      etag: object.etag,
      version_id: object.version_id,
      storage_class: object.storage_class,
      source_storage_class: object.storage_class,
      restore_expiry: Map.get(attrs, :restore_expiry),
      request_id: header(conn, "x-request-id"),
      principal: Map.get(conn.assigns, :principal),
      source_ip: conn.remote_ip
    }
  end

  defp notification_transaction_opts([]), do: []

  defp notification_transaction_opts(notifications) when is_list(notifications) do
    [
      transaction_hook: fn repo, _object ->
        Enum.flat_map(notifications, fn {event_name, attrs} ->
          NotificationDelivery.enqueue(event_name, attrs, repo: repo)
        end)
      end
    ]
  end

  defp sidecar_notification_ledger([]), do: []

  defp sidecar_notification_ledger(notifications) when is_list(notifications) do
    case Maxio.ObjectMeta.authoritative_source(:write) do
      :sidecar ->
        Enum.flat_map(notifications, fn {event_name, attrs} ->
          NotificationDelivery.sidecar_ledger(event_name, attrs)
        end)

      _pg ->
        []
    end
  end

  defp retained_notification_ledger(
         [],
         _bucket,
         _key,
         _object,
         _attrs,
         _notifications,
         _storage_opts
       ),
       do: []

  defp retained_notification_ledger(
         ledger,
         bucket,
         key,
         object,
         attrs,
         notifications,
         storage_opts
       ) do
    NotificationRetainedLedger.entries(ledger,
      bucket: bucket,
      key: key,
      operation: :restore_object,
      predicate:
        NotificationRetainedLedger.restore_state_transition(object.version_id, object, attrs,
          entry_type: "object",
          etag: object.etag,
          size: object.size
        ),
      request_id: retained_request_id(notifications),
      storage_opts: storage_opts
    )
  end

  defp persist_retained_notification_ledger!(_bucket, _key, [], _opts), do: :ok

  defp persist_retained_notification_ledger!(bucket, key, entries, opts) do
    case Maxio.ObjectMeta.authoritative_source(:write) do
      :sidecar -> NotificationRetainedLedger.persist!(bucket, key, entries, opts)
      _pg -> :ok
    end
  end

  defp recover_retained_notifications!(bucket, key) do
    case Maxio.ObjectMeta.authoritative_source(:write) do
      :sidecar -> NotificationRetainedLedger.recover_key!(bucket, key)
      _pg -> :ok
    end
  end

  defp retained_request_id([{_event_name, attrs} | _rest]) when is_map(attrs),
    do: Map.get(attrs, :request_id)

  defp retained_request_id(_notifications), do: nil

  defp notification_after_sidecar_commit([], _ledger, _bucket, _key, _retained, _storage_opts),
    do: :none

  defp notification_after_sidecar_commit(_notifications, [], _bucket, _key, [], _storage_opts),
    do: :none

  defp notification_after_sidecar_commit(
         _notifications,
         ledger,
         bucket,
         key,
         retained,
         storage_opts
       ),
       do:
         {:sidecar_ledger, ledger,
          %{bucket: bucket, key: key, retained: retained, storage_opts: storage_opts}}

  defp deliver_committed_notification(:none), do: :ok

  defp deliver_committed_notification({:enqueued, enqueued_notifications}) do
    NotificationDelivery.deliver_enqueued(enqueued_notifications)
  end

  defp deliver_committed_notification({:sidecar_ledger, ledger, context}) do
    ledger
    |> NotificationDelivery.replay_sidecar_ledger()
    |> NotificationDelivery.deliver_enqueued()

    context
    |> Map.get(:retained, [])
    |> NotificationRetainedLedger.replay_committed(Map.get(context, :storage_opts, []))
  rescue
    err ->
      Log.error("bucket notification sidecar ledger replay deferred",
        action: :bucket_notification_delivery,
        bucket: Map.get(context, :bucket),
        key: Map.get(context, :key),
        reason: inspect(err)
      )

      :ok
  end

  defp best_effort_restore_index_update(bucket, key, version_id, attrs, generation) do
    case Objects.put_restore_state(bucket, key, version_id, attrs, generation) do
      {:ok, _object} ->
        :ok

      {:error, reason} ->
        Log.error("pg restore index update failed",
          action: :restore_object,
          bucket: bucket,
          key: key,
          version_id: version_id,
          reason: inspect(reason)
        )
    end
  end

  defp mirror_restore_sidecar(bucket, key, version_id, attrs) do
    case ObjectRestoreSidecar.update(bucket, key, version_id, attrs) do
      {:ok, generation} ->
        _ = Objects.put_restore_state(bucket, key, version_id, attrs, generation)
        :ok

      {:error, reason} ->
        Log.warn("sidecar restore metadata mirror failed (PG remains authoritative)",
          action: :restore_object,
          bucket: bucket,
          key: key,
          version_id: version_id,
          reason: inspect(reason)
        )
    end
  rescue
    e ->
      Log.warn("sidecar restore metadata mirror raised (PG remains authoritative)",
        action: :restore_object,
        bucket: bucket,
        key: key,
        version_id: version_id,
        reason: inspect(e)
      )
  end

  defp restore_object_or_raise(bucket, key, version_id) do
    case Maxio.ObjectMeta.get(bucket, key, version_id, []) do
      %Objects.Object{} = object ->
        :ok = reject_delete_marker!(object, bucket, key)
        :ok = reject_non_archive_storage!(object, bucket, key)
        object

      {:error, :not_found} ->
        raise Error.new(:no_such_key, resource: "/#{bucket}/#{key}")

      {:error, :read_quorum} ->
        raise Error.new(:slow_down_read, resource: "/#{bucket}/#{key}")
    end
  end

  defp reject_delete_marker!(%Objects.Object{is_delete_marker: false}, _bucket, _key), do: :ok

  defp reject_delete_marker!(%Objects.Object{}, bucket, key) do
    raise Error.new(:method_not_allowed, resource: "/#{bucket}/#{key}")
  end

  defp reject_non_archive_storage!(%Objects.Object{storage_class: storage_class}, bucket, key) do
    if archive_storage_class?(storage_class) do
      :ok
    else
      raise Error.new(:invalid_object_state,
              message: "RestoreObject is not valid for this object's storage class",
              resource: "/#{bucket}/#{key}"
            )
    end
  end

  defp archive_storage_class?(storage_class) do
    storage_class in ["GLACIER", "DEEP_ARCHIVE"]
  end

  defp restore_active?(%Objects.Object{
         restore_status: "restored",
         restore_expiry: %DateTime{} = dt
       }) do
    DateTime.compare(dt, DateTime.utc_now()) == :gt
  end

  defp restore_active?(_object), do: false

  defp validate_version_id!(_bucket, _key, nil), do: :ok

  defp validate_version_id!(bucket, key, version_id) do
    if VersionId.valid?(version_id) do
      :ok
    else
      raise Error.new(:invalid_argument,
              message: "Invalid version id specified",
              resource: "/#{bucket}/#{key}"
            )
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

  defp ensure_bucket!(bucket) do
    case Buckets.lookup(bucket) do
      {:ok, bucket} -> bucket
      {:error, :not_found} -> raise Error.new(:no_such_bucket, resource: "/" <> bucket)
    end
  end

  defp read_small_body!(conn) do
    ControlBody.read_and_verify!(
      conn,
      @limit,
      "RestoreRequest exceeds 128KB"
    )
  end

  defp header(conn, name), do: conn |> get_req_header(name) |> List.first()

  defp maybe_put_version_id(conn, "null"), do: conn

  defp maybe_put_version_id(conn, version_id),
    do: put_resp_header(conn, "x-amz-version-id", version_id)
end
