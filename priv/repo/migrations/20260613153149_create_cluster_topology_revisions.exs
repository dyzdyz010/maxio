defmodule Maxio.Repo.Migrations.CreateClusterTopologyRevisions do
  use Ecto.Migration

  def up do
    create table(:cluster_topology_revisions,
             primary_key: false,
             comment: "集群部署拓扑的持久化版本链；active 版本是可重启恢复的部署事实来源"
           ) do
      add :id, :binary_id, primary_key: true, comment: "拓扑版本 UUID 主键"

      add :status, :string,
        null: false,
        default: "active",
        comment: "拓扑版本状态：active 表示当前部署版本；superseded 表示已被后续版本替代"

      add :topology_hash, :string,
        null: false,
        comment: "Topology.fingerprint/1 生成的完整拓扑 SHA256 指纹，包含 pool/set/endpoint 顺序"

      add :config, :map,
        null: false,
        comment: "JSON 安全的拓扑配置快照；节点以字符串保存，加载时只允许转换为既有 atom"

      add :source, :string,
        null: false,
        default: "operator",
        comment: "写入来源：operator/decommission_removal 等，用于审计部署拓扑变更入口"

      add :source_job_id,
          references(:cluster_rebalance_jobs, type: :binary_id, on_delete: :nilify_all),
          comment: "产生该拓扑版本的 rebalance/decommission job；手工导入时可为空"

      add :activated_at, :utc_datetime_usec,
        null: false,
        comment: "该版本成为 active 部署拓扑的时间"

      timestamps(type: :utc_datetime_usec)
    end

    create index(:cluster_topology_revisions, [:topology_hash],
             name: :cluster_topology_revisions_hash_index
           )

    create index(:cluster_topology_revisions, [:source_job_id],
             name: :cluster_topology_revisions_source_job_index
           )

    execute("""
    CREATE UNIQUE INDEX cluster_topology_revisions_active_index
      ON cluster_topology_revisions ((true))
      WHERE status = 'active'
    """)

    execute("COMMENT ON INDEX cluster_topology_revisions_hash_index IS '按完整拓扑 hash 查询部署拓扑版本'")

    execute(
      "COMMENT ON INDEX cluster_topology_revisions_source_job_index IS '按来源 job 追踪 decommission 拓扑持久化结果'"
    )

    execute(
      "COMMENT ON INDEX cluster_topology_revisions_active_index IS '部署拓扑 active 版本单飞约束：任意时刻最多一个 active 版本'"
    )

    execute("COMMENT ON COLUMN cluster_topology_revisions.inserted_at IS '拓扑版本记录创建时间'")
    execute("COMMENT ON COLUMN cluster_topology_revisions.updated_at IS '拓扑版本记录最后更新时间'")
  end

  def down do
    execute("COMMENT ON COLUMN cluster_topology_revisions.updated_at IS NULL")
    execute("COMMENT ON COLUMN cluster_topology_revisions.inserted_at IS NULL")
    execute("COMMENT ON INDEX cluster_topology_revisions_active_index IS NULL")
    execute("COMMENT ON INDEX cluster_topology_revisions_source_job_index IS NULL")
    execute("COMMENT ON INDEX cluster_topology_revisions_hash_index IS NULL")

    execute("DROP INDEX IF EXISTS cluster_topology_revisions_active_index")

    drop_if_exists index(:cluster_topology_revisions, [:source_job_id],
                     name: :cluster_topology_revisions_source_job_index
                   )

    drop_if_exists index(:cluster_topology_revisions, [:topology_hash],
                     name: :cluster_topology_revisions_hash_index
                   )

    drop table(:cluster_topology_revisions)
  end
end
