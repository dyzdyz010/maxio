defmodule Maxio.Policy.ACL do
  @moduledoc """
  Canned ACL ↔ 等价策略 statement 折叠（铁律 2：ACL 与 policy 共用同一个 Evaluator，不另起评估路径）
  + AccessControlPolicy XML 出入站（委托 view / request parser）。

  官方核验（§RESEARCH bake-in）映射：
    AllUsers 组          → principal "*"（匿名+认证均匹配）
    AuthenticatedUsers 组 → 任意认证 principal（本系统：principal "*" 但要求 authenticated?；
                            MVP 用内部条件键 "maxio:Authenticated"=="true" 表达，由 Authz 构造 ctx 时填）
  ACL permission → S3 action（对象/桶分别）：
    READ(对象)  → s3:GetObject(+Version)        READ(桶)  → s3:ListBucket(+Versions,+MultipartUploads)
    WRITE(桶)   → s3:PutObject                  READ_ACP  → s3:Get{Bucket,Object}Acl
    WRITE_ACP   → s3:Put{Bucket,Object}Acl
  Owner FULL_CONTROL 隐含——本系统 owner 由 Evaluator owner? 短路处理，故 canned 只产生“公共/组”授权 statement。

  支持 canned：private / public-read / public-read-write / authenticated-read。
  其余 canned（bucket-owner-*/aws-exec-read/log-delivery-write）→ 存名不产生公共 statement（按 private 评估，文档化）。
  """
  alias Maxio.Policy.{Arn, Statement}

  @public_canned ~w(public-read public-read-write authenticated-read)

  @doc "已知/受支持的 canned 名（用于校验 x-amz-acl）。"
  @spec known?(String.t()) :: boolean()
  def known?(canned) do
    canned in ~w(private public-read public-read-write authenticated-read
                 bucket-owner-read bucket-owner-full-control aws-exec-read log-delivery-write)
  end

  @doc """
  canned ACL → 等价 [Statement]（折叠进 Evaluator）。
  level=:bucket → resource=桶 ARN；level=:object → resource=对象 ARN（key 必给）。
  private 与未支持 canned → []（仅 owner 短路，无公共授权）。
  """
  @spec canned_to_statements(String.t(), :bucket | :object, String.t(), String.t() | nil) ::
          [Statement.t()]
  def canned_to_statements(canned, _level, _bucket, _key) when canned not in @public_canned, do: []

  def canned_to_statements("public-read", :object, bucket, key) do
    [allow_stmt(:any, ["s3:GetObject", "s3:GetObjectVersion"], [Arn.object_arn(bucket, key)])]
  end

  def canned_to_statements("public-read", :bucket, bucket, _key) do
    [allow_stmt(:any, bucket_read_actions(), [Arn.bucket_arn(bucket)])]
  end

  def canned_to_statements("public-read-write", :object, bucket, key) do
    [
      allow_stmt(:any, ["s3:GetObject", "s3:GetObjectVersion"], [Arn.object_arn(bucket, key)]),
      allow_stmt(:any, ["s3:PutObject"], [Arn.object_arn(bucket, key)])
    ]
  end

  def canned_to_statements("public-read-write", :bucket, bucket, _key) do
    [
      allow_stmt(:any, bucket_read_actions(), [Arn.bucket_arn(bucket)]),
      allow_stmt(:any, ["s3:PutObject"], [Arn.bucket_arn(bucket) <> "/*"])
    ]
  end

  # authenticated-read：仅认证 principal。用内部条件键 "maxio:Authenticated"=="true" 表达，
  # Authz 构造 ctx 时把 authenticated? 写入该键；匿名缺键 → 条件不成立 → 不命中（详见 M3-8 注释）。
  def canned_to_statements("authenticated-read", :object, bucket, key) do
    [allow_stmt(:authenticated, ["s3:GetObject", "s3:GetObjectVersion"], [Arn.object_arn(bucket, key)])]
  end

  def canned_to_statements("authenticated-read", :bucket, bucket, _key) do
    [allow_stmt(:authenticated, bucket_read_actions(), [Arn.bucket_arn(bucket)])]
  end

  defp bucket_read_actions,
    do: ["s3:ListBucket", "s3:ListBucketVersions", "s3:ListBucketMultipartUploads"]

  # principal=:authenticated → principals=:any + 内部条件键 "maxio:Authenticated"=="true"。
  defp allow_stmt(:authenticated, actions, resources) do
    %Statement{
      effect: :allow,
      actions: actions,
      resources: resources,
      principals: :any,
      conditions: %{"StringEquals" => %{"maxio:Authenticated" => "true"}}
    }
  end

  defp allow_stmt(:any, actions, resources) do
    %Statement{effect: :allow, actions: actions, resources: resources, principals: :any, conditions: %{}}
  end
end
