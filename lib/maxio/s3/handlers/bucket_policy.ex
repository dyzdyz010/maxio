defmodule Maxio.S3.Handlers.BucketPolicy do
  @moduledoc """
  ?policy 子资源 handler：PutBucketPolicy（JSON body → 校验 → 存，204）、
  GetBucketPolicy（200 application/json 原样回放，无则 404 NoSuchBucketPolicy）、
  DeleteBucketPolicy（204，幂等）。JSON body 走带上限整读（铁律 4：小文档不进 Plug.Parsers）。
  """
  import Plug.Conn
  alias Maxio.Buckets
  alias Maxio.Policy.{Statement, Store}
  alias Maxio.S3.{Error, Log}

  @policy_limit 1_048_576

  @spec put(Plug.Conn.t()) :: Plug.Conn.t()
  def put(conn) do
    bucket = conn.assigns.s3_bucket
    _ = ensure_bucket!(bucket)
    {conn, json} = read_small_body!(conn)

    # 语义校验：JSON 合法 + 策略结构合法（Version/Effect/Action/Resource/Principal）。
    case Statement.parse_policy(json) do
      {:ok, _stmts} ->
        case Store.put_bucket_policy(bucket, json) do
          :ok ->
            Log.info("put bucket policy", action: :put_bucket_policy, bucket: bucket)
            send_resp(conn, 204, "")

          {:error, _} ->
            raise Error.new(:malformed_policy, resource: "/" <> bucket)
        end

      {:error, :malformed} ->
        Log.warn("malformed bucket policy",
          action: :put_bucket_policy,
          bucket: bucket,
          reason: :malformed_policy
        )

        raise Error.new(:malformed_policy, resource: "/" <> bucket)
    end
  end

  @spec get(Plug.Conn.t()) :: Plug.Conn.t()
  def get(conn) do
    bucket = conn.assigns.s3_bucket
    _ = ensure_bucket!(bucket)

    case Store.get_bucket_policy(bucket) do
      {:ok, json} ->
        Log.info("get bucket policy", action: :get_bucket_policy, bucket: bucket)

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, json)

      :none ->
        raise Error.new(:no_such_bucket_policy, resource: "/" <> bucket)
    end
  end

  @spec delete(Plug.Conn.t()) :: Plug.Conn.t()
  def delete(conn) do
    bucket = conn.assigns.s3_bucket
    _ = ensure_bucket!(bucket)
    :ok = Store.delete_bucket_policy(bucket)
    Log.info("delete bucket policy", action: :delete_bucket_policy, bucket: bucket)
    send_resp(conn, 204, "")
  end

  # ── helpers ──
  defp ensure_bucket!(bucket) do
    case Buckets.lookup(bucket) do
      {:ok, b} -> b
      {:error, :not_found} -> raise Error.new(:no_such_bucket, resource: "/" <> bucket)
    end
  end

  # 小 JSON 整读（带上限，铁律 4）。
  defp read_small_body!(conn) do
    case read_body(conn, length: @policy_limit, read_length: @policy_limit) do
      {:ok, body, conn} ->
        {conn, body}

      {:more, _partial, _conn} ->
        raise Error.new(:entity_too_large, message: "Policy document too large")

      {:error, _} ->
        raise Error.new(:malformed_policy)
    end
  end
end
