defmodule Maxio.Repo.Migrations.CreateClusterSchedulerRunRollups do
  use Ecto.Migration

  def up do
    create table(:cluster_scheduler_run_rollups,
             primary_key: false,
             comment: "集群后台调度器运行账本的持久聚合窗口；用于未来清理明细 run 前保留可审计摘要，本表不代表已执行 prune"
           ) do
      add :id, :binary_id, primary_key: true, comment: "调度运行聚合窗口 UUID 主键"

      add :scheduler, :string,
        null: false,
        comment: "调度器名称：fresh_drive_heal 或 rebalance"

      add :trigger, :string,
        null: false,
        comment: "触发来源：manual 或 scheduled；rollup 按触发来源分开聚合"

      add :window_started_at, :utc_datetime_usec,
        null: false,
        comment: "聚合窗口开始时间（含），按 Unix epoch 与 window_ms 对 finished_at 取整"

      add :window_finished_at, :utc_datetime_usec,
        null: false,
        comment: "聚合窗口结束时间（不含）；默认只聚合已关闭窗口"

      add :window_ms, :bigint,
        null: false,
        comment: "聚合窗口长度毫秒数"

      add :run_count, :integer,
        null: false,
        default: 0,
        comment: "本窗口纳入聚合的 cluster_scheduler_runs 明细行数；空窗口为 0"

      add :ok_count, :integer, null: false, default: 0, comment: "本窗口 status=ok 的运行数"
      add :idle_count, :integer, null: false, default: 0, comment: "本窗口 status=idle 的运行数"
      add :skipped_count, :integer, null: false, default: 0, comment: "本窗口 status=skipped 的运行数"
      add :blocked_count, :integer, null: false, default: 0, comment: "本窗口 status=blocked 的运行数"
      add :failed_count, :integer, null: false, default: 0, comment: "本窗口 status=failed 的运行数"

      add :effective_count, :integer,
        null: false,
        default: 0,
        comment: "本窗口非 skipped 的运行数；scheduled cadence 中 skipped 不能证明有效心跳"

      add :healthy_count, :integer,
        null: false,
        default: 0,
        comment: "本窗口 status=ok 或 idle 的运行数；不代表当前调度器健康状态"

      add :result_ok_count, :integer,
        null: false,
        default: 0,
        comment: "本窗口 result_kind=ok 的运行数"

      add :result_error_count, :integer,
        null: false,
        default: 0,
        comment: "本窗口 result_kind=error 的运行数"

      add :duration_total_ms, :bigint,
        null: false,
        default: 0,
        comment: "本窗口所有明细运行 duration_ms 之和"

      add :duration_min_ms, :bigint, comment: "本窗口最短单次明细运行 duration_ms；空窗口为 NULL"
      add :duration_max_ms, :bigint, comment: "本窗口最长单次明细运行 duration_ms；空窗口为 NULL"

      add :first_run_id, :binary_id, comment: "本窗口最早明细运行 UUID；不设 FK，保证未来 prune 明细后 rollup 仍保留"

      add :last_run_id, :binary_id, comment: "本窗口最后明细运行 UUID；不设 FK，保证未来 prune 明细后 rollup 仍保留"

      add :last_status, :string, comment: "本窗口最后明细运行的 status"
      add :last_result_kind, :string, comment: "本窗口最后明细运行的 result_kind"
      add :last_phase, :string, comment: "本窗口最后明细运行的 phase"
      add :last_job_id, :string, comment: "本窗口最后明细运行关联的 rebalance/decommission job id"
      add :last_finished_at, :utc_datetime_usec, comment: "本窗口最后明细运行的 finished_at"

      add :last_effective_run_id, :binary_id,
        comment: "本窗口最后一个非 skipped 明细运行 UUID；空窗口或全 skipped 为 NULL"

      add :last_effective_status, :string,
        comment: "本窗口最后一个非 skipped 明细运行 status；空窗口或全 skipped 为 NULL"

      add :last_effective_finished_at, :utc_datetime_usec,
        comment: "本窗口最后一个非 skipped 明细运行 finished_at"

      add :last_healthy_run_id, :binary_id, comment: "本窗口最后一个 ok/idle 明细运行 UUID；空窗口或无健康运行为 NULL"

      add :last_healthy_status, :string, comment: "本窗口最后一个 ok/idle 明细运行 status；空窗口或无健康运行为 NULL"

      add :last_healthy_finished_at, :utc_datetime_usec,
        comment: "本窗口最后一个 ok/idle 明细运行 finished_at"

      add :last_error_reason, :string, comment: "本窗口最后一个非空 error_reason 摘要"

      add :last_summary, :map,
        null: false,
        default: %{},
        comment: "本窗口最后一条明细运行的裁剪后 JSON 摘要；继续使用 run ledger 脱敏结果"

      add :source_max_updated_at, :utc_datetime_usec,
        comment: "本窗口源明细运行最大 updated_at；用于未来 prune 前复核 rollup 是否覆盖当前明细"

      add :source_digest, :string,
        null: false,
        comment: "本窗口源明细运行的确定性 SHA256 摘要；未来 prune 前必须复核一致"

      add :rolled_up_at, :utc_datetime_usec,
        null: false,
        comment: "本窗口最近一次聚合写入时间；重跑同窗口会覆盖"

      add :rollup_version, :integer,
        null: false,
        default: 1,
        comment: "rollup 契约版本；聚合算法变更时递增以避免旧窗口误用"

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(
             :cluster_scheduler_run_rollups,
             [:scheduler, :trigger, :window_started_at, :window_ms],
             name: :cluster_scheduler_run_rollups_scheduler_trigger_window_index,
             comment: "调度器、触发来源与窗口唯一索引；同一窗口可幂等重算覆盖"
           )

    create index(:cluster_scheduler_run_rollups, [:scheduler, :trigger, :window_finished_at],
             name: :cluster_scheduler_run_rollups_scheduler_trigger_finished_at_index,
             comment: "按调度器、触发来源与窗口结束时间查询最近聚合窗口"
           )

    create index(:cluster_scheduler_run_rollups, [:last_status],
             name: :cluster_scheduler_run_rollups_last_status_index,
             comment: "按窗口最后状态查询异常聚合窗口"
           )

    execute("COMMENT ON COLUMN cluster_scheduler_run_rollups.inserted_at IS '调度运行聚合窗口创建时间'")
    execute("COMMENT ON COLUMN cluster_scheduler_run_rollups.updated_at IS '调度运行聚合窗口最后更新时间'")
  end

  def down do
    execute("COMMENT ON COLUMN cluster_scheduler_run_rollups.updated_at IS NULL")
    execute("COMMENT ON COLUMN cluster_scheduler_run_rollups.inserted_at IS NULL")

    drop_if_exists index(:cluster_scheduler_run_rollups, [:last_status],
                     name: :cluster_scheduler_run_rollups_last_status_index
                   )

    drop_if_exists index(
                     :cluster_scheduler_run_rollups,
                     [:scheduler, :trigger, :window_finished_at],
                     name: :cluster_scheduler_run_rollups_scheduler_trigger_finished_at_index
                   )

    drop_if_exists unique_index(
                     :cluster_scheduler_run_rollups,
                     [:scheduler, :trigger, :window_started_at, :window_ms],
                     name: :cluster_scheduler_run_rollups_scheduler_trigger_window_index
                   )

    drop table(:cluster_scheduler_run_rollups)
  end
end
