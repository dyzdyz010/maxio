defmodule Maxio.S3.SystemHeaders do
  @moduledoc """
  S3 对象可控系统元数据头（区别于 x-amz-meta-* 用户元数据）的单一映射点。

  本模块只处理已由现有请求头大小闸放行的字符串值，不解析/规范化 HTTP-date，以保留客户端
  对 Expires 的原始表达；GET/HEAD 原样回显。
  """

  @headers [
    {"content-encoding", :content_encoding},
    {"content-disposition", :content_disposition},
    {"cache-control", :cache_control},
    {"expires", :expires}
  ]

  @fields Enum.map(@headers, fn {_header, field} -> field end)

  @spec fields() :: [atom()]
  def fields, do: @fields

  @spec from_req_headers([{String.t(), String.t()}]) :: map()
  def from_req_headers(req_headers) when is_list(req_headers) do
    Enum.reduce(@headers, %{}, fn {header, field}, acc ->
      case find_header(req_headers, header) do
        nil -> acc
        value -> put_header_value(acc, field, value)
      end
    end)
  end

  @spec from_object(map()) :: map()
  def from_object(object) do
    Map.new(@fields, fn field -> {field, Map.get(object, field)} end)
  end

  @spec take(map()) :: map()
  def take(attrs) when is_map(attrs), do: Map.take(attrs, @fields)

  @spec to_object_meta(map()) :: map()
  def to_object_meta(attrs) when is_map(attrs), do: Map.take(attrs, @fields)

  @spec put_response_headers(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def put_response_headers(conn, object) do
    Enum.reduce(@headers, conn, fn {header, field}, acc ->
      case Map.get(object, field) do
        value when is_binary(value) and value != "" ->
          Plug.Conn.put_resp_header(acc, header, value)

        _ ->
          acc
      end
    end)
  end

  defp find_header(req_headers, target) do
    Enum.find_value(req_headers, fn
      {name, value} when is_binary(name) and is_binary(value) ->
        if String.downcase(name) == target, do: value

      _ ->
        nil
    end)
  end

  defp put_header_value(acc, :content_encoding, value) do
    case strip_aws_chunked(value) do
      nil -> acc
      value -> Map.put(acc, :content_encoding, value)
    end
  end

  defp put_header_value(acc, field, value), do: Map.put(acc, field, value)

  # SigV4 streaming uses Content-Encoding: aws-chunked as a transfer framing marker.
  # It is not object metadata and must not be persisted or echoed as the object's
  # Content-Encoding. Preserve any real encodings the client listed alongside it.
  defp strip_aws_chunked(value) do
    value
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.downcase(&1) == "aws-chunked"))
    |> case do
      [] -> nil
      tokens -> Enum.join(tokens, ", ")
    end
  end
end
