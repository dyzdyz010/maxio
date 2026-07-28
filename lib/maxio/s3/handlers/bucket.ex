defmodule Maxio.S3.Handlers.Bucket do
  @moduledoc "Bucket 级 handler：create / delete / head / list_objects_v2 / get_location。"
  import Plug.Conn
  alias Maxio.{BucketConfigs, Buckets, Storage}
  alias Maxio.Policy.ACL
  alias Maxio.S3.{Error, ExpectedBucketOwner, Log, ObjectLock, OwnershipControls, RequestPayer}
  alias Maxio.S3.Views.{ListBucket, ListBucketV1, LocationConstraint, ListVersions}

  @max_keys_limit 1000
  @owner_id "maxio"

  @spec create(Plug.Conn.t()) :: Plug.Conn.t()
  def create(conn) do
    bucket = conn.assigns.s3_bucket
    owner = conn.assigns.principal.arn
    ownership_config = object_ownership_from_headers!(conn)
    acl_input = bucket_acl_from_headers!(conn)
    object_lock_enabled? = object_lock_enabled_from_headers!(conn)
    :ok = OwnershipControls.reject_acl_input_for_enforced!(bucket, ownership_config, acl_input)

    case Buckets.create(bucket, owner,
           region: region(),
           acl_canned: acl_input.canned,
           acl_grants: acl_input.grants_doc
         ) do
      {:ok, _b} ->
        :ok = BucketConfigs.put(bucket, :ownership_controls, ownership_config)
        :ok = maybe_enable_object_lock(bucket, object_lock_enabled?)
        :ok = Storage.put_bucket(bucket)

        Log.info("create bucket",
          action: :create_bucket,
          bucket: bucket,
          object_ownership: ownership_config["ObjectOwnership"],
          object_lock_enabled?: object_lock_enabled?
        )

        conn
        |> put_resp_header("location", "/" <> bucket)
        |> send_resp(200, "")

      {:error, :invalid_bucket_name} ->
        raise Error.new(:invalid_bucket_name, resource: "/" <> bucket)

      {:error, :already_owned} ->
        raise Error.new(:bucket_already_owned_by_you, resource: "/" <> bucket)
    end
  end

  defp object_lock_enabled_from_headers!(conn) do
    case get_req_header(conn, "x-amz-bucket-object-lock-enabled") do
      [] ->
        false

      [value] ->
        case String.downcase(String.trim(value)) do
          "true" ->
            true

          "false" ->
            false

          _other ->
            raise Error.new(:invalid_argument,
                    message: "Invalid x-amz-bucket-object-lock-enabled"
                  )
        end

      _multiple ->
        raise Error.new(:invalid_argument, message: "Invalid x-amz-bucket-object-lock-enabled")
    end
  end

  defp maybe_enable_object_lock(bucket, true), do: ObjectLock.enable_bucket!(bucket)

  defp maybe_enable_object_lock(_bucket, false), do: :ok

  @spec delete(Plug.Conn.t()) :: Plug.Conn.t()
  def delete(conn) do
    bucket = conn.assigns.s3_bucket

    case Buckets.delete(bucket) do
      :ok ->
        _ = Storage.delete_bucket(bucket)
        Log.info("delete bucket", action: :delete_bucket, bucket: bucket)
        send_resp(conn, 204, "")

      {:error, :not_found} ->
        raise Error.new(:no_such_bucket, resource: "/" <> bucket)

      {:error, :not_empty} ->
        raise Error.new(:bucket_not_empty, resource: "/" <> bucket)
    end
  end

  @spec head(Plug.Conn.t()) :: Plug.Conn.t()
  def head(conn) do
    bucket = conn.assigns.s3_bucket

    case Buckets.lookup(bucket) do
      {:ok, b} ->
        :ok = ExpectedBucketOwner.verify!(conn, bucket)

        conn
        |> put_resp_header("x-amz-bucket-region", b.region)
        |> send_resp(200, "")

      {:error, :not_found} ->
        # HeadBucket 不带 XML body，仅状态码
        send_resp(conn, 404, "")
    end
  end

  @spec list_objects(Plug.Conn.t()) :: Plug.Conn.t()
  def list_objects(conn) do
    bucket = conn.assigns.s3_bucket
    conn = fetch_query_params(conn)
    qp = conn.query_params

    with {:ok, b} <- bucket_or_raise(bucket) do
      :ok = ExpectedBucketOwner.verify!(conn, bucket)
      charge = RequestPayer.require!(conn, bucket, resource: "/" <> bucket)
      prefix = Map.get(qp, "prefix", "")
      delimiter = Map.get(qp, "delimiter")
      marker = Map.get(qp, "marker")
      max_keys = parse_int(Map.get(qp, "max-keys"), @max_keys_limit, @max_keys_limit)
      encoding_type = Map.get(qp, "encoding-type")
      optional_attributes = optional_object_attributes!(conn)

      list_opts = %{
        prefix: prefix,
        delimiter: delimiter,
        max_keys: max_keys,
        continuation_token: nil,
        start_after: list_v1_marker_cursor(marker, delimiter)
      }

      res = Maxio.ObjectMeta.list(bucket, list_opts, bucket_versioning: versioning_of(b))
      objects = list_object_entries(res.objects)

      body =
        ListBucketV1.render(%{
          name: bucket,
          prefix: prefix,
          marker: marker,
          delimiter: delimiter,
          max_keys: max_keys,
          is_truncated: res.is_truncated,
          next_marker: next_marker(res, delimiter),
          objects: objects,
          common_prefixes: res.common_prefixes,
          encoding_type: encoding_type,
          include_restore_status?: restore_status_requested?(optional_attributes)
        })

      Log.info("list objects", action: :list_objects, bucket: bucket)

      conn
      |> put_resp_content_type("application/xml")
      |> RequestPayer.put_charged_header(charge)
      |> send_resp(200, body)
    end
  end

  @spec list_objects_v2(Plug.Conn.t()) :: Plug.Conn.t()
  def list_objects_v2(conn) do
    bucket = conn.assigns.s3_bucket
    conn = fetch_query_params(conn)
    qp = conn.query_params

    with {:ok, b} <- bucket_or_raise(bucket) do
      :ok = ExpectedBucketOwner.verify!(conn, bucket)
      charge = RequestPayer.require!(conn, bucket, resource: "/" <> bucket)
      prefix = Map.get(qp, "prefix", "")
      delimiter = Map.get(qp, "delimiter")
      max_keys = parse_int(Map.get(qp, "max-keys"), @max_keys_limit, @max_keys_limit)
      continuation = Map.get(qp, "continuation-token")
      start_after = Map.get(qp, "start-after")
      encoding_type = Map.get(qp, "encoding-type")
      optional_attributes = optional_object_attributes!(conn)

      list_opts = %{
        prefix: prefix,
        delimiter: delimiter,
        max_keys: max_keys,
        continuation_token: continuation,
        start_after: start_after
      }

      res = Maxio.ObjectMeta.list(bucket, list_opts, bucket_versioning: versioning_of(b))

      # ROUTE B B4-4：ListObjectsV2 经元数据门面分流（默认 :pg → SQL 权威 + drive-walk shadow 比对；
      # :list=:sidecar → drive-walk + quorum 确认权威返回）。透传桶 versioning：:pg 分支 shadow 门控到
      # Unversioned 桶（见 Maxio.ObjectMeta.list_shadow），避免 versioned/suspended 桶上纯 PG delete
      # marker 在盘无痕迹导致的保证性伪分歧。默认 :pg 行为与 P3 完全一致（向后兼容、可回滚）。

      # objects 元素：:pg 分支为 %Objects.Object{}（富元数据）；:sidecar 分支为 %{key: ...}
      # （B6-2 后同样富集 LastModified/ETag/Size/StorageClass）。统一用 Map.get 取，缺失留 nil。
      objects = list_object_entries(res.objects)

      body =
        ListBucket.render(%{
          name: bucket,
          prefix: prefix,
          delimiter: delimiter,
          max_keys: max_keys,
          key_count: res.key_count,
          is_truncated: res.is_truncated,
          continuation_token: continuation,
          next_continuation_token: res.next_continuation_token,
          start_after: start_after,
          objects: objects,
          common_prefixes: res.common_prefixes,
          encoding_type: encoding_type,
          include_restore_status?: restore_status_requested?(optional_attributes)
        })

      Log.info("list objects v2", action: :list_objects_v2, bucket: bucket)

      conn
      |> put_resp_content_type("application/xml")
      |> RequestPayer.put_charged_header(charge)
      |> send_resp(200, body)
    end
  end

  @spec list_object_versions(Plug.Conn.t()) :: Plug.Conn.t()
  def list_object_versions(conn) do
    bucket = conn.assigns.s3_bucket
    conn = fetch_query_params(conn)
    qp = conn.query_params

    with {:ok, b} <- bucket_or_raise(bucket) do
      :ok = ExpectedBucketOwner.verify!(conn, bucket)
      charge = RequestPayer.require!(conn, bucket, resource: "/" <> bucket)
      prefix = Map.get(qp, "prefix", "")
      delimiter = Map.get(qp, "delimiter")
      max_keys = parse_int(Map.get(qp, "max-keys"), @max_keys_limit, @max_keys_limit)
      key_marker = Map.get(qp, "key-marker")
      version_id_marker = Map.get(qp, "version-id-marker")
      encoding_type = Map.get(qp, "encoding-type")
      optional_attributes = optional_object_attributes!(conn)

      res =
        Maxio.ObjectMeta.list_versions(
          bucket,
          %{
            prefix: prefix,
            delimiter: delimiter,
            max_keys: max_keys,
            key_marker: key_marker,
            version_id_marker: version_id_marker
          },
          bucket_versioning: versioning_of(b)
        )

      body =
        ListVersions.render(%{
          name: bucket,
          prefix: prefix,
          delimiter: delimiter,
          key_marker: key_marker,
          version_id_marker: version_id_marker,
          max_keys: max_keys,
          is_truncated: res.is_truncated,
          next_key_marker: res.next_key_marker,
          next_version_id_marker: res.next_version_id_marker,
          versions: res.versions,
          common_prefixes: res.common_prefixes,
          encoding_type: encoding_type,
          include_restore_status?: restore_status_requested?(optional_attributes)
        })

      Log.info("list object versions", action: :list_object_versions, bucket: bucket)

      conn
      |> put_resp_content_type("application/xml")
      |> RequestPayer.put_charged_header(charge)
      |> send_resp(200, body)
    end
  end

  @spec get_location(Plug.Conn.t()) :: Plug.Conn.t()
  def get_location(conn) do
    bucket = conn.assigns.s3_bucket

    with {:ok, b} <- bucket_or_raise(bucket) do
      :ok = ExpectedBucketOwner.verify!(conn, bucket)
      body = LocationConstraint.render(b.region)

      conn
      |> put_resp_content_type("application/xml")
      |> send_resp(200, body)
    end
  end

  defp bucket_or_raise(bucket) do
    case Buckets.lookup(bucket) do
      {:ok, b} -> {:ok, b}
      {:error, :not_found} -> raise Error.new(:no_such_bucket, resource: "/" <> bucket)
    end
  end

  # 桶 versioning 状态（Unversioned|Enabled|Suspended）；缺省 "Unversioned"。
  defp versioning_of(%{versioning: v}) when is_binary(v), do: v
  defp versioning_of(_), do: "Unversioned"

  defp list_object_entries(objects) do
    Enum.map(objects, fn o ->
      %{
        key: o.key,
        last_modified: Map.get(o, :updated_at) || Map.get(o, :last_modified),
        etag: Map.get(o, :etag),
        size: Map.get(o, :size),
        storage_class: Map.get(o, :storage_class),
        restore_status: Map.get(o, :restore_status),
        restore_expiry: Map.get(o, :restore_expiry)
      }
    end)
  end

  defp optional_object_attributes!(conn) do
    query_value =
      conn.query_params
      |> Map.get("x-amz-optional-object-attributes")
      |> List.wrap()

    values =
      conn
      |> get_req_header("x-amz-optional-object-attributes")
      |> Kernel.++(query_value)
      |> Enum.flat_map(&String.split(&1, ","))
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    unsupported = Enum.reject(values, &(&1 == "RestoreStatus"))

    if unsupported != [] do
      raise Error.new(:invalid_argument,
              message:
                "Unsupported x-amz-optional-object-attributes: #{Enum.join(unsupported, ",")}"
            )
    end

    MapSet.new(values)
  end

  defp restore_status_requested?(optional_attributes),
    do: MapSet.member?(optional_attributes, "RestoreStatus")

  defp next_marker(%{is_truncated: true, next_continuation_token: token}, delimiter)
       when is_binary(delimiter) and delimiter != "",
       do: token

  defp next_marker(_res, _delimiter), do: nil

  defp list_v1_marker_cursor(nil, _delimiter), do: nil

  defp list_v1_marker_cursor(marker, delimiter)
       when is_binary(marker) and is_binary(delimiter) and delimiter != "" do
    if String.ends_with?(marker, delimiter) do
      lexicographic_successor(marker) || marker
    else
      marker
    end
  end

  defp list_v1_marker_cursor(marker, _delimiter), do: marker

  defp lexicographic_successor(binary) do
    binary
    |> :binary.bin_to_list()
    |> Enum.reverse()
    |> bump_reversed_bytes()
    |> case do
      nil ->
        nil

      bytes ->
        successor = :erlang.list_to_binary(bytes)
        if String.valid?(successor), do: successor, else: nil
    end
  end

  defp bump_reversed_bytes([]), do: nil
  defp bump_reversed_bytes([255 | rest]), do: bump_reversed_bytes(rest)
  defp bump_reversed_bytes([byte | rest]), do: Enum.reverse(rest, [byte + 1])

  defp parse_int(nil, default, _limit), do: default

  defp parse_int(str, default, limit) do
    case Integer.parse(str) do
      {n, ""} when n > 0 -> min(n, limit)
      _ -> default
    end
  end

  defp region, do: Application.fetch_env!(:maxio, :s3) |> Keyword.fetch!(:region)

  defp object_ownership_from_headers!(conn) do
    case conn |> get_req_header("x-amz-object-ownership") |> List.first() do
      nil ->
        %{"ObjectOwnership" => OwnershipControls.create_default()}

      value when value in ["BucketOwnerEnforced", "BucketOwnerPreferred", "ObjectWriter"] ->
        %{"ObjectOwnership" => value}

      value ->
        raise Error.new(:invalid_argument,
                message: "Unsupported x-amz-object-ownership: #{value}"
              )
    end
  end

  # CreateBucket 的对象专属 canned（bucket-owner-*）在桶级被官方忽略，落 private。
  defp bucket_acl_from_headers!(conn) do
    grant_headers? = ACL.grant_headers?(conn.req_headers)

    case conn |> get_req_header("x-amz-acl") |> List.first() do
      canned when is_binary(canned) and grant_headers? ->
        raise Error.new(:invalid_request,
                message: "Cannot specify both x-amz-acl and x-amz-grant-*"
              )

      nil ->
        if grant_headers? do
          grants =
            conn.req_headers
            |> parse_grant_headers!()
            |> ACL.drop_owner_grants(@owner_id)

          %{canned: ACL.classify_grants(grants), grants_doc: ACL.grants_doc(grants)}
        else
          %{canned: "private", grants_doc: ACL.empty_grants_doc()}
        end

      canned when canned in ~w(bucket-owner-read bucket-owner-full-control) ->
        %{canned: "private", grants_doc: ACL.empty_grants_doc()}

      canned ->
        if ACL.known?(canned) do
          %{canned: canned, grants_doc: ACL.empty_grants_doc()}
        else
          raise Error.new(:invalid_argument, message: "Unsupported x-amz-acl: #{canned}")
        end
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
end
