defmodule Maxio.Repo.Migrations.CreateClusterSchedulerStates do
  use Ecto.Migration

  def up do
    create table(:cluster_scheduler_states,
             primary_key: false,
             comment: "集群后台调度器的可重启有效健康状态行；保存最近有效运行、连续失败、退避窗口与告警状态"
           ) do
      add :id, :binary_id, primary_key: true, comment: "调度器状态 UUID 主键"

      add :scheduler, :string,
        null: false,
        comment: "调度器名称：fresh_drive_heal 或 rebalance；每个调度器最多一行"

      add :node, :string, comment: "最近一次写入有效健康状态的 BEAM 节点名"

      add :status, :string,
        null: false,
        default: "idle",
        comment: "当前有效健康状态分类：ok/idle/skipped/blocked/failed；已有状态时锁竞争或退避跳过不覆盖本字段"

      add :consecutive_failures, :integer,
        null: false,
        default: 0,
        comment: "当前有效健康状态的连续 blocked/failed 次数；ok/idle 会清零，锁竞争或退避跳过不清零"

      add :last_run_id, :binary_id, comment: "最近一次写入有效健康状态的 cluster_scheduler_runs 记录 id"

      add :last_started_at, :utc_datetime_usec, comment: "最近一次有效健康状态对应的调度开始时间"
      add :last_finished_at, :utc_datetime_usec, comment: "最近一次有效健康状态对应的调度结束时间"

      add :backoff_until, :utc_datetime_usec, comment: "自动调度退避截止时间；未处于退避窗口时为 NULL"

      add :alert_status, :string,
        null: false,
        default: "ok",
        comment: "当前告警状态：ok/warning/alert"

      add :alerted_at, :utc_datetime_usec, comment: "最近一次进入 alert 状态并尝试发出告警的时间"

      add :last_error_reason, :string, comment: "最近一次有效 blocked/failed/skipped 状态的结构化原因摘要"

      add :last_summary, :map,
        null: false,
        default: %{},
        comment: "最近一次有效健康状态的裁剪后 JSON 摘要；用于 CLI 状态页快速取证"

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:cluster_scheduler_states, [:scheduler],
             name: :cluster_scheduler_states_scheduler_index,
             comment: "调度器名称唯一索引；每个后台调度器一行可重启状态"
           )

    create index(:cluster_scheduler_states, [:alert_status],
             name: :cluster_scheduler_states_alert_status_index,
             comment: "按告警状态查询当前处于 warning/alert 的调度器"
           )

    execute("COMMENT ON COLUMN cluster_scheduler_states.inserted_at IS '调度器状态记录创建时间'")
    execute("COMMENT ON COLUMN cluster_scheduler_states.updated_at IS '调度器状态记录最后更新时间'")
  end

  def down do
    execute("COMMENT ON COLUMN cluster_scheduler_states.updated_at IS NULL")
    execute("COMMENT ON COLUMN cluster_scheduler_states.inserted_at IS NULL")

    drop_if_exists index(:cluster_scheduler_states, [:alert_status],
                     name: :cluster_scheduler_states_alert_status_index
                   )

    drop_if_exists unique_index(:cluster_scheduler_states, [:scheduler],
                     name: :cluster_scheduler_states_scheduler_index
                   )

    drop table(:cluster_scheduler_states)
  end
end
