defmodule Maxio.Repo.Migrations.AddRebalancePhysicalRemovalPurgeFields do
  use Ecto.Migration

  def up do
    alter table(:cluster_rebalance_jobs) do
      add :physical_removal_purge_status, :string,
        null: false,
        default: "not_started",
        comment:
          "物理移除隔离区清理状态：not_started/purging/purged/failed；仅表示 .maxio-removal-quarantine/<id> 已清理，不表示硬件已下架或磁盘已擦除"

      add :physical_removal_purge_scope, :string,
        null: false,
        default: "none",
        comment: "物理移除隔离区清理范围：none/quarantine_hard_delete；只允许删除同盘 quarantine root，禁止删除整盘根目录"

      add :physical_removal_purge_quarantine_id, :string,
        comment: "物理移除隔离区清理绑定的 quarantine id；必须等于 physical_removal_quarantine_id"

      add :physical_removal_purge_manifest_hash, :string,
        comment: "物理移除隔离区清理绑定的 manifest hash；必须等于 physical_removal_manifest_hash"

      add :physical_removal_purge_retention_seconds, :bigint,
        null: false,
        default: 0,
        comment: "物理移除隔离区清理要求的保留秒数；用于从 quarantine completed_at 计算 eligible_at"

      add :physical_removal_purge_retention_until, :utc_datetime_usec,
        comment: "物理移除隔离区允许清理的最早时间，由 quarantine 完成时间加 operator 指定保留期计算"

      add :physical_removal_purge_preflight_verified_at, :utc_datetime_usec,
        comment: "物理移除隔离区清理执行前最近一次通过强安全门的 preflight 时间"

      add :physical_removal_purge_started_at, :utc_datetime_usec,
        comment: "物理移除隔离区清理进入 purging 状态的时间"

      add :physical_removal_purge_completed_at, :utc_datetime_usec,
        comment: "物理移除隔离区清理成功完成并进入 purged 状态的时间"

      add :physical_removal_purge_results, :map,
        null: false,
        default: %{},
        comment: "物理移除隔离区清理每个 endpoint 的清理结果、marker 路径、删除 root 与错误摘要 JSON"

      add :physical_removal_purge_roots_deleted, :bigint,
        null: false,
        default: 0,
        comment: "物理移除隔离区清理已删除的 quarantine root 数量"

      add :physical_removal_purge_files_deleted, :bigint,
        null: false,
        default: 0,
        comment: "物理移除隔离区清理已删除的文件数量（best-effort 审计计数）"

      add :physical_removal_purge_dirs_deleted, :bigint,
        null: false,
        default: 0,
        comment: "物理移除隔离区清理已删除的目录数量（best-effort 审计计数）"

      add :physical_removal_purge_bytes_deleted, :bigint,
        null: false,
        default: 0,
        comment: "物理移除隔离区清理已删除的字节数量（删除前 lstat 汇总的 best-effort 审计计数）"

      add :physical_removal_purge_markers_written, :bigint,
        null: false,
        default: 0,
        comment: "物理移除隔离区清理已更新 endpoint 物理移除 marker 的数量"

      add :physical_removal_purge_errors, :bigint,
        null: false,
        default: 0,
        comment: "物理移除隔离区清理阶段记录的错误数量"

      add :physical_removal_purge_error_reason, :string, comment: "物理移除隔离区清理失败时的结构化原因摘要"
    end
  end

  def down do
    execute(
      "COMMENT ON COLUMN cluster_rebalance_jobs.physical_removal_purge_error_reason IS NULL"
    )

    execute("COMMENT ON COLUMN cluster_rebalance_jobs.physical_removal_purge_errors IS NULL")

    execute(
      "COMMENT ON COLUMN cluster_rebalance_jobs.physical_removal_purge_markers_written IS NULL"
    )

    execute(
      "COMMENT ON COLUMN cluster_rebalance_jobs.physical_removal_purge_bytes_deleted IS NULL"
    )

    execute(
      "COMMENT ON COLUMN cluster_rebalance_jobs.physical_removal_purge_dirs_deleted IS NULL"
    )

    execute(
      "COMMENT ON COLUMN cluster_rebalance_jobs.physical_removal_purge_files_deleted IS NULL"
    )

    execute(
      "COMMENT ON COLUMN cluster_rebalance_jobs.physical_removal_purge_roots_deleted IS NULL"
    )

    execute("COMMENT ON COLUMN cluster_rebalance_jobs.physical_removal_purge_results IS NULL")

    execute(
      "COMMENT ON COLUMN cluster_rebalance_jobs.physical_removal_purge_completed_at IS NULL"
    )

    execute("COMMENT ON COLUMN cluster_rebalance_jobs.physical_removal_purge_started_at IS NULL")

    execute(
      "COMMENT ON COLUMN cluster_rebalance_jobs.physical_removal_purge_preflight_verified_at IS NULL"
    )

    execute(
      "COMMENT ON COLUMN cluster_rebalance_jobs.physical_removal_purge_retention_until IS NULL"
    )

    execute(
      "COMMENT ON COLUMN cluster_rebalance_jobs.physical_removal_purge_retention_seconds IS NULL"
    )

    execute(
      "COMMENT ON COLUMN cluster_rebalance_jobs.physical_removal_purge_manifest_hash IS NULL"
    )

    execute(
      "COMMENT ON COLUMN cluster_rebalance_jobs.physical_removal_purge_quarantine_id IS NULL"
    )

    execute("COMMENT ON COLUMN cluster_rebalance_jobs.physical_removal_purge_scope IS NULL")

    execute("COMMENT ON COLUMN cluster_rebalance_jobs.physical_removal_purge_status IS NULL")

    alter table(:cluster_rebalance_jobs) do
      remove :physical_removal_purge_error_reason
      remove :physical_removal_purge_errors
      remove :physical_removal_purge_markers_written
      remove :physical_removal_purge_bytes_deleted
      remove :physical_removal_purge_dirs_deleted
      remove :physical_removal_purge_files_deleted
      remove :physical_removal_purge_roots_deleted
      remove :physical_removal_purge_results
      remove :physical_removal_purge_completed_at
      remove :physical_removal_purge_started_at
      remove :physical_removal_purge_preflight_verified_at
      remove :physical_removal_purge_retention_until
      remove :physical_removal_purge_retention_seconds
      remove :physical_removal_purge_manifest_hash
      remove :physical_removal_purge_quarantine_id
      remove :physical_removal_purge_scope
      remove :physical_removal_purge_status
    end
  end
end
