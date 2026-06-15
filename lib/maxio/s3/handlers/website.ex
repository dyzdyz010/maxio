defmodule Maxio.S3.Handlers.Website do
  @moduledoc """
  ?website handler for PutBucketWebsite, GetBucketWebsite, and DeleteBucketWebsite.

  This stores and returns the S3 WebsiteConfiguration control-plane document. Serving the
  static website endpoint is a separate data-plane feature.
  """
  import Plug.Conn

  alias Maxio.{Buckets, BucketConfigs}
  alias Maxio.S3.{Error, Log}
  alias Maxio.S3.RequestParsers.Website, as: Parser
  alias Maxio.S3.Views.Website, as: View

  @limit 131_072
  @protocols ~w(http https)

  @spec put(Plug.Conn.t()) :: Plug.Conn.t()
  def put(conn) do
    bucket = conn.assigns.s3_bucket
    _ = ensure_bucket!(bucket)
    {conn, xml} = read_small_body!(conn)

    case Parser.parse(xml) do
      {:ok, config} ->
        :ok = validate!(config)
        :ok = BucketConfigs.put(bucket, :website, config)

        Log.info("put bucket website",
          action: :put_bucket_website,
          bucket: bucket,
          routing_rules_count: length(config["routing_rules"] || []),
          redirect_all_requests_to?: is_map(config["redirect_all_requests_to"])
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

    case BucketConfigs.get(bucket, :website) do
      {:ok, config} ->
        conn
        |> put_resp_content_type("application/xml")
        |> send_resp(200, View.render(config))

      :none ->
        raise Error.new(:no_such_website_configuration, resource: "/" <> bucket)
    end
  end

  @spec delete(Plug.Conn.t()) :: Plug.Conn.t()
  def delete(conn) do
    bucket = conn.assigns.s3_bucket
    _ = ensure_bucket!(bucket)
    :ok = BucketConfigs.delete(bucket, :website)

    Log.info("delete bucket website", action: :delete_bucket_website, bucket: bucket)

    send_resp(conn, 204, "")
  end

  @spec validate!(term()) :: :ok
  def validate!(config) when is_map(config) do
    index_document = config["index_document"]
    error_document = config["error_document"]
    redirect_all = config["redirect_all_requests_to"]
    routing_rules = config["routing_rules"] || []

    cond do
      not is_list(routing_rules) ->
        raise Error.new(:malformed_xml, message: "Invalid WebsiteConfiguration RoutingRules")

      length(routing_rules) > 50 ->
        raise Error.new(:malformed_xml, message: "Too many website routing rules (max 50)")

      empty_config?(index_document, error_document, redirect_all, routing_rules) ->
        raise Error.new(:malformed_xml, message: "Empty WebsiteConfiguration")

      is_map(redirect_all) and
          (present?(index_document) or present?(error_document) or routing_rules != []) ->
        raise Error.new(
                :malformed_xml,
                message: "RedirectAllRequestsTo cannot be combined with other website settings"
              )

      redirect_all == nil and not present?(index_document) ->
        raise Error.new(:malformed_xml, message: "WebsiteConfiguration requires IndexDocument")

      not valid_index_document?(index_document) ->
        raise Error.new(:malformed_xml, message: "Invalid IndexDocument")

      not valid_error_document?(error_document) ->
        raise Error.new(:malformed_xml, message: "Invalid ErrorDocument")

      not valid_redirect_all?(redirect_all) ->
        raise Error.new(:malformed_xml, message: "Invalid RedirectAllRequestsTo")

      not Enum.all?(routing_rules, &valid_routing_rule?/1) ->
        raise Error.new(:malformed_xml, message: "Invalid RoutingRule")

      true ->
        :ok
    end
  end

  def validate!(_config),
    do: raise(Error.new(:malformed_xml, message: "Invalid WebsiteConfiguration"))

  defp empty_config?(index_document, error_document, redirect_all, routing_rules) do
    not present?(index_document) and not present?(error_document) and not present?(redirect_all) and
      routing_rules == []
  end

  defp valid_index_document?(nil), do: true

  defp valid_index_document?(%{"suffix" => suffix}),
    do: non_empty_string?(suffix) and not String.contains?(suffix, "/")

  defp valid_index_document?(_other), do: false

  defp valid_error_document?(nil), do: true
  defp valid_error_document?(%{"key" => key}), do: non_empty_string?(key)
  defp valid_error_document?(_other), do: false

  defp valid_redirect_all?(nil), do: true

  defp valid_redirect_all?(%{"host_name" => host_name} = redirect) do
    non_empty_string?(host_name) and valid_protocol?(redirect["protocol"])
  end

  defp valid_redirect_all?(_other), do: false

  defp valid_routing_rule?(%{"redirect" => redirect} = rule) when is_map(redirect) do
    valid_condition?(rule["condition"]) and valid_redirect?(redirect)
  end

  defp valid_routing_rule?(_other), do: false

  defp valid_condition?(nil), do: true

  defp valid_condition?(condition) when is_map(condition) do
    map_size(condition) > 0 and
      Enum.all?(condition, fn
        {"http_error_code_returned_equals", value} -> http_status_code?(value)
        {"key_prefix_equals", value} -> is_binary(value)
        _other -> false
      end)
  end

  defp valid_condition?(_other), do: false

  defp valid_redirect?(redirect) when is_map(redirect) do
    has_redirect_target? =
      [
        "host_name",
        "protocol",
        "replace_key_prefix_with",
        "replace_key_with",
        "http_redirect_code"
      ]
      |> Enum.any?(&(Map.get(redirect, &1) not in [nil, ""]))

    not (present_text?(redirect["replace_key_prefix_with"]) and
           present_text?(redirect["replace_key_with"])) and
      has_redirect_target? and
      optional_non_empty_string?(redirect["host_name"]) and
      valid_protocol?(redirect["protocol"]) and
      optional_non_empty_string?(redirect["replace_key_prefix_with"]) and
      optional_non_empty_string?(redirect["replace_key_with"]) and
      redirect_code?(redirect["http_redirect_code"])
  end

  defp valid_redirect?(_redirect), do: false

  defp present?(value) when is_map(value), do: map_size(value) > 0
  defp present?(_value), do: false

  defp non_empty_string?(value), do: is_binary(value) and value != ""

  defp optional_non_empty_string?(nil), do: true
  defp optional_non_empty_string?(value), do: non_empty_string?(value)

  defp present_text?(value), do: is_binary(value) and value != ""

  defp valid_protocol?(nil), do: true
  defp valid_protocol?(value), do: value in @protocols

  defp http_status_code?(value) when is_binary(value) do
    case Integer.parse(value) do
      {code, ""} -> code >= 400 and code <= 599
      _other -> false
    end
  end

  defp http_status_code?(_value), do: false

  defp redirect_code?(nil), do: true

  defp redirect_code?(value) when is_binary(value) do
    case Integer.parse(value) do
      {code, ""} -> code >= 300 and code <= 399
      _other -> false
    end
  end

  defp redirect_code?(_value), do: false

  defp ensure_bucket!(bucket) do
    case Buckets.lookup(bucket) do
      {:ok, bucket} -> bucket
      {:error, :not_found} -> raise Error.new(:no_such_bucket, resource: "/" <> bucket)
    end
  end

  defp read_small_body!(conn) do
    case read_body(conn, length: @limit, read_length: @limit) do
      {:ok, body, conn} ->
        {conn, body}

      {:more, _partial, _conn} ->
        raise Error.new(:malformed_xml, message: "WebsiteConfiguration exceeds 128KB")

      {:error, _reason} ->
        raise Error.new(:malformed_xml)
    end
  end
end
