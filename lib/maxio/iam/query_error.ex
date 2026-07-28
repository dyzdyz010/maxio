defmodule Maxio.IAM.QueryError do
  @moduledoc """
  AWS IAM Query API error shape.

  IAM management actions share SigV4 with S3/STS, but their wire errors are
  AWS Query API `<ErrorResponse>` envelopes in the IAM namespace.
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
    delete_conflict:
      {"DeleteConflict", 409, "Cannot delete a virtual MFA device that is still active.",
       "Sender"},
    duplicate_certificate:
      {"DuplicateCertificate", 409,
       "The request was rejected because the same certificate already exists.", "Sender"},
    duplicate_ssh_public_key:
      {"DuplicateSSHPublicKey", 400,
       "The request was rejected because the same SSH public key already exists.", "Sender"},
    entity_already_exists:
      {"EntityAlreadyExists", 409,
       "The request was rejected because it attempted to create a duplicate entity.", "Sender"},
    invalid_action:
      {"InvalidAction", 400, "The action or operation requested is invalid.", "Sender"},
    invalid_authentication_code:
      {"InvalidAuthenticationCode", 403, "The supplied authentication code is invalid.", "Sender"},
    invalid_input: {"InvalidInput", 400, "The request contains invalid input.", "Sender"},
    invalid_parameter_value:
      {"InvalidParameterValue", 400, "An invalid or out-of-range value was supplied.", "Sender"},
    invalid_request: {"InvalidRequest", 400, "The request is invalid.", "Sender"},
    invalid_public_key:
      {"InvalidPublicKey", 400, "The SSH public key is invalid or malformed.", "Sender"},
    key_pair_mismatch:
      {"KeyPairMismatch", 400, "The certificate body does not match the supplied private key.",
       "Sender"},
    limit_exceeded:
      {"LimitExceeded", 409,
       "The request was rejected because it attempted to create resources beyond the current account limits.",
       "Sender"},
    malformed_certificate:
      {"MalformedCertificate", 400, "The certificate is malformed or invalid.", "Sender"},
    malformed_policy_document:
      {"MalformedPolicyDocument", 400, "The policy document is malformed.", "Sender"},
    no_such_entity:
      {"NoSuchEntity", 404,
       "The request was rejected because it referenced an entity that does not exist.", "Sender"},
    open_id_idp_communication_error:
      {"OpenIdIdpCommunicationError", 400,
       "IAM cannot connect to the OpenID Connect identity provider URL.", "Sender"},
    service_failure: {"ServiceFailure", 500, "The request processing has failed.", "Receiver"},
    unrecognized_public_key_encoding:
      {"UnrecognizedPublicKeyEncoding", 400, "The SSH public key encoding is not recognized.",
       "Sender"}
  }

  @spec new(atom(), keyword()) :: t()
  def new(code, opts \\ []) when is_atom(code) do
    {code_str, status, default_msg, type} = Map.get(@table, code, @table.service_failure)

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
