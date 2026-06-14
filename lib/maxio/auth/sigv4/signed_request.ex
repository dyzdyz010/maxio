defmodule Maxio.Auth.SigV4.SignedRequest do
  @moduledoc """
  解析签名材料后的统一结构（header-based 与 presigned 两种形态共用）。
  payload_mode: :single（声明了 body 哈希）| :unsigned（UNSIGNED-PAYLOAD）|
  :streaming（STREAMING-AWS4-HMAC-SHA256-PAYLOAD）。
  """
  @enforce_keys [
    :access_key,
    :scope_date,
    :region,
    :service,
    :signed_headers,
    :signature,
    :amz_date,
    :auth_type,
    :payload_mode
  ]
  defstruct [
    :access_key,
    :scope_date,
    :region,
    :service,
    :signed_headers,
    :signature,
    :amz_date,
    :auth_type,
    :payload_mode,
    :expires,
    :session_token,
    :session_token_source
  ]

  @type t :: %__MODULE__{
          access_key: String.t(),
          scope_date: String.t(),
          region: String.t(),
          service: String.t(),
          signed_headers: [String.t()],
          signature: String.t(),
          amz_date: String.t(),
          auth_type: :header | :presigned,
          payload_mode: :single | :unsigned | :streaming,
          expires: pos_integer() | nil,
          session_token: String.t() | nil,
          session_token_source: :header | :query | nil
        }
end
