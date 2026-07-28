defmodule Maxio.S3.Handlers.Versioning do
  @moduledoc """
  ?versioning 子资源 handler：PutBucketVersioning（XML body → 校验 → 存 buckets.versioning/mfa_delete，200）、
  GetBucketVersioning（200 + VersioningConfiguration XML，三态）。XML body 走带上限整读（铁律 4）。
  注：已 Enabled 的桶不能回退 Unversioned，只能 Suspended（与 AWS 一致）——本 handler 只接受 Enabled/Suspended。
  """
  import Plug.Conn
  alias Maxio.{BucketConfigs, Buckets}
  alias Maxio.S3.{ControlBody, Error, ExpectedBucketOwner, Log, MFADelete}
  alias Maxio.S3.RequestParsers.VersioningConfiguration, as: Parser
  alias Maxio.S3.Views.VersioningConfiguration, as: View

  @xml_limit 1_048_576

  @spec put(Plug.Conn.t()) :: Plug.Conn.t()
  def put(conn) do
    bucket = conn.assigns.s3_bucket
    bucket_meta = ensure_bucket!(bucket)
    :ok = ExpectedBucketOwner.verify!(conn, bucket)
    {conn, xml} = read_small_body!(conn)

    case Parser.parse(xml) do
      {:ok, %{status: status, mfa_delete: mfa}} ->
        MFADelete.require_for_versioning_put!(conn, bucket_meta, status, mfa)
        :ok = reject_object_lock_versioning_suspend!(bucket_meta, status)

        # status 缺省（空 body）→ 不改状态（保留现状）；显式 Enabled/Suspended → 落库。
        :ok = Buckets.put_versioning(bucket, status, mfa)

        Log.info("put bucket versioning",
          action: :put_bucket_versioning,
          bucket: bucket,
          reason: status
        )

        send_resp(conn, 200, "")

      {:error, :malformed_xml} ->
        raise Error.new(:malformed_xml, resource: "/" <> bucket)
    end
  end

  @spec get(Plug.Conn.t()) :: Plug.Conn.t()
  def get(conn) do
    bucket = conn.assigns.s3_bucket
    b = ensure_bucket!(bucket)
    :ok = ExpectedBucketOwner.verify!(conn, bucket)
    body = View.render(%{versioning: b.versioning, mfa_delete: b.mfa_delete})

    conn
    |> put_resp_content_type("application/xml")
    |> send_resp(200, body)
  end

  defp ensure_bucket!(bucket) do
    case Buckets.lookup(bucket) do
      {:ok, b} -> b
      {:error, :not_found} -> raise Error.new(:no_such_bucket, resource: "/" <> bucket)
    end
  end

  defp reject_object_lock_versioning_suspend!(%{name: bucket}, "Suspended") do
    case BucketConfigs.get(bucket, :object_lock) do
      {:ok, %{"ObjectLockEnabled" => "Enabled"}} ->
        raise Error.new(:invalid_bucket_state,
                message: "Versioning cannot be suspended on a bucket with Object Lock enabled",
                resource: "/" <> bucket
              )

      _other ->
        :ok
    end
  end

  defp reject_object_lock_versioning_suspend!(_bucket_meta, _status), do: :ok

  defp read_small_body!(conn) do
    ControlBody.read_and_verify!(conn, @xml_limit, "Versioning config too large",
      require_integrity: :content_md5,
      too_large_error: :entity_too_large
    )
  end
end
