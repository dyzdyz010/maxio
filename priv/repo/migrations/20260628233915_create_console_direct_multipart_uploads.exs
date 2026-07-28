defmodule Maxio.Repo.Migrations.CreateConsoleDirectMultipartUploads do
  use Ecto.Migration

  def up do
    create table(:console_direct_multipart_uploads,
             primary_key: false,
             comment:
               "Console browser-direct multipart 上传恢复索引；对象字节与 part 权威仍归 S3 multipart_uploads/parts"
           ) do
      add :id, :binary_id, primary_key: true, comment: "Console direct multipart registry UUID 主键"

      add :multipart_upload_id,
          references(:multipart_uploads,
            type: :binary_id,
            on_delete: :delete_all,
            name: :console_direct_multipart_uploads_multipart_upload_id_fkey
          ),
          null: false,
          comment: "关联的 S3 multipart_uploads.id；Complete/Abort 删除会话时级联清理本 registry"

      add :bucket_name, :string,
        null: false,
        comment: "目标 bucket 名称；冗余保存便于 Console 按桶/prefix 列出未完成上传"

      add :key, :text,
        null: false,
        comment: "目标对象 key 原文；不做 URL 编码，必须与 multipart_uploads.key 一致"

      add :upload_id, :string,
        null: false,
        comment: "S3 UploadId；与 multipart_uploads.upload_id 一致，浏览器恢复时使用"

      add :principal_arn, :string,
        null: false,
        comment: "发起 direct multipart 的 Console principal ARN；非本人不得管理"

      add :access_key, :string,
        null: false,
        comment: "发起 direct multipart 的 Console access key id；仅用于审计，不保存 secret"

      add :file_name, :string,
        null: false,
        comment: "浏览器选择的本地文件名；仅用于恢复提示与指纹匹配"

      add :file_size, :bigint,
        null: false,
        comment: "浏览器声明的本地文件大小；恢复时必须与重新选择的文件一致"

      add :file_last_modified, :bigint,
        null: false,
        comment: "浏览器 File.lastModified 毫秒时间戳；与 file_size/key 一起作为恢复指纹"

      add :part_size, :bigint,
        null: false,
        comment: "本次 direct multipart 使用的 part size；恢复与 ListParts size 校验必须沿用"

      add :status, :string,
        null: false,
        default: "active",
        comment: "registry 状态；当前仅 active，真实完成/中止由 multipart_uploads 级联删除体现"

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:console_direct_multipart_uploads, [:upload_id],
             name: :console_direct_multipart_uploads_upload_id_index
           )

    create unique_index(:console_direct_multipart_uploads, [:multipart_upload_id],
             name: :console_direct_multipart_uploads_multipart_upload_id_index
           )

    create index(:console_direct_multipart_uploads, [:principal_arn, :bucket_name, :status, :key],
             name: :console_direct_multipart_uploads_owner_bucket_status_key_index
           )

    create index(
             :console_direct_multipart_uploads,
             [:principal_arn, :bucket_name, :key, :file_size, :file_last_modified],
             name: :console_direct_multipart_uploads_resume_fingerprint_index
           )

    execute(
      "COMMENT ON INDEX console_direct_multipart_uploads_upload_id_index IS '按 S3 UploadId 唯一定位 Console direct multipart registry'"
    )

    execute(
      "COMMENT ON INDEX console_direct_multipart_uploads_multipart_upload_id_index IS '每个 S3 multipart_uploads 会话至多一个 Console direct registry'"
    )

    execute(
      "COMMENT ON INDEX console_direct_multipart_uploads_owner_bucket_status_key_index IS 'Console Object Browser 按当前 principal、bucket、状态与 key/prefix 列出未完成 direct MPU'"
    )

    execute(
      "COMMENT ON INDEX console_direct_multipart_uploads_resume_fingerprint_index IS '浏览器重选同一文件时按 principal/bucket/key/size/lastModified 查找可恢复 direct MPU'"
    )

    execute(
      "COMMENT ON COLUMN console_direct_multipart_uploads.inserted_at IS 'registry 创建时间；用于 Console 展示发起时间'"
    )

    execute(
      "COMMENT ON COLUMN console_direct_multipart_uploads.updated_at IS 'registry 最后更新时间；register 覆盖时刷新'"
    )
  end

  def down do
    execute("COMMENT ON COLUMN console_direct_multipart_uploads.updated_at IS NULL")
    execute("COMMENT ON COLUMN console_direct_multipart_uploads.inserted_at IS NULL")
    execute("COMMENT ON INDEX console_direct_multipart_uploads_resume_fingerprint_index IS NULL")

    execute(
      "COMMENT ON INDEX console_direct_multipart_uploads_owner_bucket_status_key_index IS NULL"
    )

    execute("COMMENT ON INDEX console_direct_multipart_uploads_multipart_upload_id_index IS NULL")
    execute("COMMENT ON INDEX console_direct_multipart_uploads_upload_id_index IS NULL")

    drop_if_exists index(
                     :console_direct_multipart_uploads,
                     [:principal_arn, :bucket_name, :key, :file_size, :file_last_modified],
                     name: :console_direct_multipart_uploads_resume_fingerprint_index
                   )

    drop_if_exists index(
                     :console_direct_multipart_uploads,
                     [:principal_arn, :bucket_name, :status, :key],
                     name: :console_direct_multipart_uploads_owner_bucket_status_key_index
                   )

    drop_if_exists index(:console_direct_multipart_uploads, [:multipart_upload_id],
                     name: :console_direct_multipart_uploads_multipart_upload_id_index
                   )

    drop_if_exists index(:console_direct_multipart_uploads, [:upload_id],
                     name: :console_direct_multipart_uploads_upload_id_index
                   )

    drop table(:console_direct_multipart_uploads)
  end
end
