defmodule Maxio.Auth.SigningSecret do
  @moduledoc """
  Request-scoped capability containing the credential that successfully signed a request.

  The value is deliberately redacted from inspection and has no JSON encoder or public
  accessor. It may only be consumed synchronously by the authenticated admin envelope path.
  """

  @opaque t :: %__MODULE__{secret: binary()}
  defstruct [:secret]

  @doc false
  @spec new(binary()) :: t()
  def new(secret) when is_binary(secret), do: %__MODULE__{secret: secret}

  defimpl Inspect do
    def inspect(_secret, _opts), do: "#Maxio.Auth.SigningSecret<redacted>"
  end
end
