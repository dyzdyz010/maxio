defmodule Maxio.S3.Handlers.Cors do
  @moduledoc """
  ?cors 子资源 handler：PutBucketCors（XML → 校验 → 存，200）、GetBucketCors（200+XML，无→404
  NoSuchCORSConfiguration）、DeleteBucketCors（204）。校验：方法白名单 GET/PUT/POST/DELETE/HEAD、
  origin/header 至多一个*、每 rule 至少一个 method+origin、≤100 rule。违反 → MalformedXML 400。
  XML body 走带上限整读（铁律 4）。
  """
  import Plug.Conn
  alias Maxio.{Buckets, BucketConfigs}
  alias Maxio.S3.{ControlBody, Error, ExpectedBucketOwner, Log}
  alias Maxio.S3.RequestParsers.Cors, as: Parser
  alias Maxio.S3.Views.Cors, as: View

  @limit 65_536
  @valid_methods ~w(GET PUT POST DELETE HEAD)

  @spec put(Plug.Conn.t()) :: Plug.Conn.t()
  def put(conn) do
    bucket = conn.assigns.s3_bucket
    _ = ensure_bucket!(bucket)
    :ok = ExpectedBucketOwner.verify!(conn, bucket)
    {conn, xml} = read_xml_body!(conn)

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
    :ok = ExpectedBucketOwner.verify!(conn, bucket)

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
    :ok = ExpectedBucketOwner.verify!(conn, bucket)
    :ok = BucketConfigs.delete(bucket, :cors)
    Log.info("delete bucket cors", action: :delete_bucket_cors, bucket: bucket)
    send_resp(conn, 204, "")
  end

  # ── 校验 ──
  @spec validate!(term()) :: :ok
  def validate!(rules) when is_list(rules) do
    cond do
      rules == [] ->
        raise Error.new(:malformed_xml, message: "CORS configuration requires at least one rule")

      length(rules) > 100 ->
        raise Error.new(:malformed_xml, message: "Too many CORS rules (max 100)")

      Enum.all?(rules, &valid_rule?/1) ->
        :ok

      true ->
        raise Error.new(:malformed_xml, message: "Invalid CORS rule")
    end
  end

  def validate!(_rules),
    do: raise(Error.new(:malformed_xml, message: "Invalid CORS configuration"))

  defp valid_rule?(r) when is_map(r) do
    methods = Map.get(r, "allowed_methods", [])
    origins = Map.get(r, "allowed_origins", [])
    headers = Map.get(r, "allowed_headers", [])
    expose_headers = Map.get(r, "expose_headers", [])
    max_age = Map.get(r, "max_age_seconds")
    id = Map.get(r, "id")

    methods != [] and origins != [] and
      list_of_non_empty_strings?(methods) and list_of_non_empty_strings?(origins) and
      list_of_non_empty_strings?(headers) and list_of_non_empty_strings?(expose_headers) and
      Enum.all?(methods, &(&1 in @valid_methods)) and
      Enum.all?(origins, &at_most_one_star?/1) and
      Enum.all?(headers, &at_most_one_star?/1) and
      optional_id?(id) and optional_non_negative_integer?(max_age)
  end

  defp valid_rule?(_r), do: false

  defp list_of_non_empty_strings?(values) when is_list(values),
    do: Enum.all?(values, &(is_binary(&1) and &1 != ""))

  defp list_of_non_empty_strings?(_values), do: false

  defp optional_id?(nil), do: true
  defp optional_id?(value), do: is_binary(value) and String.length(value) <= 255

  defp optional_non_negative_integer?(nil), do: true
  defp optional_non_negative_integer?(value) when is_integer(value), do: value >= 0
  defp optional_non_negative_integer?(_value), do: false

  defp at_most_one_star?(s) do
    s |> String.graphemes() |> Enum.count(&(&1 == "*")) <= 1
  end

  defp ensure_bucket!(bucket) do
    case Buckets.lookup(bucket) do
      {:ok, b} -> b
      {:error, :not_found} -> raise Error.new(:no_such_bucket, resource: "/" <> bucket)
    end
  end

  defp read_xml_body!(conn) do
    ControlBody.read_and_verify!(conn, @limit, "CORS configuration exceeds 64KB",
      require_integrity: :content_md5
    )
  end
end
