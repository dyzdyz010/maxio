defmodule Maxio.S3.Handlers.Cors do
  @moduledoc """
  ?cors 子资源 handler：PutBucketCors（XML → 校验 → 存，200）、GetBucketCors（200+XML，无→404
  NoSuchCORSConfiguration）、DeleteBucketCors（204）。校验：方法白名单 GET/PUT/POST/DELETE/HEAD、
  origin/header 至多一个*、每 rule 至少一个 method+origin、≤100 rule。违反 → MalformedXML 400。
  XML body 走带上限整读（铁律 4）。
  """
  import Plug.Conn
  alias Maxio.{Buckets, BucketConfigs}
  alias Maxio.S3.{Error, Log}
  alias Maxio.S3.RequestParsers.Cors, as: Parser
  alias Maxio.S3.Views.Cors, as: View

  @limit 65_536
  @valid_methods ~w(GET PUT POST DELETE HEAD)

  @spec put(Plug.Conn.t()) :: Plug.Conn.t()
  def put(conn) do
    bucket = conn.assigns.s3_bucket
    _ = ensure_bucket!(bucket)
    {conn, xml} = read_small_body!(conn)

    case Parser.parse(xml) do
      {:ok, rules} ->
        :ok = validate!(rules)
        :ok = BucketConfigs.put(bucket, :cors, rules)
        Log.info("put bucket cors", action: :put_bucket_cors, bucket: bucket)
        send_resp(conn, 200, "")

      {:error, :malformed_xml} ->
        raise Error.new(:malformed_xml, resource: "/" <> bucket)
    end
  end

  @spec get(Plug.Conn.t()) :: Plug.Conn.t()
  def get(conn) do
    bucket = conn.assigns.s3_bucket
    _ = ensure_bucket!(bucket)

    case BucketConfigs.get(bucket, :cors) do
      {:ok, rules} ->
        conn |> put_resp_content_type("application/xml") |> send_resp(200, View.render(rules))

      :none ->
        raise Error.new(:no_such_cors_configuration, resource: "/" <> bucket)
    end
  end

  @spec delete(Plug.Conn.t()) :: Plug.Conn.t()
  def delete(conn) do
    bucket = conn.assigns.s3_bucket
    _ = ensure_bucket!(bucket)
    :ok = BucketConfigs.delete(bucket, :cors)
    Log.info("delete bucket cors", action: :delete_bucket_cors, bucket: bucket)
    send_resp(conn, 204, "")
  end

  # ── 校验 ──
  defp validate!(rules) do
    cond do
      length(rules) > 100 -> raise Error.new(:malformed_xml, message: "Too many CORS rules (max 100)")
      Enum.all?(rules, &valid_rule?/1) -> :ok
      true -> raise Error.new(:malformed_xml, message: "Invalid CORS rule")
    end
  end

  defp valid_rule?(r) do
    methods = Map.get(r, "allowed_methods", [])
    origins = Map.get(r, "allowed_origins", [])
    headers = Map.get(r, "allowed_headers", [])

    methods != [] and origins != [] and
      Enum.all?(methods, &(&1 in @valid_methods)) and
      Enum.all?(origins, &at_most_one_star?/1) and
      Enum.all?(headers, &at_most_one_star?/1)
  end

  defp at_most_one_star?(s) do
    (s |> String.graphemes() |> Enum.count(&(&1 == "*"))) <= 1
  end

  defp ensure_bucket!(bucket) do
    case Buckets.lookup(bucket) do
      {:ok, b} -> b
      {:error, :not_found} -> raise Error.new(:no_such_bucket, resource: "/" <> bucket)
    end
  end

  defp read_small_body!(conn) do
    case read_body(conn, length: @limit, read_length: @limit) do
      {:ok, body, conn} -> {conn, body}
      {:more, _partial, _conn} -> raise Error.new(:malformed_xml, message: "CORS configuration exceeds 64KB")
      {:error, _} -> raise Error.new(:malformed_xml)
    end
  end
end
