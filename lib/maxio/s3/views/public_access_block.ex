defmodule Maxio.S3.Views.PublicAccessBlock do
  @moduledoc "GetPublicAccessBlock response XML."
  import Saxy.XML
  alias Maxio.S3.{PublicAccessBlock, XML}

  @spec render(map()) :: iodata()
  def render(config) when is_map(config) do
    config = PublicAccessBlock.normalize(config)

    children =
      Enum.map(PublicAccessBlock.keys(), fn key ->
        element(key, [], characters(bool_text(Map.get(config, key, false))))
      end)

    root = element("PublicAccessBlockConfiguration", [{"xmlns", XML.namespace()}], children)
    XML.encode(root)
  end

  defp bool_text(true), do: "true"
  defp bool_text(false), do: "false"
end
