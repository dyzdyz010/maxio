defmodule Maxio.IAM.OIDCDiscovery do
  @moduledoc "Behaviour for bounded OpenID Connect discovery used by IAM provider creation."

  @callback discover(String.t(), keyword()) ::
              {:ok,
               %{
                 required(:discovery_document) => map(),
                 required(:jwks) => map(),
                 required(:jwks_fetched_at) => DateTime.t(),
                 optional(:thumbprints) => [String.t()]
               }}
              | {:error, atom()}
end
