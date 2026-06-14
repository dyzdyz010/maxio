defmodule Maxio.Repo.Migrations.AddRebalancePhysicalRemovalManifestFields do
  use Ecto.Migration

  def up do
    alter table(:cluster_rebalance_jobs) do
      add :topology_removal_target_endpoints, :map,
        null: false,
        default: %{},
        comment:
          "拓扑移除前捕获的目标 set 端点清单；用于 deployment verified 后继续定位已移除 set 的物理 drive root，禁止从当前拓扑反推"

      add :topology_removal_removed_pool_ids, {:array, :integer},
        null: false,
        default: [],
        comment: "拓扑移除计划中随目标 set 一并从部署拓扑移除的 pool id 列表；仅审计物理移除候选，不表示已删除目录"
    end
  end

  def down do
    execute("COMMENT ON COLUMN cluster_rebalance_jobs.topology_removal_removed_pool_ids IS NULL")
    execute("COMMENT ON COLUMN cluster_rebalance_jobs.topology_removal_target_endpoints IS NULL")

    alter table(:cluster_rebalance_jobs) do
      remove :topology_removal_removed_pool_ids
      remove :topology_removal_target_endpoints
    end
  end
end
