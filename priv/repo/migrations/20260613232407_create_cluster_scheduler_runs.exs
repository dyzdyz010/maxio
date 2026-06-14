defmodule Maxio.Repo.Migrations.CreateClusterSchedulerRuns do
  use Ecto.Migration

  def up do
    create table(:cluster_scheduler_runs,
             primary_key: false,
             comment:
               "集群后台调度器每次运行一行的审计账本；用于重启后追踪 fresh-drive heal / rebalance 自动化结果、失败与退避证据，告警发送失败可注记本次摘要"
           ) do
      add :id, :binary_id, primary_key: true, comment: "调度运行记录 UUID 主键"

      add :scheduler, :string,
        null: false,
        comment: "调度器名称：fresh_drive_heal 或 rebalance"

      add :trigger, :string,
        null: false,
        comment: "触发来源：manual 表示 run_now/CLI/IEx 手动触发；scheduled 表示后台周期触发"

      add :node, :string,
        null: false,
        comment: "记录本次调度结果的 BEAM 节点名，用于多节点 singleton cadence 取证"

      add :status, :string,
        null: false,
        comment: "调度结果分类：ok/idle/skipped/blocked/failed；blocked/failed 才计入连续失败"

      add :result_kind, :string,
        null: false,
        comment: "原始返回形态分类：ok 表示 {:ok, report}；error 表示 {:error, reason}"

      add :phase, :string,
        comment: "本次调度推进的阶段摘要，例如 copy/source_cleanup/rebalance_closure；无阶段则为 NULL"

      add :job_id, :string,
        comment: "本次调度涉及的 rebalance/decommission job id；fresh-drive 未创建 job 或无 job 时为 NULL"

      add :started_at, :utc_datetime_usec, null: false, comment: "本次调度开始时间"
      add :finished_at, :utc_datetime_usec, null: false, comment: "本次调度结束时间"

      add :duration_ms, :bigint,
        null: false,
        default: 0,
        comment: "本次调度耗时毫秒数；用于长期 cadence 与慢运行取证"

      add :consecutive_failures_after, :integer,
        null: false,
        default: 0,
        comment: "写入本记录后该调度器的连续 blocked/failed 次数"

      add :backoff_until, :utc_datetime_usec,
        comment: "连续失败达到阈值后计算出的自动调度退避截止时间；手动 run_now 不受此字段阻挡"

      add :alert_status, :string,
        null: false,
        default: "ok",
        comment: "调度告警状态：ok/warning/alert；alert 表示已达到配置的连续失败阈值"

      add :summary, :map,
        null: false,
        default: %{},
        comment: "裁剪后的调度结果 JSON 摘要；禁止保存对象数据、secret、raw serial/WWID 等敏感原文"

      add :error_reason, :string, comment: "失败、阻塞或跳过时的结构化原因摘要"

      timestamps(type: :utc_datetime_usec)
    end

    create index(:cluster_scheduler_runs, [:scheduler, :started_at],
             name: :cluster_scheduler_runs_scheduler_started_at_index,
             comment: "按调度器与开始时间查询最近运行记录"
           )

    create index(:cluster_scheduler_runs, [:job_id],
             name: :cluster_scheduler_runs_job_id_index,
             comment: "按关联 rebalance/decommission job 查询调度证据"
           )

    create index(:cluster_scheduler_runs, [:status],
             name: :cluster_scheduler_runs_status_index,
             comment: "按调度结果分类查询 blocked/failed/idle 等运行记录"
           )

    execute("COMMENT ON COLUMN cluster_scheduler_runs.inserted_at IS '调度运行记录创建时间'")
    execute("COMMENT ON COLUMN cluster_scheduler_runs.updated_at IS '调度运行记录最后更新时间'")
  end

  def down do
    execute("COMMENT ON COLUMN cluster_scheduler_runs.updated_at IS NULL")
    execute("COMMENT ON COLUMN cluster_scheduler_runs.inserted_at IS NULL")

    drop_if_exists index(:cluster_scheduler_runs, [:status],
                     name: :cluster_scheduler_runs_status_index
                   )

    drop_if_exists index(:cluster_scheduler_runs, [:job_id],
                     name: :cluster_scheduler_runs_job_id_index
                   )

    drop_if_exists index(:cluster_scheduler_runs, [:scheduler, :started_at],
                     name: :cluster_scheduler_runs_scheduler_started_at_index
                   )

    drop table(:cluster_scheduler_runs)
  end
end
