defmodule Maxio.S3.MFADelete.Verifier do
  @moduledoc """
  Behaviour/config facade for MFA Delete token verification.

  Production deployments must configure a verifier via:

      config :maxio, :mfa_delete_verifier, MyVerifier

  where `MyVerifier.verify/3` returns `:ok` or `{:error, reason}`.
  A three-arity function is also accepted for tests.
  """

  @callback verify(principal :: map(), serial :: String.t(), code :: String.t()) ::
              :ok | {:error, term()}

  @spec verify(map(), String.t(), String.t()) :: :ok | {:error, term()}
  def verify(principal, serial, code) do
    case Application.get_env(:maxio, :mfa_delete_verifier) do
      nil ->
        {:error, :mfa_verifier_not_configured}

      verifier when is_atom(verifier) ->
        verifier.verify(principal, serial, code)

      verifier when is_function(verifier, 3) ->
        verifier.(principal, serial, code)

      {module, function, extra_args} when is_atom(module) and is_atom(function) ->
        apply(module, function, [principal, serial, code | List.wrap(extra_args)])

      _other ->
        {:error, :invalid_mfa_verifier_config}
    end
  end
end
