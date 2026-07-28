defmodule Maxio.S3.Handlers.Acl do
  @moduledoc """
  ?acl 子资源 handler：GetBucketAcl/PutBucketAcl/GetObjectAcl/PutObjectAcl。
  Get → AccessControlPolicy XML（canned 或显式 grants 展开）。Put → 接受 x-amz-acl 头、
  x-amz-grant-* 头或 XML body（互斥），归一化为 ACL 元数据。email grantee → 400 InvalidArgument。
  """
  import Plug.Conn
  alias Maxio.{Buckets, ObjectAclSidecar, ObjectMeta, Objects}
  alias Maxio.Policy.ACL
  alias Maxio.Versioning.VersionId

  alias Maxio.S3.{
    ControlBody,
    Error,
    ExpectedBucketOwner,
    Log,
    OwnershipControls,
    PublicAccessBlock,
    RequestPayer
  }

  alias Maxio.S3.Views.AccessControlPolicy, as: AclView
  alias Maxio.S3.RequestParsers.AccessControlPolicy, as: AclParser

  @owner_id "maxio"
  @owner_display "maxio"
  @acl_limit 1_048_576

  @spec get_bucket_acl(Plug.Conn.t()) :: Plug.Conn.t()
  def get_bucket_acl(conn) do
    bucket = conn.assigns.s3_bucket
    b = ensure_bucket!(bucket)
    :ok = ExpectedBucketOwner.verify!(conn, bucket)
    render_acl(conn, b.acl_canned, b.acl_grants)
  end

  @spec put_bucket_acl(Plug.Conn.t()) :: Plug.Conn.t()
  def put_bucket_acl(conn) do
    bucket = conn.assigns.s3_bucket
    _ = ensure_bucket!(bucket)
    :ok = ExpectedBucketOwner.verify!(conn, bucket)
    :ok = OwnershipControls.reject_acl_update!(bucket)
    {conn, %{canned: canned, grants_doc: grants_doc}} = resolve_acl!(conn)

    :ok =
      PublicAccessBlock.reject_public_acl_write!(bucket, %{canned: canned, grants_doc: grants_doc})

    :ok = Buckets.put_acl(bucket, canned, grants_doc)
    Log.info("put bucket acl", action: :put_bucket_acl, bucket: bucket, reason: canned)
    send_resp(conn, 200, "")
  end

  @spec get_object_acl(Plug.Conn.t()) :: Plug.Conn.t()
  def get_object_acl(conn) do
    conn = fetch_query_params(conn)
    bucket = conn.assigns.s3_bucket
    key = conn.assigns.s3_key
    version_id = version_id!(conn, bucket, key)
    _ = ensure_bucket!(bucket)
    :ok = ExpectedBucketOwner.verify!(conn, bucket, resource: "/#{bucket}/#{key}")
    charge = RequestPayer.require!(conn, bucket, resource: "/#{bucket}/#{key}")

    case object_for_acl(bucket, key, version_id) do
      %Objects.Object{} = obj ->
        render_acl(conn, obj.acl_canned, obj.acl_grants, charge, obj.version_id)

      {:error, :delete_marker, obj} ->
        send_delete_marker_response(conn, obj, version_id)

      {:error, :not_found} ->
        raise Error.new(:no_such_key, resource: "/#{bucket}/#{key}")

      {:error, :read_quorum} ->
        raise Error.new(:slow_down_read, resource: "/#{bucket}/#{key}")
    end
  end

  @spec put_object_acl(Plug.Conn.t()) :: Plug.Conn.t()
  def put_object_acl(conn) do
    conn = fetch_query_params(conn)
    bucket = conn.assigns.s3_bucket
    key = conn.assigns.s3_key
    version_id = version_id!(conn, bucket, key)
    _ = ensure_bucket!(bucket)
    :ok = ExpectedBucketOwner.verify!(conn, bucket, resource: "/#{bucket}/#{key}")
    charge = RequestPayer.require!(conn, bucket, resource: "/#{bucket}/#{key}")
    :ok = OwnershipControls.reject_acl_update!(bucket)
    {conn, %{canned: canned, grants_doc: grants_doc}} = resolve_acl!(conn)

    :ok =
      PublicAccessBlock.reject_public_acl_write!(bucket, %{canned: canned, grants_doc: grants_doc})

    commit_result =
      Maxio.Lock.with_object_lock({bucket, key}, fn ->
        target = object_for_acl!(bucket, key, version_id)
        :ok = commit_object_acl!(bucket, key, target.version_id, canned, grants_doc)
        target.version_id
      end)

    case commit_result do
      {:ok, response_version_id} ->
        Log.info("put object acl",
          action: :put_object_acl,
          bucket: bucket,
          key: key,
          reason: canned
        )

        conn
        |> maybe_put_version_id(response_version_id)
        |> RequestPayer.put_charged_header(charge)
        |> send_resp(200, "")

      {:error, :locked} ->
        raise Error.new(:request_timeout, resource: "/#{bucket}/#{key}")
    end
  end

  # ── helpers ──
  defp object_for_acl(bucket, key, version_id) do
    case ObjectMeta.get(bucket, key, version_id, []) do
      %Objects.Object{is_delete_marker: true} = obj -> {:error, :delete_marker, obj}
      %Objects.Object{} = obj -> obj
      {:error, :not_found} -> {:error, :not_found}
      {:error, :read_quorum} -> {:error, :read_quorum}
    end
  end

  defp object_for_acl!(bucket, key, version_id) do
    case object_for_acl(bucket, key, version_id) do
      {:error, :delete_marker, _obj} ->
        raise Error.new(:no_such_key, resource: "/#{bucket}/#{key}")

      %Objects.Object{} = obj ->
        obj

      {:error, :not_found} ->
        raise Error.new(:no_such_key, resource: "/#{bucket}/#{key}")

      {:error, :read_quorum} ->
        raise Error.new(:slow_down_read, resource: "/#{bucket}/#{key}")
    end
  end

  defp commit_object_acl!(bucket, key, version_id, canned, grants_doc) do
    case ObjectMeta.authoritative_source(:write) do
      :sidecar -> commit_object_acl_sidecar!(bucket, key, version_id, canned, grants_doc)
      _pg -> commit_object_acl_pg!(bucket, key, version_id, canned, grants_doc)
    end
  end

  defp commit_object_acl_sidecar!(bucket, key, version_id, canned, grants_doc) do
    case ObjectAclSidecar.update(bucket, key, version_id, canned, grants_doc) do
      {:ok, generation} ->
        best_effort_object_acl_index_update(
          bucket,
          key,
          version_id,
          canned,
          grants_doc,
          generation
        )

      {:error, :not_found} ->
        raise Error.new(:no_such_key, resource: "/#{bucket}/#{key}")

      {:error, :read_quorum} ->
        raise Error.new(:slow_down_read, resource: "/#{bucket}/#{key}")

      {:error, reason} when reason in [:write_quorum, :no_topology] ->
        raise Error.new(:slow_down_write, resource: "/#{bucket}/#{key}")

      {:error, :invalid_key} ->
        raise Error.new(:invalid_object_name, resource: "/#{bucket}/#{key}")
    end
  end

  defp commit_object_acl_pg!(bucket, key, version_id, canned, grants_doc) do
    case Objects.put_acl_version(bucket, key, version_id, canned, grants_doc) do
      :ok ->
        mirror_object_acl_sidecar(bucket, key, version_id, canned, grants_doc)
        :ok

      {:error, :not_found} ->
        raise Error.new(:no_such_key, resource: "/#{bucket}/#{key}")
    end
  end

  defp best_effort_object_acl_index_update(
         bucket,
         key,
         version_id,
         canned,
         grants_doc,
         generation
       ) do
    case Objects.put_acl_version(bucket, key, version_id, canned, grants_doc, generation) do
      :ok ->
        :ok

      {:error, reason} ->
        Log.error("pg index acl update failed (object ACL durably stored in sidecar)",
          action: :put_object_acl,
          bucket: bucket,
          key: key,
          reason: inspect(reason)
        )

        :ok
    end
  end

  defp mirror_object_acl_sidecar(bucket, key, version_id, canned, grants_doc) do
    try do
      case ObjectAclSidecar.update(bucket, key, version_id, canned, grants_doc) do
        {:ok, generation} ->
          case Objects.put_acl_version(bucket, key, version_id, canned, grants_doc, generation) do
            :ok ->
              :ok

            {:error, reason} ->
              Log.warn("pg acl generation sync failed after sidecar mirror",
                action: :put_object_acl,
                bucket: bucket,
                key: key,
                reason: inspect(reason)
              )
          end

        {:error, reason} ->
          Log.warn("sidecar acl mirror failed (PG remains authoritative)",
            action: :put_object_acl,
            bucket: bucket,
            key: key,
            reason: inspect(reason)
          )
      end
    rescue
      e ->
        Log.warn("sidecar acl mirror raised (PG remains authoritative)",
          action: :put_object_acl,
          bucket: bucket,
          key: key,
          reason: inspect(e)
        )
    catch
      kind, reason ->
        Log.warn("sidecar acl mirror caught (PG remains authoritative)",
          action: :put_object_acl,
          bucket: bucket,
          key: key,
          reason: inspect({kind, reason})
        )
    end
  end

  defp render_acl(conn, canned, grants_doc, charge \\ :not_charged, version_id \\ nil) do
    bucket = conn.assigns.s3_bucket

    {canned, grants_doc} =
      if OwnershipControls.bucket_owner_enforced?(bucket) do
        OwnershipControls.effective_acl(bucket, canned, grants_doc)
      else
        PublicAccessBlock.effective_acl(bucket, canned, grants_doc)
      end

    body =
      AclView.render(%{
        canned: canned,
        grants: grants_doc,
        owner_id: @owner_id,
        owner_display: @owner_display
      })

    conn
    |> put_resp_content_type("application/xml")
    |> maybe_put_version_id(version_id)
    |> RequestPayer.put_charged_header(charge)
    |> send_resp(200, body)
  end

  defp maybe_put_version_id(conn, nil), do: conn
  defp maybe_put_version_id(conn, "null"), do: conn

  defp maybe_put_version_id(conn, version_id) when is_binary(version_id),
    do: put_resp_header(conn, "x-amz-version-id", version_id)

  defp send_delete_marker_response(conn, object, nil) do
    conn
    |> put_resp_header("x-amz-delete-marker", "true")
    |> maybe_put_version_id(object.version_id)
    |> send_resp(404, "")
  end

  defp send_delete_marker_response(conn, object, _requested_version_id) do
    conn
    |> put_resp_header("x-amz-delete-marker", "true")
    |> put_resp_header("last-modified", http_date(object.updated_at))
    |> maybe_put_version_id(object.version_id)
    |> send_resp(405, "")
  end

  defp http_date(%DateTime{} = dt), do: Calendar.strftime(dt, "%a, %d %b %Y %H:%M:%S GMT")

  # 归一化 ACL 输入。x-amz-acl / x-amz-grant-* / XML body 三类输入互斥。
  defp resolve_acl!(conn) do
    header_acl = header(conn, "x-amz-acl")
    grant_headers? = ACL.grant_headers?(conn.req_headers)

    cond do
      is_binary(header_acl) and grant_headers? ->
        raise Error.new(:invalid_request,
                message: "Cannot specify both x-amz-acl and x-amz-grant-*"
              )

      is_binary(header_acl) ->
        unless ACL.known?(header_acl) do
          raise Error.new(:invalid_argument, message: "Unsupported x-amz-acl: #{header_acl}")
        end

        conn = reject_acl_body!(conn, "Cannot specify x-amz-acl with ACL XML body")
        {conn, %{canned: header_acl, grants_doc: ACL.empty_grants_doc()}}

      grant_headers? ->
        conn = reject_acl_body!(conn, "Cannot specify x-amz-grant-* with ACL XML body")

        grants =
          conn.req_headers
          |> parse_grant_headers!()
          |> ACL.drop_owner_grants(@owner_id)

        canned = ACL.classify_grants(grants)
        {conn, %{canned: canned, grants_doc: ACL.grants_doc(grants)}}

      true ->
        {conn, xml} = read_acl_xml_body!(conn)

        case AclParser.parse_grants(xml) do
          {:ok, grants} ->
            grants = ACL.drop_owner_grants(grants, @owner_id)
            canned = ACL.classify_grants(grants)
            {conn, %{canned: canned, grants_doc: ACL.grants_doc(grants)}}

          {:error, :unsupported_email} ->
            raise Error.new(:invalid_argument, message: "Email grantee ACLs are not supported")

          {:error, :invalid_grant} ->
            raise Error.new(:invalid_argument, message: "Invalid ACL grant")

          {:error, :too_many_grants} ->
            raise Error.new(:invalid_argument, message: "ACL can contain at most 100 grants")

          {:error, :malformed_xml} ->
            raise Error.new(:malformed_xml)
        end
    end
  end

  defp reject_acl_body!(conn, message) do
    {conn, body} =
      ControlBody.read_and_verify!(conn, @acl_limit, "ACL document too large",
        require_integrity: :optional,
        too_large_error: :entity_too_large
      )

    if body == "" do
      conn
    else
      raise Error.new(:invalid_request, message: message)
    end
  end

  defp parse_grant_headers!(headers) do
    case ACL.parse_grant_headers(headers) do
      {:ok, grants} ->
        grants

      {:error, :unsupported_email} ->
        raise Error.new(:invalid_argument, message: "Email grantee ACLs are not supported")

      {:error, :too_many_grants} ->
        raise Error.new(:invalid_argument, message: "ACL can contain at most 100 grants")

      {:error, :invalid_grant} ->
        raise Error.new(:invalid_argument, message: "Invalid ACL grant")
    end
  end

  defp ensure_bucket!(bucket) do
    case Buckets.lookup(bucket) do
      {:ok, b} -> b
      {:error, :not_found} -> raise Error.new(:no_such_bucket, resource: "/" <> bucket)
    end
  end

  defp read_acl_xml_body!(conn) do
    ControlBody.read_and_verify!(conn, @acl_limit, "ACL document too large",
      require_integrity: :content_md5_or_flexible,
      too_large_error: :entity_too_large
    )
  end

  defp header(conn, name), do: conn |> get_req_header(name) |> List.first()

  defp version_id!(conn, bucket, key) do
    version_id =
      conn.query_params
      |> Map.get("versionId")
      |> VersionId.normalize_param()

    if is_nil(version_id) or VersionId.valid?(version_id) do
      version_id
    else
      raise Error.new(:invalid_argument,
              message: "Invalid version id specified",
              resource: "/#{bucket}/#{key}"
            )
    end
  end
end
