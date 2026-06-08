defmodule Maxio.Repo.Migrations.CreateMultipartUploads do
  use Ecto.Migration

  def change do
    create table(:multipart_uploads,
             primary_key: false,
             comment:
               "S3 分段上传会话：CreateMultipartUpload 建一行，Complete/Abort 后删除；part 字节归存储后端"
           ) do
      add :id, :binary_id, primary_key: true, comment: "分段上传主键（UUID）"

      add :upload_id, :string,
        null: false,
        comment: "对客户端暴露的 UploadId（S3 全局应答；本系统用 UUID 串）"

      add :bucket_name, :string,
        null: false,
        comment: "目标桶名（与 key 一起定位最终对象）"

      add :key, :string, null: false, comment: "目标对象键（Complete 后写入此 key）"

      add :content_type, :string,
        null: false,
        default: "binary/octet-stream",
        comment: "最终对象 MIME（CreateMultipartUpload 的 Content-Type）"

      add :storage_class, :string,
        null: false,
        default: "STANDARD",
        comment: "存储类别（S3 兼容，MVP 恒 STANDARD）"

      add :owner, :string,
        null: false,
        comment: "发起者 principal（M2 恒为 root 的 arn）"

      add :metadata, :map,
        null: false,
        default: %{},
        comment: "用户自定义元数据（x-amz-meta-*，Complete 时随对象落库）"

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:multipart_uploads, [:upload_id],
             comment: "UploadId 唯一索引（UploadPart/Complete/Abort/ListParts 按此定位会话）"
           )

    create index(:multipart_uploads, [:bucket_name, :key],
             comment: "按桶名 + key 列举进行中分段上传索引（ListMultipartUploads prefix/分页）"
           )
  end
end
