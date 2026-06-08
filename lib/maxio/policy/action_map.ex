defmodule Maxio.Policy.ActionMap do
  @moduledoc """
  S3 操作（Dispatcher 的 action atom）→ 所需 s3:Action + 资源层级（铁律 5，对齐官方
  「Required permissions for S3 API operations」表）。资源层级决定 Authz 构造桶 ARN 还是对象 ARN：
    :bucket  → arn:aws:s3:::<bucket>
    :object  → arn:aws:s3:::<bucket>/<key>
    :account → arn:aws:s3:::*（ListAllMyBuckets）
  CopyObject / UploadPartCopy 需源 GetObject + 目标 PutObject 两次检查（{:multi, [...]}），
  本 MVP 由 Authz 特判（见 authorize/2）。
  """

  @type level :: :bucket | :object | :account
  @type spec :: {String.t(), level()}

  @doc "返回 {required_action, level}。未知 action → nil（Authz 当作无需授权放行——仅子资源管理动作已显式列出）。"
  @spec for_action(atom()) :: spec() | nil
  def for_action(:list_buckets), do: {"s3:ListAllMyBuckets", :account}

  def for_action(:create_bucket), do: {"s3:CreateBucket", :bucket}
  def for_action(:delete_bucket), do: {"s3:DeleteBucket", :bucket}
  def for_action(:head_bucket), do: {"s3:ListBucket", :bucket}
  def for_action(:list_objects_v2), do: {"s3:ListBucket", :bucket}
  def for_action(:list_object_versions), do: {"s3:ListBucketVersions", :bucket}
  def for_action(:get_bucket_location), do: {"s3:GetBucketLocation", :bucket}

  def for_action(:put_object), do: {"s3:PutObject", :object}
  def for_action(:get_object), do: {"s3:GetObject", :object}
  def for_action(:head_object), do: {"s3:GetObject", :object}
  def for_action(:delete_object), do: {"s3:DeleteObject", :object}
  # DeleteObjects 批删：Authz 用桶级 s3:DeleteObject 作粗粒度门（细粒度逐 key 检查 defer，文档化）。
  def for_action(:delete_objects), do: {"s3:DeleteObject", :bucket}

  def for_action(:create_multipart_upload), do: {"s3:PutObject", :object}
  def for_action(:upload_part), do: {"s3:PutObject", :object}
  def for_action(:complete_multipart_upload), do: {"s3:PutObject", :object}
  def for_action(:abort_multipart_upload), do: {"s3:AbortMultipartUpload", :object}
  def for_action(:list_parts), do: {"s3:ListMultipartUploadParts", :object}
  def for_action(:list_multipart_uploads), do: {"s3:ListBucketMultipartUploads", :bucket}

  def for_action(:put_bucket_policy), do: {"s3:PutBucketPolicy", :bucket}
  def for_action(:get_bucket_policy), do: {"s3:GetBucketPolicy", :bucket}
  def for_action(:delete_bucket_policy), do: {"s3:DeleteBucketPolicy", :bucket}

  def for_action(:get_bucket_acl), do: {"s3:GetBucketAcl", :bucket}
  def for_action(:put_bucket_acl), do: {"s3:PutBucketAcl", :bucket}
  def for_action(:get_object_acl), do: {"s3:GetObjectAcl", :object}
  def for_action(:put_object_acl), do: {"s3:PutObjectAcl", :object}

  def for_action(:put_bucket_versioning), do: {"s3:PutBucketVersioning", :bucket}
  def for_action(:get_bucket_versioning), do: {"s3:GetBucketVersioning", :bucket}

  def for_action(:put_object_tagging), do: {"s3:PutObjectTagging", :object}
  def for_action(:get_object_tagging), do: {"s3:GetObjectTagging", :object}
  def for_action(:delete_object_tagging), do: {"s3:DeleteObjectTagging", :object}
  def for_action(:put_bucket_tagging), do: {"s3:PutBucketTagging", :bucket}
  def for_action(:get_bucket_tagging), do: {"s3:GetBucketTagging", :bucket}
  def for_action(:delete_bucket_tagging), do: {"s3:DeleteBucketTagging", :bucket}

  def for_action(:put_bucket_cors), do: {"s3:PutBucketCORS", :bucket}
  def for_action(:get_bucket_cors), do: {"s3:GetBucketCORS", :bucket}
  def for_action(:delete_bucket_cors), do: {"s3:PutBucketCORS", :bucket}

  def for_action(:put_bucket_lifecycle), do: {"s3:PutLifecycleConfiguration", :bucket}
  def for_action(:get_bucket_lifecycle), do: {"s3:GetLifecycleConfiguration", :bucket}
  def for_action(:delete_bucket_lifecycle), do: {"s3:PutLifecycleConfiguration", :bucket}

  # CopyObject 走 :put_object（put 路径内部分流），源读权限的二次检查由 Authz 特判（见 authorize/2 的 copy 分支）。
  def for_action(_other), do: nil
end
