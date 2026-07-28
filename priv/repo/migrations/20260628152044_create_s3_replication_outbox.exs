defmodule Maxio.Repo.Migrations.CreateS3ReplicationOutbox do
  use Ecto.Migration

  def up do
    alter table(:objects) do
      add :replication_status, :string,
        comment: "S3 对象复制状态；源对象为 PENDING/COMPLETED/FAILED，副本对象为 REPLICA"
    end

    create table(:s3_replication_outbox,
             primary_key: false,
             comment: "S3 Bucket Replication 数据面 outbox；对象变更提交后先持久化复制任务，再由 drain/调度器幂等执行"
           ) do
      add :id, :binary_id, primary_key: true, comment: "replication outbox 任务 UUID 主键"

      add :source_bucket, :string,
        null: false,
        comment: "源 bucket 名称；与源对象元数据中的 bucket_name 保持一致"

      add :source_key, :text,
        null: false,
        comment: "源对象 key 原文；不做 URL 编码"

      add :source_version_id, :string,
        null: false,
        comment: "源对象版本 ID；未版本化对象使用 null 字符串"

      add :event_name, :string,
        null: false,
        comment: "触发复制的 S3 数据面事件，例如 s3:ObjectCreated:Put"

      add :destination_bucket, :string,
        null: false,
        comment: "目标 bucket 名称；由 ReplicationConfiguration Destination.Bucket ARN 解析得到"

      add :rule_id, :string, comment: "匹配的 replication rule ID；规则未提供 ID 时为 NULL"

      add :destination_storage_class, :string, comment: "目标对象存储类型覆盖；为 NULL 时继承源对象 storage_class"

      add :source_etag, :string, comment: "源对象提交时的 ETag；delete marker 任务为空"
      add :source_size, :bigint, comment: "源对象提交时的可见字节数；delete marker 任务为空"

      add :status, :string,
        null: false,
        default: "pending",
        comment: "任务状态：pending/delivering/completed/failed；failed 到期后可重试"

      add :attempts, :integer,
        null: false,
        default: 0,
        comment: "已开始的复制尝试次数；claim 时递增"

      add :next_attempt_at, :utc_datetime_usec,
        null: false,
        comment: "下一次允许尝试复制的时间；失败退避与 delivering lease 均写入此字段"

      add :last_attempted_at, :utc_datetime_usec, comment: "最近一次复制尝试开始时间"
      add :completed_at, :utc_datetime_usec, comment: "复制成功完成时间"

      add :error_reason, :string, comment: "最近一次复制失败原因摘要；不保存对象字节、secret 或外部响应正文"

      add :payload, :map,
        null: false,
        comment: "复制任务快照；包含源对象、目标、规则与事件上下文，便于幂等重试"

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(
             :s3_replication_outbox,
             [:source_bucket, :source_key, :source_version_id, :destination_bucket, :event_name],
             name: :s3_replication_outbox_unique_task_index,
             comment: "同一源版本、目标 bucket 与事件只保留一个复制任务，保证 enqueue 幂等"
           )

    create index(:s3_replication_outbox, [:status, :next_attempt_at],
             name: :s3_replication_outbox_status_next_attempt_at_index,
             comment: "按状态与下一次尝试时间扫描可执行复制任务"
           )

    create index(:s3_replication_outbox, [:source_bucket, :source_key, :source_version_id],
             name: :s3_replication_outbox_source_version_index,
             comment: "按源对象版本查询复制任务，用于更新源对象复制状态"
           )

    create index(:s3_replication_outbox, [:destination_bucket],
             name: :s3_replication_outbox_destination_bucket_index,
             comment: "按目标 bucket 查询复制任务积压"
           )

    execute("COMMENT ON COLUMN s3_replication_outbox.inserted_at IS 'replication outbox 任务创建时间'")
    execute("COMMENT ON COLUMN s3_replication_outbox.updated_at IS 'replication outbox 任务最后更新时间'")
  end

  def down do
    execute("COMMENT ON COLUMN s3_replication_outbox.updated_at IS NULL")
    execute("COMMENT ON COLUMN s3_replication_outbox.inserted_at IS NULL")

    drop_if_exists index(:s3_replication_outbox, [:destination_bucket],
                     name: :s3_replication_outbox_destination_bucket_index
                   )

    drop_if_exists index(
                     :s3_replication_outbox,
                     [:source_bucket, :source_key, :source_version_id],
                     name: :s3_replication_outbox_source_version_index
                   )

    drop_if_exists index(:s3_replication_outbox, [:status, :next_attempt_at],
                     name: :s3_replication_outbox_status_next_attempt_at_index
                   )

    drop_if_exists index(
                     :s3_replication_outbox,
                     [
                       :source_bucket,
                       :source_key,
                       :source_version_id,
                       :destination_bucket,
                       :event_name
                     ],
                     name: :s3_replication_outbox_unique_task_index
                   )

    drop table(:s3_replication_outbox)

    alter table(:objects) do
      remove :replication_status
    end
  end
end
