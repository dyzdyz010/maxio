defmodule Maxio.STS.Error do
  @moduledoc """
  STS Query API error shape.

  S3 and STS share SigV4 authentication, but their wire error envelopes differ.
  This module keeps STS action/parameter errors in the AWS Query API
  `<ErrorResponse>` shape instead of reusing S3 `<Error>` responses.
  """

  defexception [:code, :message, :http_status, :type, :request_id]

  @type t :: %__MODULE__{
          code: String.t(),
          message: String.t(),
          http_status: pos_integer(),
          type: String.t(),
          request_id: String.t() | nil
        }

  @table %{
    access_denied: {"AccessDenied", 403, "Access denied.", "Sender"},
    invalid_action:
      {"InvalidAction", 400, "The action or operation requested is invalid.", "Sender"},
    invalid_client_token_id:
      {"InvalidClientTokenId", 403, "The security token included in the request is invalid.",
       "Sender"},
    malformed_policy_document:
      {"MalformedPolicyDocument", 400, "The policy document is malformed.", "Sender"},
    invalid_parameter_value:
      {"InvalidParameterValue", 400, "An invalid or out-of-range value was supplied.", "Sender"},
    invalid_request: {"InvalidRequest", 400, "The request is invalid.", "Sender"},
    invalid_identity_token:
      {"InvalidIdentityToken", 400, "The web identity token is invalid.", "Sender"},
    expired_token:
      {"ExpiredToken", 400, "The security token included in the request is expired.", "Sender"},
    idp_rejected_claim:
      {"IDPRejectedClaim", 403, "The identity provider rejected the claim.", "Sender"},
    internal_failure: {"InternalFailure", 500, "The request processing has failed.", "Receiver"}
  }

  @spec new(atom(), keyword()) :: t()
  def new(code, opts \\ []) when is_atom(code) do
    {code_str, status, default_msg, type} =
      Map.get(@table, code, @table.internal_failure)

    %__MODULE__{
      code: code_str,
      message: Keyword.get(opts, :message, default_msg),
      http_status: status,
      type: Keyword.get(opts, :type, type),
      request_id: Keyword.get(opts, :request_id)
    }
  end

  @impl true
  def message(%__MODULE__{code: code, message: message}), do: "#{code}: #{message}"
end
