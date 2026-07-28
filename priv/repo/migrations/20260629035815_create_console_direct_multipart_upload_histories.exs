defmodule Maxio.Repo.Migrations.CreateConsoleDirectMultipartUploadHistories do
  use Ecto.Migration

  def up do
    create table(:console_direct_multipart_upload_histories,
             primary_key: false,
             comment: "Console browser-direct multipart 终态历史；只保存非秘密审计快照，不作为 S3 MPU/part 权威"
           ) do
      add :id, :binary_id,
        primary_key: true,
        comment: "Console direct multipart history UUID 主键"

      add :upload_id, :string,
        null: false,
        comment: "S3 UploadId；终态历史按 upload_id 幂等唯一"

      add :terminal_state, :string,
        null: false,
        comment: "终态：completed 表示 S3 Complete 成功，aborted 表示 S3 Abort 成功"

      add :bucket_name, :string,
        null: false,
        comment: "目标 bucket 名称；用于 Console 按 bucket/prefix 展示历史"

      add :key, :text,
        null: false,
        comment: "目标对象 key 原文；不保存 URL 或 presigned query"

      add :principal_arn, :string,
        null: false,
        comment: "发起 direct multipart 的 Console principal ARN；用于历史可见性隔离"

      add :access_key, :string,
        null: false,
        comment: "发起 direct multipart 的 Console access key id；仅用于审计，不保存 secret"

      add :file_name, :string,
        null: false,
        comment: "浏览器选择的本地文件名；非秘密恢复/审计信息"

      add :file_size, :bigint,
        null: false,
        comment: "浏览器声明的本地文件大小；不代表 S3 Complete 权威 part 列表"

      add :file_last_modified, :bigint,
        null: false,
        comment: "浏览器 File.lastModified 毫秒时间戳；非秘密文件指纹"

      add :part_size, :bigint,
        null: false,
        comment: "本次 direct multipart 使用的 part size"

      add :part_count, :integer,
        null: false,
        default: 0,
        comment: "终态记录时 multipart_parts 中已提交 part 数量快照"

      add :uploaded_size, :bigint,
        null: false,
        default: 0,
        comment: "终态记录时已提交 part 明文字节数快照；completed 时等于完成对象 size"

      add :etag, :string, comment: "CompleteMultipartUpload 成功后的对象 ETag；aborted 为空"

      add :version_id, :string, comment: "CompleteMultipartUpload 成功后的对象 versionId；aborted 为空"

      add :content_type, :string, comment: "CreateMultipartUpload 会话捕获的 Content-Type"

      add :storage_class, :string, comment: "CreateMultipartUpload 会话捕获的 storage class"

      add :request_payer, :boolean,
        null: false,
        default: false,
        comment: "本 direct multipart 是否使用 Requester Pays capability"

      add :sse_algorithm, :string, comment: "完成/中止时 MPU 的 SSE 算法；不保存 envelope 或 customer key"

      add :sse_customer_key_required, :boolean,
        null: false,
        default: false,
        comment: "是否为 SSE-C direct MPU；仅保存非秘密布尔标记"

      add :terminal_at, :utc_datetime_usec,
        null: false,
        comment: "终态发生时间；completed/aborted 共用"

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:console_direct_multipart_upload_histories, [:upload_id],
             name: :console_direct_multipart_upload_histories_upload_id_index
           )

    create index(
             :console_direct_multipart_upload_histories,
             [:principal_arn, :bucket_name, :terminal_at],
             name: :console_direct_multipart_upload_histories_owner_bucket_time_index
           )

    create index(
             :console_direct_multipart_upload_histories,
             [:principal_arn, :bucket_name, :key, :terminal_at],
             name: :console_direct_multipart_upload_histories_owner_bucket_key_time_index
           )

    execute(
      "COMMENT ON INDEX console_direct_multipart_upload_histories_upload_id_index IS '按 S3 UploadId 幂等定位 Console direct multipart 终态历史'"
    )

    execute(
      "COMMENT ON INDEX console_direct_multipart_upload_histories_owner_bucket_time_index IS 'Console 按 principal 与 bucket 查询最近 direct multipart 终态历史'"
    )

    execute(
      "COMMENT ON INDEX console_direct_multipart_upload_histories_owner_bucket_key_time_index IS 'Console 按 principal、bucket 与 key/prefix 查询 direct multipart 终态历史'"
    )

    execute(
      "COMMENT ON COLUMN console_direct_multipart_upload_histories.inserted_at IS 'history 行创建时间；通常等于终态记录写入时间'"
    )

    execute(
      "COMMENT ON COLUMN console_direct_multipart_upload_histories.updated_at IS 'history 行更新时间；幂等 upsert 时刷新'"
    )
  end

  def down do
    execute("COMMENT ON COLUMN console_direct_multipart_upload_histories.updated_at IS NULL")
    execute("COMMENT ON COLUMN console_direct_multipart_upload_histories.inserted_at IS NULL")

    execute(
      "COMMENT ON INDEX console_direct_multipart_upload_histories_owner_bucket_key_time_index IS NULL"
    )

    execute(
      "COMMENT ON INDEX console_direct_multipart_upload_histories_owner_bucket_time_index IS NULL"
    )

    execute("COMMENT ON INDEX console_direct_multipart_upload_histories_upload_id_index IS NULL")

    drop_if_exists index(
                     :console_direct_multipart_upload_histories,
                     [:principal_arn, :bucket_name, :key, :terminal_at],
                     name: :console_direct_multipart_upload_histories_owner_bucket_key_time_index
                   )

    drop_if_exists index(
                     :console_direct_multipart_upload_histories,
                     [:principal_arn, :bucket_name, :terminal_at],
                     name: :console_direct_multipart_upload_histories_owner_bucket_time_index
                   )

    drop_if_exists index(:console_direct_multipart_upload_histories, [:upload_id],
                     name: :console_direct_multipart_upload_histories_upload_id_index
                   )

    drop table(:console_direct_multipart_upload_histories)
  end
end
