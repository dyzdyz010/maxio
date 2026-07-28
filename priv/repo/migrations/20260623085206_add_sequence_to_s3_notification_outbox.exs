defmodule Maxio.Repo.Migrations.AddSequenceToS3NotificationOutbox do
  use Ecto.Migration

  def up do
    alter table(:s3_notification_outbox) do
      add :sequence, :bigserial,
        null: false,
        comment: "数据库持久递增 notification sequencer；用于 S3 事件 payload 中每对象排序提示，避免 BEAM 重启后回退"
    end

    create index(:s3_notification_outbox, [:bucket, :object_key, :sequence],
             name: :s3_notification_outbox_object_sequence_index,
             comment: "按对象 key 与持久 sequencer 查询 notification 事件顺序"
           )
  end

  def down do
    drop_if_exists index(:s3_notification_outbox, [:bucket, :object_key, :sequence],
                     name: :s3_notification_outbox_object_sequence_index
                   )

    alter table(:s3_notification_outbox) do
      remove :sequence
    end
  end
end
