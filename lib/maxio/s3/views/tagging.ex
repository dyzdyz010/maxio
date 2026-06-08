defmodule Maxio.S3.Views.Tagging do
  @moduledoc "Get{Object,Bucket}Tagging 响应 XML（Tagging>TagSet>Tag>(Key,Value)，带 xmlns）。"
  import Saxy.XML
  alias Maxio.S3.XML

  @spec render([{String.t(), String.t()}]) :: iodata()
  def render(tags) when is_list(tags) do
    tag_elems =
      Enum.map(tags, fn {k, v} ->
        element("Tag", [], [
          element("Key", [], characters(k)),
          element("Value", [], characters(v))
        ])
      end)

    root =
      element("Tagging", [{"xmlns", XML.namespace()}], [
        element("TagSet", [], tag_elems)
      ])

    XML.encode(root)
  end
end
