defmodule Maxio.S3.ErrorView do
  @moduledoc """
  把 %Maxio.S3.Error{} 渲染为 S3 兼容的 <Error> XML（铁律 3：所有错误显式映射、不静默 500）。
  返回 {http_status, iodata}，由 plug 写 Content-Type: application/xml + send_resp。
  """
  import Saxy.XML
  alias Maxio.S3.{Error, XML}

  @doc "渲染错误为 {status, xml iodata}。resource/request_id 缺省则省略对应元素。"
  @spec render(Error.t()) :: {pos_integer(), iodata()}
  def render(%Error{} = err) do
    children =
      [
        element("Code", [], characters(err.code)),
        element("Message", [], characters(err.message))
      ]
      |> maybe_append("Resource", err.resource)
      |> maybe_append("RequestId", err.request_id)

    root = element("Error", [], children)
    {err.http_status, XML.encode(root)}
  end

  defp maybe_append(children, _name, nil), do: children
  defp maybe_append(children, _name, ""), do: children

  defp maybe_append(children, name, value) do
    children ++ [element(name, [], characters(to_string(value)))]
  end
end
