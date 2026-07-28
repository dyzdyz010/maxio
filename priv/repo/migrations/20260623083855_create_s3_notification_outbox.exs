defmodule Maxio.Repo.Migrations.CreateS3NotificationOutbox do
  use Ecto.Migration

  def up do
    create table(:s3_notification_outbox,
             primary_key: false,
             comment:
               "S3 Bucket Notification 数据面事件 outbox；对象变更提交后先持久化到此表，再由即时任务或显式 drain 投递，失败可按 next_attempt_at 重试"
           ) do
      add :id, :binary_id, primary_key: true, comment: "notification outbox 事件 UUID 主键"

      add :bucket, :string,
        null: false,
        comment: "触发事件的 bucket 名称；与 S3 事件 payload 中 bucket.name 保持一致"

      add :object_key, :text,
        null: false,
        comment: "触发事件的对象 key 原文；不做 URL 编码，payload 渲染时按目的地格式编码"

      add :event_name, :string,
        null: false,
        comment: "完整 S3 notification 事件名，例如 s3:ObjectCreated:Put"

      add :destination_type, :string,
        null: false,
        comment: "目的地类型：Topic/Queue/LambdaFunction/EventBridge"

      add :destination_arn, :string, comment: "目的地 ARN；EventBridgeConfiguration 无独立 ARN 时为 NULL"

      add :configuration_id, :string,
        comment: "NotificationConfiguration 中的 Id；EventBridge 使用固定 EventBridge"

      add :status, :string,
        null: false,
        default: "pending",
        comment: "投递状态：pending/delivering/delivered/failed；failed 到期后可重新 claim"

      add :attempts, :integer,
        null: false,
        default: 0,
        comment: "已开始的投递尝试次数；claim 时递增"

      add :next_attempt_at, :utc_datetime_usec,
        null: false,
        comment: "下一次允许投递尝试的时间；失败 backoff 与 delivering lease 均写入此字段"

      add :last_attempted_at, :utc_datetime_usec, comment: "最近一次投递尝试开始时间"

      add :delivered_at, :utc_datetime_usec, comment: "投递成功时间；成功后 status=delivered"

      add :error_reason, :string, comment: "最近一次投递失败的结构化原因摘要；不保存 secret、对象字节或外部响应正文"

      add :payload, :map,
        null: false,
        comment: "已构造的 notification 事件 payload；包含 destination/message/record 等投递所需 JSON 数据"

      timestamps(type: :utc_datetime_usec)
    end

    create index(:s3_notification_outbox, [:status, :next_attempt_at],
             name: :s3_notification_outbox_status_next_attempt_at_index,
             comment: "按状态与下一次尝试时间扫描可投递事件"
           )

    create index(:s3_notification_outbox, [:bucket, :object_key],
             name: :s3_notification_outbox_bucket_object_key_index,
             comment: "按 bucket/object key 查询对象相关 notification 事件"
           )

    create index(:s3_notification_outbox, [:destination_type, :destination_arn],
             name: :s3_notification_outbox_destination_index,
             comment: "按目的地类型与 ARN 查询投递积压"
           )

    execute("COMMENT ON COLUMN s3_notification_outbox.inserted_at IS 'outbox 事件创建时间'")
    execute("COMMENT ON COLUMN s3_notification_outbox.updated_at IS 'outbox 事件最后更新时间'")
  end

  def down do
    execute("COMMENT ON COLUMN s3_notification_outbox.updated_at IS NULL")
    execute("COMMENT ON COLUMN s3_notification_outbox.inserted_at IS NULL")

    drop_if_exists index(:s3_notification_outbox, [:destination_type, :destination_arn],
                     name: :s3_notification_outbox_destination_index
                   )

    drop_if_exists index(:s3_notification_outbox, [:bucket, :object_key],
                     name: :s3_notification_outbox_bucket_object_key_index
                   )

    drop_if_exists index(:s3_notification_outbox, [:status, :next_attempt_at],
                     name: :s3_notification_outbox_status_next_attempt_at_index
                   )

    drop table(:s3_notification_outbox)
  end
end
