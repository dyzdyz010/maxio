defmodule Maxio.S3.Views.OwnershipControls do
  @moduledoc "GetBucketOwnershipControls response XML."
  import Saxy.XML

  alias Maxio.S3.{OwnershipControls, XML}

  @spec render(map()) :: iodata()
  def render(config) when is_map(config) do
    %{"ObjectOwnership" => value} = OwnershipControls.normalize(config)

    root =
      element("OwnershipControls", [{"xmlns", XML.namespace()}], [
        element("Rule", [], [
          element("ObjectOwnership", [], characters(value))
        ])
      ])

    XML.encode(root)
  end
end
