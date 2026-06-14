defmodule Maxio.Repo.Migrations.AddRebalanceTopologyRemovalDeploymentVerificationFields do
  use Ecto.Migration

  def up do
    alter table(:cluster_rebalance_jobs) do
      add :topology_removal_deployment_status, :string,
        null: false,
        default: "not_started",
        comment:
          "部署拓扑移除核验状态：not_started/verified/failed；只有 verified 表示 deployment config 已持久化 target set 移除"

      add :topology_removal_deployment_hash, :string,
        comment: "核验通过的 deployment topology hash，必须等于 topology_removal_proposed_hash"

      add :topology_removal_deployment_verified_at, :utc_datetime_usec,
        comment: "operator 核验 deployment config 与 proposed topology 一致的时间"
    end
  end

  def down do
    execute(
      "COMMENT ON COLUMN cluster_rebalance_jobs.topology_removal_deployment_verified_at IS NULL"
    )

    execute("COMMENT ON COLUMN cluster_rebalance_jobs.topology_removal_deployment_hash IS NULL")
    execute("COMMENT ON COLUMN cluster_rebalance_jobs.topology_removal_deployment_status IS NULL")

    alter table(:cluster_rebalance_jobs) do
      remove :topology_removal_deployment_verified_at
      remove :topology_removal_deployment_hash
      remove :topology_removal_deployment_status
    end
  end
end
