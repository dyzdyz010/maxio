defmodule Maxio.S3.Handlers.ObjectLock do
  @moduledoc """
  ?object-lock handler for Bucket Object Lock configuration APIs.

  Bucket configuration controls default retention. Object retention and legal
  hold APIs write per-version metadata used by object write/delete enforcement.
  """
  import Plug.Conn

  alias Maxio.{Buckets, ObjectLockMetadata, Objects}
  alias Maxio.S3.{Authz, ControlBody, Error, ExpectedBucketOwner, Log, ObjectLock, RequestPayer}
  alias Maxio.S3.RequestParsers.ObjectLock, as: Parser
  alias Maxio.S3.Views.ObjectLock, as: View

  @limit 131_072

  @spec put(Plug.Conn.t()) :: Plug.Conn.t()
  def put(conn) do
    bucket = conn.assigns.s3_bucket
    bucket_meta = ensure_bucket!(bucket)
    :ok = ExpectedBucketOwner.verify!(conn, bucket)
    :ok = require_bucket_object_lock_enabled!(bucket_meta)
    {conn, xml} = read_config_body!(conn)

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
    :ok = ExpectedBucketOwner.verify!(conn, bucket)

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
    bucket_meta = ensure_bucket!(bucket)
    :ok = ExpectedBucketOwner.verify!(conn, bucket, resource: object_resource(bucket, key))
    charge = RequestPayer.require!(conn, bucket, resource: object_resource(bucket, key))
    :ok = require_bucket_object_lock_enabled!(bucket_meta)
    {conn, xml} = read_optional_checksum_body!(conn)

    case Parser.parse_retention(xml) do
      {:ok, attrs} ->
        object =
          case ObjectLockMetadata.put_retention(bucket, key, version_id, attrs,
                 now: now(conn),
                 bypass_governance?: retention_change_bypass_authorized?(conn, bucket, key)
               ) do
            {:ok, object} ->
              object

            {:error, reason} ->
              raise_object_lock_mutation_error!(reason, bucket, key)
          end

        Log.info("put object retention",
          action: :put_object_retention,
          bucket: bucket,
          key: key,
          version_id: object.version_id
        )

        conn
        |> RequestPayer.put_charged_header(charge)
        |> send_resp(200, "")

      {:error, :malformed_xml} ->
        raise Error.new(:malformed_xml, resource: object_resource(bucket, key))
    end
  end

  @spec get_retention(Plug.Conn.t()) :: Plug.Conn.t()
  def get_retention(conn) do
    {conn, bucket, key, version_id} = object_request!(conn)
    _bucket_meta = ensure_bucket!(bucket)
    :ok = ExpectedBucketOwner.verify!(conn, bucket, resource: object_resource(bucket, key))
    charge = RequestPayer.require!(conn, bucket, resource: object_resource(bucket, key))
    object = object_or_raise!(bucket, key, version_id)

    conn
    |> maybe_put_version_id(object.version_id)
    |> put_resp_content_type("application/xml")
    |> RequestPayer.put_charged_header(charge)
    |> send_resp(200, View.render_retention(object))
  end

  @spec put_legal_hold(Plug.Conn.t()) :: Plug.Conn.t()
  def put_legal_hold(conn) do
    {conn, bucket, key, version_id} = object_request!(conn)
    bucket_meta = ensure_bucket!(bucket)
    :ok = ExpectedBucketOwner.verify!(conn, bucket, resource: object_resource(bucket, key))
    charge = RequestPayer.require!(conn, bucket, resource: object_resource(bucket, key))
    :ok = require_bucket_object_lock_enabled!(bucket_meta)
    {conn, xml} = read_optional_checksum_body!(conn)

    case Parser.parse_legal_hold(xml) do
      {:ok, attrs} ->
        object =
          case ObjectLockMetadata.put_legal_hold(bucket, key, version_id, attrs) do
            {:ok, object} ->
              object

            {:error, reason} ->
              raise_object_lock_mutation_error!(reason, bucket, key)
          end

        Log.info("put object legal hold",
          action: :put_object_legal_hold,
          bucket: bucket,
          key: key,
          version_id: object.version_id
        )

        conn
        |> RequestPayer.put_charged_header(charge)
        |> send_resp(200, "")

      {:error, :malformed_xml} ->
        raise Error.new(:malformed_xml, resource: object_resource(bucket, key))
    end
  end

  @spec get_legal_hold(Plug.Conn.t()) :: Plug.Conn.t()
  def get_legal_hold(conn) do
    {conn, bucket, key, version_id} = object_request!(conn)
    _bucket_meta = ensure_bucket!(bucket)
    :ok = ExpectedBucketOwner.verify!(conn, bucket, resource: object_resource(bucket, key))
    charge = RequestPayer.require!(conn, bucket, resource: object_resource(bucket, key))
    object = object_or_raise!(bucket, key, version_id)

    conn
    |> maybe_put_version_id(object.version_id)
    |> put_resp_content_type("application/xml")
    |> RequestPayer.put_charged_header(charge)
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

  defp read_config_body!(conn) do
    ControlBody.read_and_verify!(
      conn,
      @limit,
      "ObjectLockConfiguration exceeds 128KB",
      require_integrity: :content_md5_or_flexible
    )
  end

  defp read_optional_checksum_body!(conn),
    do: ControlBody.read_and_verify!(conn, @limit, "ObjectLockConfiguration exceeds 128KB")

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

  defp retention_change_bypass_authorized?(conn, bucket, key) do
    bypass_governance_header?(conn) and
      bypass_governance_authorized?(conn, bucket, key)
  end

  defp bypass_governance_authorized?(conn, bucket, key) do
    principal = conn.assigns[:principal]
    authenticated? = principal != :anonymous
    conditions = Authz.conditions_for(conn, authenticated?)
    action = "s3:BypassGovernanceRetention"

    Authz.object_action_allowed?(
      bucket,
      key,
      action,
      principal,
      authenticated?,
      Authz.owner?(principal, bucket),
      conditions
    )
  end

  defp raise_object_lock_mutation_error!(reason, bucket, key) do
    case reason do
      :no_such_version ->
        raise Error.new(:no_such_version, resource: object_resource(bucket, key))

      :not_found ->
        raise Error.new(:no_such_key, resource: object_resource(bucket, key))

      :locked ->
        raise Error.new(:access_denied, resource: object_resource(bucket, key))

      :lock_timeout ->
        raise Error.new(:request_timeout, resource: object_resource(bucket, key))

      :slow_down_read ->
        raise Error.new(:slow_down_read, resource: object_resource(bucket, key))

      :slow_down_write ->
        raise Error.new(:slow_down_write, resource: object_resource(bucket, key))

      :invalid_key ->
        raise Error.new(:invalid_object_name, resource: object_resource(bucket, key))
    end
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
