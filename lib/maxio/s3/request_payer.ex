defmodule Maxio.S3.RequestPayer do
  @moduledoc """
  Requester Pays data-plane enforcement.

  The helper only reads bucket config, request headers/query params, and the
  authenticated principal. It never consumes the request body.
  """

  import Plug.Conn

  alias Maxio.S3.{Authz, Error, RequestPayment}

  @charged :charged
  @not_charged :not_charged

  @type charge :: :charged | :not_charged

  @spec require!(Plug.Conn.t(), String.t(), keyword()) :: charge()
  def require!(conn, bucket, opts \\ []) when is_binary(bucket) do
    resource = Keyword.get(opts, :resource, "/" <> bucket)

    case RequestPayment.get_config(bucket) do
      {:ok, %{"Payer" => "Requester"}} ->
        require_requester!(conn, bucket, resource)

      {:ok, %{"Payer" => "BucketOwner"}} ->
        @not_charged
    end
  end

  @spec merge(charge(), charge()) :: charge()
  def merge(@charged, _other), do: @charged
  def merge(_other, @charged), do: @charged
  def merge(_left, _right), do: @not_charged

  @spec put_charged_header(Plug.Conn.t(), charge()) :: Plug.Conn.t()
  def put_charged_header(conn, @charged) do
    put_resp_header(conn, "x-amz-request-charged", "requester")
  end

  def put_charged_header(conn, _charge), do: conn

  defp require_requester!(conn, bucket, resource) do
    principal = Map.get(conn.assigns, :principal, :anonymous)

    cond do
      principal == :anonymous ->
        raise Error.new(:access_denied, resource: resource)

      Authz.owner?(principal, bucket) ->
        @not_charged

      requester_acknowledged?(conn) ->
        @charged

      true ->
        raise Error.new(:access_denied, resource: resource)
    end
  end

  defp requester_acknowledged?(conn) do
    header_values = get_req_header(conn, "x-amz-request-payer")
    query_values = query_values(conn.query_string, "x-amz-request-payer")

    valid_header? =
      header_values != [] and header_signed?(conn, "x-amz-request-payer") and
        all_requester?(header_values)

    valid_query? = query_values != [] and all_requester?(query_values)

    invalid_header? =
      header_values != [] and
        (not header_signed?(conn, "x-amz-request-payer") or not all_requester?(header_values))

    invalid_query? = query_values != [] and not all_requester?(query_values)

    (valid_header? or valid_query?) and not invalid_header? and not invalid_query?
  end

  defp all_requester?(values), do: Enum.all?(values, &(&1 == "requester"))

  defp header_signed?(conn, header) do
    signed_headers =
      conn.assigns
      |> Map.get(:sigv4_signed_headers, [])
      |> Enum.map(&String.downcase/1)

    String.downcase(header) in signed_headers
  end

  defp query_values("", _name), do: []
  defp query_values(nil, _name), do: []

  defp query_values(query_string, name) when is_binary(query_string) do
    query_string
    |> String.split("&", trim: true)
    |> Enum.flat_map(&query_pair_value(&1, name))
  end

  defp query_pair_value(pair, name) do
    {raw_key, raw_value} =
      case String.split(pair, "=", parts: 2) do
        [key, value] -> {key, value}
        [key] -> {key, ""}
      end

    if decode_strict(raw_key) == name do
      [decode_strict(raw_value)]
    else
      []
    end
  rescue
    ArgumentError -> []
  end

  # SigV4 canonical query decoding only decodes %XX and never treats "+" as a
  # space. Requester Pays query acknowledgement must follow the same wire model.
  defp decode_strict(value), do: URI.decode(value)
end
