defmodule Maxio.S3.Views.LocationConstraint do
  @moduledoc "GetBucketLocation 响应 XML。us-east-1 返回空体（区域值为文本内容，非默认区域才填）。"
  import Saxy.XML
  alias Maxio.S3.XML

  @spec render(String.t()) :: iodata()
  def render(region) do
    content = if region == "us-east-1", do: [], else: characters(region)
    root = element("LocationConstraint", [{"xmlns", XML.namespace()}], content)
    XML.encode(root)
  end
end
