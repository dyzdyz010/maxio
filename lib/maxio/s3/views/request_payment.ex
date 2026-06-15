defmodule Maxio.S3.Views.RequestPayment do
  @moduledoc "GetBucketRequestPayment response XML renderer."
  import Saxy.XML

  alias Maxio.S3.{RequestPayment, XML}

  @spec render(map()) :: iodata()
  def render(config) when is_map(config) do
    %{"Payer" => payer} = RequestPayment.normalize(config)

    root =
      element("RequestPaymentConfiguration", [{"xmlns", XML.namespace()}], [
        element("Payer", [], characters(payer))
      ])

    XML.encode(root)
  end
end
