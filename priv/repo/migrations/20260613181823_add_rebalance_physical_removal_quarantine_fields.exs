defmodule Maxio.Repo.Migrations.AddRebalancePhysicalRemovalQuarantineFields do
  use Ecto.Migration

  def up do
    alter table(:cluster_rebalance_jobs) do
      add :physical_removal_status, :string,
        null: false,
        default: "not_started",
        comment:
          "物理移除阶段状态：not_started/quarantining/quarantined/failed；仅表示已处理已验证移除端点上的 Maxio 布局，不表示硬件已下架或磁盘已擦除"

      add :physical_removal_scope, :string,
        null: false,
        default: "none",
        comment: "物理移除执行范围：none/layout_quarantine；首个实现只隔离 Maxio 布局根，禁止删除整盘根目录"

      add :physical_removal_quarantine_id, :string,
        comment: "物理移除隔离批次 UUID；用于端点内 .maxio-removal-quarantine/<id> 的幂等续跑和审计"

      add :physical_removal_manifest_hash, :string,
        comment:
          "执行时绑定的 topology_removal_target_endpoints、removed_pool_ids 与 proposed topology hash 摘要；重试必须一致，禁止从当前拓扑反推"

      add :physical_removal_preflight_verified_at, :utc_datetime_usec,
        comment: "物理移除执行前最近一次通过强安全门的 preflight 时间"

      add :physical_removal_started_at, :utc_datetime_usec, comment: "物理移除进入 quarantining 状态的时间"

      add :physical_removal_completed_at, :utc_datetime_usec,
        comment: "物理移除成功完成并进入 quarantined 状态的时间"

      add :physical_removal_results, :map,
        null: false,
        default: %{},
        comment: "物理移除每个 endpoint 的隔离结果、marker 路径、移动 roots 与错误摘要 JSON，用于审计和幂等恢复"

      add :physical_removal_roots_quarantined, :bigint,
        null: false,
        default: 0,
        comment: "物理移除已隔离的 Maxio 布局根数量"

      add :physical_removal_markers_written, :bigint,
        null: false,
        default: 0,
        comment: "物理移除已写入 endpoint 移除 marker 的数量"

      add :physical_removal_errors, :bigint,
        null: false,
        default: 0,
        comment: "物理移除阶段记录的错误数量"

      add :physical_removal_error_reason, :string, comment: "物理移除失败时的结构化原因摘要"
    end
  end

  def down do
    execute("COMMENT ON COLUMN cluster_rebalance_jobs.physical_removal_error_reason IS NULL")
    execute("COMMENT ON COLUMN cluster_rebalance_jobs.physical_removal_errors IS NULL")
    execute("COMMENT ON COLUMN cluster_rebalance_jobs.physical_removal_markers_written IS NULL")
    execute("COMMENT ON COLUMN cluster_rebalance_jobs.physical_removal_roots_quarantined IS NULL")
    execute("COMMENT ON COLUMN cluster_rebalance_jobs.physical_removal_results IS NULL")
    execute("COMMENT ON COLUMN cluster_rebalance_jobs.physical_removal_completed_at IS NULL")
    execute("COMMENT ON COLUMN cluster_rebalance_jobs.physical_removal_started_at IS NULL")

    execute(
      "COMMENT ON COLUMN cluster_rebalance_jobs.physical_removal_preflight_verified_at IS NULL"
    )

    execute("COMMENT ON COLUMN cluster_rebalance_jobs.physical_removal_manifest_hash IS NULL")
    execute("COMMENT ON COLUMN cluster_rebalance_jobs.physical_removal_quarantine_id IS NULL")
    execute("COMMENT ON COLUMN cluster_rebalance_jobs.physical_removal_scope IS NULL")
    execute("COMMENT ON COLUMN cluster_rebalance_jobs.physical_removal_status IS NULL")

    alter table(:cluster_rebalance_jobs) do
      remove :physical_removal_error_reason
      remove :physical_removal_errors
      remove :physical_removal_markers_written
      remove :physical_removal_roots_quarantined
      remove :physical_removal_results
      remove :physical_removal_completed_at
      remove :physical_removal_started_at
      remove :physical_removal_preflight_verified_at
      remove :physical_removal_manifest_hash
      remove :physical_removal_quarantine_id
      remove :physical_removal_scope
      remove :physical_removal_status
    end
  end
end
