defmodule Maxio.S3.Handlers.Bucket do
  @moduledoc "Bucket 级 handler：create / delete / head / list_objects_v2 / get_location。"
  import Plug.Conn
  alias Maxio.{Buckets, Objects, Storage}
  alias Maxio.S3.{Error, Log}
  alias Maxio.S3.Views.{ListBucket, LocationConstraint, ListVersions}

  @spec create(Plug.Conn.t()) :: Plug.Conn.t()
  def create(conn) do
    bucket = conn.assigns.s3_bucket
    owner = conn.assigns.principal.arn
    acl = bucket_canned(conn |> get_req_header("x-amz-acl") |> List.first())

    case Buckets.create(bucket, owner, region: region(), acl_canned: acl) do
      {:ok, _b} ->
        :ok = Storage.put_bucket(bucket)
        Log.info("create bucket", action: :create_bucket, bucket: bucket)

        conn
        |> put_resp_header("location", "/" <> bucket)
        |> send_resp(200, "")

      {:error, :invalid_bucket_name} ->
        raise Error.new(:invalid_bucket_name, resource: "/" <> bucket)

      {:error, :already_owned} ->
        raise Error.new(:bucket_already_owned_by_you, resource: "/" <> bucket)
    end
  end

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
        conn
        |> put_resp_header("x-amz-bucket-region", b.region)
        |> send_resp(200, "")

      {:error, :not_found} ->
        # HeadBucket 不带 XML body，仅状态码
        send_resp(conn, 404, "")
    end
  end

  @spec list_objects_v2(Plug.Conn.t()) :: Plug.Conn.t()
  def list_objects_v2(conn) do
    bucket = conn.assigns.s3_bucket
    conn = fetch_query_params(conn)
    qp = conn.query_params

    with {:ok, _b} <- bucket_or_raise(bucket) do
      prefix = Map.get(qp, "prefix", "")
      delimiter = Map.get(qp, "delimiter")
      max_keys = parse_int(Map.get(qp, "max-keys"), 1000)
      continuation = Map.get(qp, "continuation-token")
      start_after = Map.get(qp, "start-after")
      encoding_type = Map.get(qp, "encoding-type")

      res =
        Objects.list_objects_v2(bucket, %{
          prefix: prefix,
          delimiter: delimiter,
          max_keys: max_keys,
          continuation_token: continuation,
          start_after: start_after
        })

      objects =
        Enum.map(res.objects, fn o ->
          %{key: o.key, last_modified: o.updated_at, etag: o.etag, size: o.size}
        end)

      body =
        ListBucket.render(%{
          name: bucket,
          prefix: prefix,
          delimiter: delimiter,
          max_keys: max_keys,
          key_count: res.key_count,
          is_truncated: res.is_truncated,
          next_continuation_token: res.next_continuation_token,
          start_after: start_after,
          objects: objects,
          common_prefixes: res.common_prefixes,
          encoding_type: encoding_type
        })

      Log.info("list objects v2", action: :list_objects_v2, bucket: bucket)

      conn
      |> put_resp_content_type("application/xml")
      |> send_resp(200, body)
    end
  end

  @spec list_object_versions(Plug.Conn.t()) :: Plug.Conn.t()
  def list_object_versions(conn) do
    bucket = conn.assigns.s3_bucket
    conn = fetch_query_params(conn)
    qp = conn.query_params

    with {:ok, _b} <- bucket_or_raise(bucket) do
      prefix = Map.get(qp, "prefix", "")
      delimiter = Map.get(qp, "delimiter")
      max_keys = parse_int(Map.get(qp, "max-keys"), 1000)
      key_marker = Map.get(qp, "key-marker")
      version_id_marker = Map.get(qp, "version-id-marker")
      encoding_type = Map.get(qp, "encoding-type")

      res =
        Objects.list_object_versions(bucket, %{
          prefix: prefix,
          delimiter: delimiter,
          max_keys: max_keys,
          key_marker: key_marker,
          version_id_marker: version_id_marker
        })

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
          encoding_type: encoding_type
        })

      Log.info("list object versions", action: :list_object_versions, bucket: bucket)

      conn
      |> put_resp_content_type("application/xml")
      |> send_resp(200, body)
    end
  end

  @spec get_location(Plug.Conn.t()) :: Plug.Conn.t()
  def get_location(conn) do
    bucket = conn.assigns.s3_bucket

    with {:ok, b} <- bucket_or_raise(bucket) do
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

  defp parse_int(nil, default), do: default

  defp parse_int(str, default) do
    case Integer.parse(str) do
      {n, ""} when n > 0 -> n
      _ -> default
    end
  end

  defp region, do: Application.fetch_env!(:maxio, :s3) |> Keyword.fetch!(:region)

  # CreateBucket 的 x-amz-acl：对象专属 canned（bucket-owner-*）在桶级被静默忽略（官方），落 private。
  defp bucket_canned(nil), do: "private"
  defp bucket_canned(c) when c in ~w(bucket-owner-read bucket-owner-full-control), do: "private"
  defp bucket_canned(c), do: c
end
