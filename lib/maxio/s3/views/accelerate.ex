defmodule Maxio.S3.Views.Accelerate do
  @moduledoc "GetBucketAccelerateConfiguration response XML renderer."
  import Saxy.XML

  alias Maxio.S3.{Accelerate, XML}

  @spec render(map()) :: iodata()
  def render(config) when is_map(config) do
    %{"Status" => status} = Accelerate.normalize(config)

    children =
      case status do
        nil -> []
        value -> [element("Status", [], characters(value))]
      end

    XML.encode(element("AccelerateConfiguration", [{"xmlns", XML.namespace()}], children))
  end
end
