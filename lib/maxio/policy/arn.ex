defmodule Maxio.Policy.Arn do
  @moduledoc """
  S3 ARN 构造与通配匹配（铁律 5，对齐官方）。
  S3 ARN 的 region/account 段恒空：`arn:aws:s3:::<bucket>[/<key>]`。
  桶级动作用桶 ARN，对象级动作用对象 ARN（getting this wrong 是 S3 授权头号 bug）。

  通配（Action 与 Resource 共用，policy 文档语义）：
    * `*` = 多字符（≥0）通配  →  正则 `.*`
    * `?` = 单字符通配        →  正则 `.`
    * 其余字符 Regex.escape，整体 `\\A…\\z` 锚定。
  Action 匹配大小写不敏感（官方：`iam:ListAccessKeys` == `IAM:listaccesskeys`）；
  Resource 匹配大小写敏感（S3 key 区分大小写）。
  """

  @doc "桶资源 ARN：arn:aws:s3:::<bucket>"
  @spec bucket_arn(String.t()) :: String.t()
  def bucket_arn(bucket), do: "arn:aws:s3:::" <> bucket

  @doc "对象资源 ARN：arn:aws:s3:::<bucket>/<key>"
  @spec object_arn(String.t(), String.t()) :: String.t()
  def object_arn(bucket, key), do: "arn:aws:s3:::" <> bucket <> "/" <> key

  @doc "账户级伪资源（ListAllMyBuckets）：arn:aws:s3:::*"
  @spec account_arn() :: String.t()
  def account_arn, do: "arn:aws:s3:::*"

  @doc """
  通配匹配。opts[:case_insensitive]（默认 false）。
  pattern 来自 policy（可含 `*`/`?`），value 是请求的具体 action/resource 串。
  """
  @spec glob_match?(String.t(), String.t(), keyword()) :: boolean()
  def glob_match?(pattern, value, opts \\ []) when is_binary(pattern) and is_binary(value) do
    regex_src =
      pattern
      |> Regex.escape()
      |> String.replace("\\*", ".*")
      |> String.replace("\\?", ".")

    flags = if Keyword.get(opts, :case_insensitive, false), do: "iu", else: "u"

    case Regex.compile("\\A" <> regex_src <> "\\z", flags) do
      {:ok, re} -> Regex.match?(re, value)
      {:error, _} -> false
    end
  end
end
