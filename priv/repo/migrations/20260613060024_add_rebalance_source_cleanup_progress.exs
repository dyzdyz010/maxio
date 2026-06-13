defmodule Maxio.Repo.Migrations.AddRebalanceSourceCleanupProgress do
  use Ecto.Migration

  def up do
    alter table(:cluster_rebalance_jobs) do
      add :source_cleanup_cursor_bucket, :string,
        comment: "源 set 清理 ListObjectVersions 恢复用 bucket 游标；NULL 表示从首桶开始或已完成"

      add :source_cleanup_cursor_key_marker, :string,
        comment: "源 set 清理 ListObjectVersions 恢复用 key-marker 游标"

      add :source_cleanup_cursor_version_id_marker, :string,
        comment: "源 set 清理 ListObjectVersions 恢复用 version-id-marker 游标"

      add :source_cleanup_scanned, :bigint,
        null: false,
        default: 0,
        comment: "源 set 清理已检查的对象版本或 delete marker 行数"

      add :source_cleanup_deleted, :bigint,
        null: false,
        default: 0,
        comment: "源 set 清理已成功调用权威 delete_version 删除的旧副本版本数"

      add :source_cleanup_skipped, :bigint,
        null: false,
        default: 0,
        comment: "源 set 清理因 PG placement 不满足清理条件而跳过的版本数"

      add :source_cleanup_errors, :bigint,
        null: false,
        default: 0,
        comment: "源 set 清理遇到的 fail-closed 错误数；非零批次不会标记 complete"
    end

    execute(
      "COMMENT ON COLUMN cluster_rebalance_jobs.source_cleanup_status IS '源 shard 清理状态：not_started/moving/complete/failed/skipped；只清理 PG 已切到 destination_set_id 的旧 source set 副本'"
    )
  end

  def down do
    execute("COMMENT ON COLUMN cluster_rebalance_jobs.source_cleanup_errors IS NULL")
    execute("COMMENT ON COLUMN cluster_rebalance_jobs.source_cleanup_skipped IS NULL")
    execute("COMMENT ON COLUMN cluster_rebalance_jobs.source_cleanup_deleted IS NULL")
    execute("COMMENT ON COLUMN cluster_rebalance_jobs.source_cleanup_scanned IS NULL")

    execute(
      "COMMENT ON COLUMN cluster_rebalance_jobs.source_cleanup_cursor_version_id_marker IS NULL"
    )

    execute("COMMENT ON COLUMN cluster_rebalance_jobs.source_cleanup_cursor_key_marker IS NULL")
    execute("COMMENT ON COLUMN cluster_rebalance_jobs.source_cleanup_cursor_bucket IS NULL")

    execute(
      "COMMENT ON COLUMN cluster_rebalance_jobs.source_cleanup_status IS '源 shard 清理状态；当前 copy-pass 固定 not_started，不删除源 shard'"
    )

    alter table(:cluster_rebalance_jobs) do
      remove :source_cleanup_errors
      remove :source_cleanup_skipped
      remove :source_cleanup_deleted
      remove :source_cleanup_scanned
      remove :source_cleanup_cursor_version_id_marker
      remove :source_cleanup_cursor_key_marker
      remove :source_cleanup_cursor_bucket
    end
  end
end
