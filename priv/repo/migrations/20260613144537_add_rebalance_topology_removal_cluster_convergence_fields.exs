defmodule Maxio.Repo.Migrations.AddRebalanceTopologyRemovalClusterConvergenceFields do
  use Ecto.Migration

  def up do
    alter table(:cluster_rebalance_jobs) do
      add :topology_removal_cluster_status, :string,
        null: false,
        default: "not_started",
        comment:
          "集群运行时拓扑收敛状态：not_started/runtime_converged/failed；仅表示参与节点 runtime topology 已安装 proposed hash"

      add :topology_removal_cluster_hash, :string,
        comment: "集群运行时收敛核验通过的 topology hash，必须等于 topology_removal_proposed_hash"

      add :topology_removal_cluster_nodes, {:array, :string},
        null: false,
        default: [],
        comment: "集群运行时拓扑收敛覆盖的 BEAM 节点名列表"

      add :topology_removal_cluster_verified_at, :utc_datetime_usec,
        comment: "operator 核验所有参与节点 runtime topology 收敛到 proposed hash 的时间"
    end
  end

  def down do
    execute(
      "COMMENT ON COLUMN cluster_rebalance_jobs.topology_removal_cluster_verified_at IS NULL"
    )

    execute("COMMENT ON COLUMN cluster_rebalance_jobs.topology_removal_cluster_nodes IS NULL")
    execute("COMMENT ON COLUMN cluster_rebalance_jobs.topology_removal_cluster_hash IS NULL")
    execute("COMMENT ON COLUMN cluster_rebalance_jobs.topology_removal_cluster_status IS NULL")

    alter table(:cluster_rebalance_jobs) do
      remove :topology_removal_cluster_verified_at
      remove :topology_removal_cluster_nodes
      remove :topology_removal_cluster_hash
      remove :topology_removal_cluster_status
    end
  end
end
