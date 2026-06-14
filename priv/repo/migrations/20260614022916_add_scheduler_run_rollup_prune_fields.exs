defmodule Maxio.Repo.Migrations.AddSchedulerRunRollupPruneFields do
  use Ecto.Migration

  def up do
    alter table(:cluster_scheduler_run_rollups) do
      add :pruned_at, :utc_datetime_usec, comment: "本聚合窗口对应明细运行记录被安全 prune 的时间；NULL 表示尚未执行 prune"

      add :pruned_run_count, :integer,
        null: false,
        default: 0,
        comment: "本聚合窗口已安全删除的 cluster_scheduler_runs 明细行数；必须由 prune 前 digest 复核后写入"

      add :pruned_source_digest, :string,
        comment: "执行 prune 时复核通过的源明细 digest；应等于 source_digest，用于证明删除动作绑定同一聚合证据"

      add :pruned_by_node, :string, comment: "执行 prune 的 BEAM 节点名；用于多节点运维审计"
    end
  end

  def down do
    alter table(:cluster_scheduler_run_rollups) do
      remove :pruned_by_node
      remove :pruned_source_digest
      remove :pruned_run_count
      remove :pruned_at
    end
  end
end
