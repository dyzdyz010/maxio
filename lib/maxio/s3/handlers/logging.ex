defmodule Maxio.S3.Handlers.Logging do
  @moduledoc """
  ?logging handler for PutBucketLogging and GetBucketLogging.

  This stores and returns the S3 BucketLoggingStatus control-plane document.
  Server access log delivery is a separate data-plane feature.
  """
  import Plug.Conn

  alias Maxio.{Buckets, BucketConfigs}

  alias Maxio.S3.{
    ControlBody,
    Error,
    ExpectedBucketOwner,
    Log,
    Logging,
    ObjectLock,
    OwnershipControls
  }

  alias Maxio.S3.RequestPayment
  alias Maxio.S3.RequestParsers.Logging, as: Parser
  alias Maxio.S3.Views.Logging, as: View

  @limit 131_072
  @default_region "us-east-1"

  @spec put(Plug.Conn.t()) :: Plug.Conn.t()
  def put(conn) do
    bucket = conn.assigns.s3_bucket
    _ = ensure_bucket!(bucket)
    :ok = ExpectedBucketOwner.verify!(conn, bucket)
    {conn, xml} = read_xml_body!(conn)

    case Parser.parse(xml) do
      {:ok, %{"LoggingEnabled" => nil}} ->
        :ok = BucketConfigs.delete(bucket, :logging)

        Log.info("disable bucket logging", action: :put_bucket_logging, bucket: bucket)

        send_resp(conn, 200, "")

      {:ok, config} ->
        config = validate_config!(config, bucket)
        :ok = BucketConfigs.put(bucket, :logging, config)

        enabled = config["LoggingEnabled"]

        Log.info("put bucket logging",
          action: :put_bucket_logging,
          bucket: bucket,
          target_bucket: enabled["TargetBucket"],
          target_prefix: enabled["TargetPrefix"]
        )

        send_resp(conn, 200, "")

      {:error, :malformed_xml} ->
        raise Error.new(:malformed_xml, resource: "/" <> bucket)
    end
  end

  @spec get(Plug.Conn.t()) :: Plug.Conn.t()
  def get(conn) do
    bucket = conn.assigns.s3_bucket
    _ = ensure_bucket!(bucket)
    :ok = ExpectedBucketOwner.verify!(conn, bucket)
    {:ok, config} = Logging.get_config(bucket)

    conn
    |> put_resp_content_type("application/xml")
    |> send_resp(200, View.render(config))
  end

  defp validate_config!(config, source_bucket) do
    normalized =
      case Logging.validate_client_config(config) do
        {:ok, %{"LoggingEnabled" => enabled} = normalized} when is_map(enabled) ->
          normalized

        _other ->
          raise Error.new(:malformed_xml, resource: "/" <> source_bucket)
      end

    enabled = normalized["LoggingEnabled"]
    source = ensure_bucket!(source_bucket)
    target = target_bucket_or_raise!(enabled["TargetBucket"], source_bucket)

    :ok = reject_cross_region_target!(source, target)
    :ok = reject_requester_pays_target!(target, source_bucket)
    :ok = reject_object_lock_target!(target, source_bucket)
    :ok = reject_target_grants_for_enforced_target!(enabled, source_bucket)

    normalized
  end

  defp target_bucket_or_raise!(target_bucket, source_bucket) do
    case Buckets.lookup(target_bucket) do
      {:ok, bucket} ->
        bucket

      {:error, :not_found} ->
        raise Error.new(:invalid_target_bucket_for_logging, resource: "/" <> source_bucket)
    end
  end

  defp reject_cross_region_target!(source, target) do
    source_region = bucket_region(source)
    target_region = bucket_region(target)

    if source_region == target_region do
      :ok
    else
      raise Error.new(:invalid_target_bucket_for_logging,
              message: "Cross S3 location logging not allowed",
              resource: "/" <> source.name
            )
    end
  end

  defp reject_requester_pays_target!(target, source_bucket) do
    case RequestPayment.get_config(target.name) do
      {:ok, %{"Payer" => "Requester"}} ->
        raise Error.new(:invalid_target_bucket_for_logging,
                message: "The destination bucket must not have Requester Pays enabled.",
                resource: "/" <> source_bucket
              )

      {:ok, _config} ->
        :ok
    end
  end

  defp reject_object_lock_target!(target, source_bucket) do
    if ObjectLock.bucket_enabled?(target.name) do
      raise Error.new(:invalid_target_bucket_for_logging,
              message:
                "S3 buckets that have S3 Object Lock enabled can't be used as destination buckets for server access logs.",
              resource: "/" <> source_bucket
            )
    else
      :ok
    end
  end

  defp reject_target_grants_for_enforced_target!(
         %{"TargetBucket" => target_bucket, "TargetGrants" => grants},
         source_bucket
       )
       when is_list(grants) and grants != [] do
    if OwnershipControls.bucket_owner_enforced?(target_bucket) do
      raise Error.new(:invalid_target_bucket_for_logging, resource: "/" <> source_bucket)
    end

    :ok
  end

  defp reject_target_grants_for_enforced_target!(_enabled, _source_bucket), do: :ok

  defp bucket_region(%{region: region}) when is_binary(region) and region != "", do: region
  defp bucket_region(_bucket), do: @default_region

  defp ensure_bucket!(bucket) do
    case Buckets.lookup(bucket) do
      {:ok, bucket} -> bucket
      {:error, :not_found} -> raise Error.new(:no_such_bucket, resource: "/" <> bucket)
    end
  end

  defp read_xml_body!(conn) do
    ControlBody.read_and_verify!(conn, @limit, "BucketLoggingStatus exceeds 128KB",
      require_integrity: :content_md5_or_flexible
    )
  end
end
