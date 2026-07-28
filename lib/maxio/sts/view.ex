defmodule Maxio.STS.View do
  @moduledoc "AWS STS Query API XML response rendering."

  import Saxy.XML

  alias Maxio.S3.XML
  alias Maxio.STS.Error

  @namespace "https://sts.amazonaws.com/doc/2011-06-15/"

  @spec get_session_token_response(map(), String.t() | nil) :: iodata()
  def get_session_token_response(session, request_id) when is_map(session) do
    root =
      element("GetSessionTokenResponse", [{"xmlns", @namespace}], [
        element("GetSessionTokenResult", [], [
          element("Credentials", [], [
            element("AccessKeyId", [], characters(session.access_key_id)),
            element("SecretAccessKey", [], characters(session.secret_key)),
            element("SessionToken", [], characters(session.session_token)),
            element("Expiration", [], characters(XML.iso8601(session.expires_at)))
          ])
        ]),
        response_metadata(request_id)
      ])

    XML.encode(root)
  end

  @spec get_caller_identity_response(map(), String.t() | nil) :: iodata()
  def get_caller_identity_response(identity, request_id) when is_map(identity) do
    root =
      element("GetCallerIdentityResponse", [{"xmlns", @namespace}], [
        element("GetCallerIdentityResult", [], [
          element("UserId", [], characters(identity.user_id)),
          element("Account", [], characters(identity.account)),
          element("Arn", [], characters(identity.arn))
        ]),
        response_metadata(request_id)
      ])

    XML.encode(root)
  end

  @spec get_access_key_info_response(String.t(), String.t() | nil) :: iodata()
  def get_access_key_info_response(account_id, request_id) when is_binary(account_id) do
    root =
      element("GetAccessKeyInfoResponse", [{"xmlns", @namespace}], [
        element("GetAccessKeyInfoResult", [], [
          element("Account", [], characters(account_id))
        ]),
        response_metadata(request_id)
      ])

    XML.encode(root)
  end

  @spec assume_role_response(map(), String.t() | nil) :: iodata()
  def assume_role_response(session, request_id) when is_map(session) do
    result_children =
      [
        element("AssumedRoleUser", [], [
          element("AssumedRoleId", [], characters(session.assumed_role_id)),
          element("Arn", [], characters(session.assumed_role_arn))
        ])
      ] ++
        source_identity_elements(session) ++
        [
          element("Credentials", [], [
            element("AccessKeyId", [], characters(session.access_key_id)),
            element("SecretAccessKey", [], characters(session.secret_key)),
            element("SessionToken", [], characters(session.session_token)),
            element("Expiration", [], characters(XML.iso8601(session.expires_at)))
          ])
        ]

    root =
      element("AssumeRoleResponse", [{"xmlns", @namespace}], [
        element("AssumeRoleResult", [], result_children),
        response_metadata(request_id)
      ])

    XML.encode(root)
  end

  @spec assume_role_with_web_identity_response(map(), String.t() | nil) :: iodata()
  def assume_role_with_web_identity_response(session, request_id) when is_map(session) do
    result_children =
      [
        element("SubjectFromWebIdentityToken", [], characters(session.web_identity_subject)),
        element("Audience", [], characters(session.web_identity_audience)),
        element("Provider", [], characters(session.web_identity_provider)),
        element("AssumedRoleUser", [], [
          element("AssumedRoleId", [], characters(session.assumed_role_id)),
          element("Arn", [], characters(session.assumed_role_arn))
        ]),
        element("Credentials", [], [
          element("AccessKeyId", [], characters(session.access_key_id)),
          element("SecretAccessKey", [], characters(session.secret_key)),
          element("SessionToken", [], characters(session.session_token)),
          element("Expiration", [], characters(XML.iso8601(session.expires_at)))
        ])
      ] ++ source_identity_elements(session)

    root =
      element("AssumeRoleWithWebIdentityResponse", [{"xmlns", @namespace}], [
        element("AssumeRoleWithWebIdentityResult", [], result_children),
        response_metadata(request_id)
      ])

    XML.encode(root)
  end

  @spec error_response(Error.t()) :: {pos_integer(), iodata()}
  def error_response(%Error{} = error) do
    root =
      element("ErrorResponse", [{"xmlns", @namespace}], [
        element("Error", [], [
          element("Type", [], characters(error.type)),
          element("Code", [], characters(error.code)),
          element("Message", [], characters(error.message))
        ]),
        element("RequestId", [], characters(to_string(error.request_id || "")))
      ])

    {error.http_status, XML.encode(root)}
  end

  defp response_metadata(nil), do: element("ResponseMetadata", [], [])
  defp response_metadata(""), do: element("ResponseMetadata", [], [])

  defp response_metadata(request_id) do
    element("ResponseMetadata", [], [
      element("RequestId", [], characters(request_id))
    ])
  end

  defp source_identity_elements(%{source_identity: source_identity})
       when is_binary(source_identity) and source_identity != "" do
    [element("SourceIdentity", [], characters(source_identity))]
  end

  defp source_identity_elements(_session), do: []
end
