defmodule Maxio.S3.Handlers.ObjectLock do
  @moduledoc """
  ?object-lock handler for Bucket Object Lock configuration APIs.

  Bucket configuration controls default retention. Object retention and legal
  hold APIs write per-version metadata used by object write/delete enforcement.
  """
  import Plug.Conn

  alias Maxio.{Buckets, ObjectLockSidecar, ObjectMeta, Objects}
  alias Maxio.Policy.{Arn, Evaluator, RequestContext}
  alias Maxio.S3.{Checksum, Error, Log, ObjectLock}
  alias Maxio.S3.RequestParsers.ObjectLock, as: Parser
  alias Maxio.S3.Views.ObjectLock, as: View

  @limit 131_072
  @local_account_id "000000000000"

  @spec put(Plug.Conn.t()) :: Plug.Conn.t()
  def put(conn) do
    bucket = conn.assigns.s3_bucket
    bucket_meta = ensure_bucket!(bucket)
    :ok = verify_expected_bucket_owner!(conn, bucket)
    :ok = require_bucket_object_lock_enabled!(bucket_meta)
    :ok = reject_streaming_body!(conn)
    :ok = reject_checksum_trailers!(conn)
    {conn, xml} = read_small_body!(conn)
    :ok = validate_checksums!(conn, xml)

    case Parser.parse(xml) do
      {:ok, config} ->
        :ok = ObjectLock.put_config(bucket, config)

        Log.info("put bucket object lock configuration",
          action: :put_bucket_object_lock_configuration,
          bucket: bucket,
          has_default_retention?: Map.has_key?(config, "Rule")
        )

        send_resp(conn, 200, "")

      {:error, :malformed_xml} ->
        raise Error.new(:malformed_xml, resource: "/" <> bucket)
    end
  end

  @spec get(Plug.Conn.t()) :: Plug.Conn.t()
  def get(conn) do
    bucket = conn.assigns.s3_bucket
    _bucket_meta = ensure_bucket!(bucket)
    :ok = verify_expected_bucket_owner!(conn, bucket)

    case ObjectLock.get_config(bucket) do
      {:ok, config} ->
        conn
        |> put_resp_content_type("application/xml")
        |> send_resp(200, View.render(config))

      :none ->
        raise Error.new(:object_lock_configuration_not_found, resource: "/" <> bucket)
    end
  end

  @spec put_retention(Plug.Conn.t()) :: Plug.Conn.t()
  def put_retention(conn) do
    {conn, bucket, key, version_id} = object_request!(conn)
    :ok = require_bucket_object_lock_enabled!(ensure_bucket!(bucket))
    :ok = reject_streaming_body!(conn)
    :ok = reject_checksum_trailers!(conn)
    {conn, xml} = read_small_body!(conn)
    :ok = validate_optional_checksums!(conn, xml)

    case Parser.parse_retention(xml) do
      {:ok, attrs} ->
        object =
          with_object_metadata_lock!(bucket, key, fn ->
            object = object_or_raise!(bucket, key, version_id)
            :ok = reject_locked_object_change!(conn, object, attrs)
            :ok = commit_object_lock!(bucket, key, object.version_id, attrs)
            object
          end)

        Log.info("put object retention",
          action: :put_object_retention,
          bucket: bucket,
          key: key,
          version_id: object.version_id
        )

        send_resp(conn, 200, "")

      {:error, :malformed_xml} ->
        raise Error.new(:malformed_xml, resource: object_resource(bucket, key))
    end
  end

  @spec get_retention(Plug.Conn.t()) :: Plug.Conn.t()
  def get_retention(conn) do
    {conn, bucket, key, version_id} = object_request!(conn)
    _bucket_meta = ensure_bucket!(bucket)
    object = object_or_raise!(bucket, key, version_id)

    conn
    |> maybe_put_version_id(object.version_id)
    |> put_resp_content_type("application/xml")
    |> send_resp(200, View.render_retention(object))
  end

  @spec put_legal_hold(Plug.Conn.t()) :: Plug.Conn.t()
  def put_legal_hold(conn) do
    {conn, bucket, key, version_id} = object_request!(conn)
    :ok = require_bucket_object_lock_enabled!(ensure_bucket!(bucket))
    :ok = reject_streaming_body!(conn)
    :ok = reject_checksum_trailers!(conn)
    {conn, xml} = read_small_body!(conn)
    :ok = validate_optional_checksums!(conn, xml)

    case Parser.parse_legal_hold(xml) do
      {:ok, attrs} ->
        object =
          with_object_metadata_lock!(bucket, key, fn ->
            object = object_or_raise!(bucket, key, version_id)
            :ok = commit_object_lock!(bucket, key, object.version_id, attrs)
            object
          end)

        Log.info("put object legal hold",
          action: :put_object_legal_hold,
          bucket: bucket,
          key: key,
          version_id: object.version_id
        )

        send_resp(conn, 200, "")

      {:error, :malformed_xml} ->
        raise Error.new(:malformed_xml, resource: object_resource(bucket, key))
    end
  end

  @spec get_legal_hold(Plug.Conn.t()) :: Plug.Conn.t()
  def get_legal_hold(conn) do
    {conn, bucket, key, version_id} = object_request!(conn)
    _bucket_meta = ensure_bucket!(bucket)
    object = object_or_raise!(bucket, key, version_id)

    conn
    |> maybe_put_version_id(object.version_id)
    |> put_resp_content_type("application/xml")
    |> send_resp(200, View.render_legal_hold(object))
  end

  defp ensure_bucket!(bucket) do
    case Buckets.lookup(bucket) do
      {:ok, bucket} -> bucket
      {:error, :not_found} -> raise Error.new(:no_such_bucket, resource: "/" <> bucket)
    end
  end

  defp require_bucket_object_lock_enabled!(%{name: bucket, versioning: "Enabled"}) do
    case ObjectLock.get_config(bucket) do
      {:ok, %{"ObjectLockEnabled" => "Enabled"}} ->
        :ok

      :none ->
        raise Error.new(:invalid_bucket_state,
                message:
                  "Object Lock configuration can only be changed for buckets created with Object Lock enabled",
                resource: "/" <> bucket
              )
    end
  end

  defp require_bucket_object_lock_enabled!(%{name: bucket}) do
    raise Error.new(:invalid_bucket_state,
            message: "Object Lock configuration requires bucket versioning to be enabled",
            resource: "/" <> bucket
          )
  end

  defp verify_expected_bucket_owner!(conn, bucket) do
    case get_req_header(conn, "x-amz-expected-bucket-owner") do
      [] ->
        :ok

      [owner] ->
        if owner == account_id() do
          :ok
        else
          raise Error.new(:access_denied, resource: "/" <> bucket)
        end

      _multiple ->
        raise Error.new(:access_denied, resource: "/" <> bucket)
    end
  end

  defp account_id do
    :maxio
    |> Application.get_env(:sts, [])
    |> Keyword.get(:account_id, @local_account_id)
    |> to_string()
  end

  defp read_small_body!(conn) do
    case read_body(conn, length: @limit, read_length: @limit) do
      {:ok, body, conn} ->
        {conn, body}

      {:more, _partial, _conn} ->
        raise Error.new(:malformed_xml, message: "ObjectLockConfiguration exceeds 128KB")

      {:error, _reason} ->
        raise Error.new(:malformed_xml)
    end
  end

  defp object_request!(conn) do
    bucket = conn.assigns.s3_bucket
    key = conn.assigns.s3_key
    conn = fetch_query_params(conn)

    :ok = validate_object_key!(bucket, key)

    version_id =
      conn.query_params
      |> Map.get("versionId")
      |> Maxio.Versioning.VersionId.normalize_param()

    :ok = validate_version_id!(bucket, key, version_id)
    {conn, bucket, key, version_id}
  end

  defp validate_object_key!(bucket, key) do
    case Maxio.Cluster.Paths.validate_key(key) do
      :ok ->
        :ok

      {:error, :invalid_key} ->
        raise Error.new(:invalid_object_name, resource: object_resource(bucket, key))

      {:error, :key_too_long} ->
        raise Error.new(:key_too_long, resource: object_resource(bucket, key))
    end
  end

  defp validate_version_id!(_bucket, _key, nil), do: :ok

  defp validate_version_id!(bucket, key, version_id) do
    if Maxio.Versioning.VersionId.valid?(version_id) do
      :ok
    else
      raise Error.new(:invalid_argument,
              message: "Invalid versionId specified",
              resource: object_resource(bucket, key)
            )
    end
  end

  defp object_or_raise!(bucket, key, version_id) do
    case Objects.get_version(bucket, key, version_id || current_version_id!(bucket, key)) do
      {:ok, %{is_delete_marker: true}} ->
        raise Error.new(:no_such_key, resource: object_resource(bucket, key))

      {:ok, object} ->
        object

      {:error, :not_found} when is_binary(version_id) ->
        raise Error.new(:no_such_version, resource: object_resource(bucket, key))

      {:error, :not_found} ->
        raise Error.new(:no_such_key, resource: object_resource(bucket, key))
    end
  end

  defp current_version_id!(bucket, key) do
    case Objects.get_metadata(bucket, key) do
      {:ok, object} -> object.version_id
      {:error, :not_found} -> nil
    end
  end

  defp reject_locked_object_change!(conn, object, _attrs) do
    if ObjectLock.locked?(object,
         now: now(conn),
         bypass_governance?: retention_change_bypass_authorized?(conn, object)
       ) do
      raise Error.new(:access_denied, resource: object_resource(object.bucket_name, object.key))
    end

    :ok
  end

  defp with_object_metadata_lock!(bucket, key, fun) when is_function(fun, 0) do
    case Maxio.Lock.with_object_lock({bucket, key}, fun) do
      {:ok, result} ->
        result

      {:error, :locked} ->
        raise Error.new(:request_timeout, resource: object_resource(bucket, key))
    end
  end

  defp retention_change_bypass_authorized?(conn, object) do
    bypass_governance_header?(conn) and
      bypass_governance_authorized?(conn, object.bucket_name, object.key)
  end

  defp bypass_governance_authorized?(conn, bucket, key) do
    principal = conn.assigns[:principal]
    authenticated? = principal != :anonymous
    conditions = Maxio.S3.Authz.conditions_for(conn, authenticated?)
    resource = Arn.object_arn(bucket, key)
    action = "s3:BypassGovernanceRetention"

    cond do
      Maxio.S3.Authz.owner?(principal, bucket) ->
        Maxio.S3.Authz.session_policy_allows?(principal, action, resource, conditions)

      true ->
        statements = Maxio.S3.Authz.object_statements(bucket, key, principal)

        ctx = %RequestContext{
          principal: principal,
          authenticated?: authenticated?,
          owner?: false,
          action: action,
          resource: resource,
          conditions: conditions
        }

        Evaluator.evaluate(ctx, statements) == :allow and
          Maxio.S3.Authz.session_policy_allows?(principal, action, resource, conditions)
    end
  end

  defp commit_object_lock!(bucket, key, version_id, attrs) do
    case ObjectMeta.authoritative_source(:write) do
      :sidecar -> commit_object_lock_sidecar!(bucket, key, version_id, attrs)
      _pg -> commit_object_lock_pg!(bucket, key, version_id, attrs)
    end
  end

  defp commit_object_lock_sidecar!(bucket, key, version_id, attrs) do
    case ObjectLockSidecar.update(bucket, key, version_id, attrs) do
      {:ok, generation} ->
        best_effort_object_lock_index_update(bucket, key, version_id, attrs, generation)

      {:error, :not_found} ->
        raise Error.new(:no_such_key, resource: object_resource(bucket, key))

      {:error, :read_quorum} ->
        raise Error.new(:slow_down_read, resource: object_resource(bucket, key))

      {:error, reason} when reason in [:write_quorum, :no_topology] ->
        raise Error.new(:slow_down_write, resource: object_resource(bucket, key))

      {:error, :invalid_key} ->
        raise Error.new(:invalid_object_name, resource: object_resource(bucket, key))
    end
  end

  defp commit_object_lock_pg!(bucket, key, version_id, attrs) do
    case Objects.put_object_lock(bucket, key, version_id, attrs) do
      {:ok, _object} ->
        mirror_object_lock_sidecar(bucket, key, version_id, attrs)
        :ok

      {:error, :not_found} ->
        raise Error.new(:no_such_key, resource: object_resource(bucket, key))
    end
  end

  defp best_effort_object_lock_index_update(bucket, key, version_id, attrs, generation) do
    case Objects.put_object_lock(bucket, key, version_id, attrs, generation) do
      {:ok, _object} ->
        :ok

      {:error, reason} ->
        Log.error("pg index object lock update failed (object lock durably stored in sidecar)",
          action: :put_object_lock_metadata,
          bucket: bucket,
          key: key,
          reason: inspect(reason)
        )

        :ok
    end
  end

  defp mirror_object_lock_sidecar(bucket, key, version_id, attrs) do
    try do
      case ObjectLockSidecar.update(bucket, key, version_id, attrs) do
        {:ok, generation} ->
          case Objects.put_object_lock(bucket, key, version_id, attrs, generation) do
            {:ok, _object} ->
              :ok

            {:error, reason} ->
              Log.warn("pg object lock generation sync failed after sidecar mirror",
                action: :put_object_lock_metadata,
                bucket: bucket,
                key: key,
                reason: inspect(reason)
              )
          end

        {:error, reason} ->
          Log.warn("sidecar object lock mirror failed (PG remains authoritative)",
            action: :put_object_lock_metadata,
            bucket: bucket,
            key: key,
            reason: inspect(reason)
          )
      end
    rescue
      e ->
        Log.warn("sidecar object lock mirror raised (PG remains authoritative)",
          action: :put_object_lock_metadata,
          bucket: bucket,
          key: key,
          reason: inspect(e)
        )
    catch
      kind, reason ->
        Log.warn("sidecar object lock mirror caught (PG remains authoritative)",
          action: :put_object_lock_metadata,
          bucket: bucket,
          key: key,
          reason: inspect({kind, reason})
        )
    end
  end

  defp reject_streaming_body!(conn) do
    if conn.assigns[:payload_mode] == :streaming do
      raise Error.new(:not_implemented,
              message: "Bucket Object Lock aws-chunked XML bodies are not implemented",
              resource: "/" <> conn.assigns.s3_bucket
            )
    end

    :ok
  end

  defp reject_checksum_trailers!(conn) do
    case get_req_header(conn, "x-amz-trailer") do
      [] ->
        :ok

      _trailers ->
        raise Error.new(:not_implemented,
                message: "Bucket Object Lock checksum trailers are not implemented",
                resource: "/" <> conn.assigns.s3_bucket
              )
    end
  end

  defp validate_checksums!(conn, body) do
    case get_req_header(conn, "content-md5") do
      [_value] ->
        checksum = Checksum.from_conn!(conn)
        {stream, get_context, _discard_context} = Checksum.wrap_stream([body], checksum)
        _ = Enum.to_list(stream)
        checksum = get_context.()
        checksum.verify!.()

      [] ->
        raise Error.new(:missing_security_header,
                message: "Missing required Content-MD5 header",
                resource: "/" <> conn.assigns.s3_bucket
              )

      _multiple ->
        raise Error.new(:bad_digest, resource: "/" <> conn.assigns.s3_bucket)
    end
  end

  defp validate_optional_checksums!(conn, body) do
    checksum = Checksum.from_conn!(conn)
    {stream, get_context, _discard_context} = Checksum.wrap_stream([body], checksum)
    _ = Enum.to_list(stream)
    checksum = get_context.()
    checksum.verify!.()
  end

  defp bypass_governance_header?(conn) do
    case get_req_header(conn, "x-amz-bypass-governance-retention") do
      [value] -> value |> String.trim() |> String.downcase() == "true"
      _other -> false
    end
  end

  defp maybe_put_version_id(conn, "null"), do: conn

  defp maybe_put_version_id(conn, version_id) when is_binary(version_id),
    do: put_resp_header(conn, "x-amz-version-id", version_id)

  defp now(conn), do: conn.private[:maxio_now] || DateTime.utc_now()

  defp object_resource(bucket, key), do: "/#{bucket}/#{key}"
end
