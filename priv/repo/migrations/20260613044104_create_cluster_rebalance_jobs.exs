defmodule Maxio.Repo.Migrations.CreateClusterRebalanceJobs do
  use Ecto.Migration

  def up do
    create table(:cluster_rebalance_jobs,
             primary_key: false,
             comment: "集群 rebalance/decommission 运维任务控制面状态"
           ) do
      add :id, :binary_id, primary_key: true, comment: "任务 UUID 主键"
      add :kind, :string, null: false, comment: "任务类型：rebalance 或 decommission"

      add :status, :string,
        null: false,
        default: "planned",
        comment:
          "任务状态：planned/running/cancel_requested/complete/failed/canceled；planned 表示已持久化计划但尚未搬迁数据"

      add :data_movement_status, :string,
        null: false,
        default: "not_started",
        comment: "数据迁移阶段状态；当前控制面切片固定为 not_started，不伪装已搬迁"

      add :target_set_id, :integer, comment: "decommission 目标 erasure set id；rebalance 为空"
      add :current_only, :boolean, null: false, default: false, comment: "计划是否只扫描当前版本"

      add :include_drive_stats, :boolean,
        null: false,
        default: true,
        comment: "计划快照是否包含 drive filesystem stats"

      add :page_size, :integer, null: false, default: 500, comment: "生成计划时使用的 PG inventory 分页大小"
      add :plan_status, :string, null: false, comment: "计划生成结果状态，如 ok/partial"
      add :plan, :map, null: false, comment: "创建任务时的 rebalance/decommission 计划快照 JSON"
      add :plan_scanned, :bigint, null: false, default: 0, comment: "计划快照扫描的对象版本/marker 行数"
      add :plan_bytes, :bigint, null: false, default: 0, comment: "计划快照估算的 logical object bytes"

      add :plan_placement_fallbacks, :bigint,
        null: false,
        default: 0,
        comment: "计划快照中缺少持久化 placement 而回退当前路由的行数"

      add :cursor_bucket, :string, comment: "后续搬迁 worker 恢复扫描用的 bucket 游标"
      add :cursor_key_marker, :string, comment: "后续搬迁 worker 恢复 ListObjectVersions 用的 key-marker"

      add :cursor_version_id_marker, :string,
        comment: "后续搬迁 worker 恢复 ListObjectVersions 用的 version-id-marker"

      add :progress_scanned, :bigint,
        null: false,
        default: 0,
        comment: "后续搬迁 worker 已处理的版本/marker 行数"

      add :progress_moved, :bigint, null: false, default: 0, comment: "后续搬迁 worker 已成功迁移的对象版本数"
      add :progress_skipped, :bigint, null: false, default: 0, comment: "后续搬迁 worker 跳过的对象版本数"
      add :progress_errors, :bigint, null: false, default: 0, comment: "后续搬迁 worker 记录的错误数"
      add :cancel_requested_at, :utc_datetime_usec, comment: "操作者请求取消任务的时间"
      add :started_at, :utc_datetime_usec, comment: "任务进入控制面 active 状态的时间"
      add :finished_at, :utc_datetime_usec, comment: "任务终止、完成或失败的时间"
      add :error_reason, :string, comment: "任务失败或被拒绝时的结构化原因摘要"
      add :requested_by, :string, comment: "创建任务的操作者或入口标识"

      timestamps(type: :utc_datetime_usec)
    end

    create index(:cluster_rebalance_jobs, [:kind, :status],
             name: :cluster_rebalance_jobs_kind_status_index
           )

    create index(:cluster_rebalance_jobs, [:target_set_id],
             name: :cluster_rebalance_jobs_target_set_index
           )

    create index(:cluster_rebalance_jobs, [:inserted_at],
             name: :cluster_rebalance_jobs_inserted_at_index
           )

    execute("""
    CREATE UNIQUE INDEX cluster_rebalance_jobs_active_singleton_index
      ON cluster_rebalance_jobs ((true))
      WHERE status IN ('planned', 'running', 'cancel_requested')
    """)

    execute(
      "COMMENT ON INDEX cluster_rebalance_jobs_kind_status_index IS '按任务类型与状态查询 rebalance/decommission job'"
    )

    execute(
      "COMMENT ON INDEX cluster_rebalance_jobs_target_set_index IS '按 decommission 目标 erasure set 查询任务'"
    )

    execute(
      "COMMENT ON INDEX cluster_rebalance_jobs_inserted_at_index IS '按任务创建时间排序显示 status 列表'"
    )

    execute(
      "COMMENT ON INDEX cluster_rebalance_jobs_active_singleton_index IS '集群级维护任务单飞闸：planned/running 同时最多一个，避免并发迁移冲突'"
    )

    execute("COMMENT ON COLUMN cluster_rebalance_jobs.inserted_at IS '任务记录创建时间'")
    execute("COMMENT ON COLUMN cluster_rebalance_jobs.updated_at IS '任务记录最后更新时间'")
  end

  def down do
    execute("COMMENT ON COLUMN cluster_rebalance_jobs.updated_at IS NULL")
    execute("COMMENT ON COLUMN cluster_rebalance_jobs.inserted_at IS NULL")
    execute("COMMENT ON INDEX cluster_rebalance_jobs_active_singleton_index IS NULL")
    execute("COMMENT ON INDEX cluster_rebalance_jobs_inserted_at_index IS NULL")
    execute("COMMENT ON INDEX cluster_rebalance_jobs_target_set_index IS NULL")
    execute("COMMENT ON INDEX cluster_rebalance_jobs_kind_status_index IS NULL")

    execute("DROP INDEX IF EXISTS cluster_rebalance_jobs_active_singleton_index")

    drop_if_exists index(:cluster_rebalance_jobs, [:inserted_at],
                     name: :cluster_rebalance_jobs_inserted_at_index
                   )

    drop_if_exists index(:cluster_rebalance_jobs, [:target_set_id],
                     name: :cluster_rebalance_jobs_target_set_index
                   )

    drop_if_exists index(:cluster_rebalance_jobs, [:kind, :status],
                     name: :cluster_rebalance_jobs_kind_status_index
                   )

    drop table(:cluster_rebalance_jobs)
  end
end
