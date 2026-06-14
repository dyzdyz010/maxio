defmodule Maxio.Repo.Migrations.AddRebalanceTopologyRemovalApplyFields do
  use Ecto.Migration

  def up do
    alter table(:cluster_rebalance_jobs) do
      add :topology_removal_status, :string,
        null: false,
        default: "not_started",
        comment: "拓扑移除应用状态：not_started/runtime_local_applied/failed；仅记录 operator 显式 runtime apply"

      add :topology_removal_scope, :string,
        null: false,
        default: "none",
        comment: "拓扑移除应用范围：none/runtime_local；不代表 deployment config 已持久化"

      add :topology_removal_current_hash, :string,
        comment: "执行拓扑移除前的当前 topology hash，用于审计 operator 应用的基线"

      add :topology_removal_proposed_hash, :string,
        comment: "执行拓扑移除后写入 runtime 的 proposed topology hash"

      add :topology_removal_applied_at, :utc_datetime_usec,
        comment: "operator 显式执行 runtime topology removal apply 的时间"
    end
  end

  def down do
    execute("COMMENT ON COLUMN cluster_rebalance_jobs.topology_removal_applied_at IS NULL")
    execute("COMMENT ON COLUMN cluster_rebalance_jobs.topology_removal_proposed_hash IS NULL")
    execute("COMMENT ON COLUMN cluster_rebalance_jobs.topology_removal_current_hash IS NULL")
    execute("COMMENT ON COLUMN cluster_rebalance_jobs.topology_removal_scope IS NULL")
    execute("COMMENT ON COLUMN cluster_rebalance_jobs.topology_removal_status IS NULL")

    alter table(:cluster_rebalance_jobs) do
      remove :topology_removal_applied_at
      remove :topology_removal_proposed_hash
      remove :topology_removal_current_hash
      remove :topology_removal_scope
      remove :topology_removal_status
    end
  end
end
