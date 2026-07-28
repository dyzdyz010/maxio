defmodule Maxio.Policy.RequestContext do
  @moduledoc """
  授权评估输入（纯数据）。由 Maxio.S3.Authz 按 operation→action 映射 + 当前 principal 组装。

  字段：
    * principal —— 认证 principal map（%{type, access_key, arn}）或 :anonymous。
    * authenticated? —— 是否带有效签名（AuthenticatedUsers 组判定用；:anonymous → false）。
    * owner? —— principal 是否为该资源（桶/对象）所有者或 root；用于补隐式 Allow，
      但不覆盖显式 Deny。
    * action —— "s3:GetObject" 等具体动作串。
    * resource —— 已构造的具体资源 ARN（桶级动作=桶 ARN，对象级=对象 ARN，账户级=arn:aws:s3:::*）。
    * conditions —— 从 HTTP 请求抽取的条件键值（aws:SecureTransport / aws:SourceIp /
      aws:CurrentTime / s3:prefix / s3:delimiter 等），供条件算子求值。
  """
  @type t :: %__MODULE__{
          principal: map() | :anonymous,
          authenticated?: boolean(),
          owner?: boolean(),
          action: String.t(),
          resource: String.t(),
          conditions: map()
        }

  defstruct principal: :anonymous,
            authenticated?: false,
            owner?: false,
            action: "",
            resource: "",
            conditions: %{}
end
