defmodule Maxio.Repo.Migrations.AddRebalanceClosureAuditFields do
  use Ecto.Migration

  def up do
    alter table(:cluster_rebalance_jobs) do
      add :rebalance_closure_status, :string,
        null: false,
        default: "not_started",
        comment:
          "rebalance 逻辑闭环审计状态：not_started/checking/verified/blocked/failed；只记录 copy+cleanup 后的 PG/router placement 审计，不移动数据、不改拓扑"

      add :rebalance_closure_checked_at, :utc_datetime_usec,
        comment: "rebalance 逻辑闭环审计最近一次写入 job 审计结果的时间"

      add :rebalance_closure_verified_at, :utc_datetime_usec,
        comment: "rebalance 逻辑闭环审计最近一次通过并进入 verified 状态的时间"

      add :rebalance_closure_topology_hash, :string,
        comment: "rebalance 逻辑闭环审计使用的 runtime topology fingerprint；用于取证，不作为后续写路由来源"

      add :rebalance_closure_results, :map,
        null: false,
        default: %{},
        comment:
          "rebalance 逻辑闭环审计结果 JSON：object placement counters、MPU placement/hash 风险、examples 与 workflow 状态"

      add :rebalance_closure_blockers, {:array, :string},
        null: false,
        default: [],
        comment: "rebalance 逻辑闭环审计阻塞原因列表；非空时 closure_status=blocked，scheduler 可在 operator 修复后重试"

      add :rebalance_closure_error_reason, :string, comment: "rebalance 逻辑闭环审计执行失败时的结构化原因摘要"
    end
  end

  def down do
    execute("COMMENT ON COLUMN cluster_rebalance_jobs.rebalance_closure_error_reason IS NULL")
    execute("COMMENT ON COLUMN cluster_rebalance_jobs.rebalance_closure_blockers IS NULL")
    execute("COMMENT ON COLUMN cluster_rebalance_jobs.rebalance_closure_results IS NULL")
    execute("COMMENT ON COLUMN cluster_rebalance_jobs.rebalance_closure_topology_hash IS NULL")
    execute("COMMENT ON COLUMN cluster_rebalance_jobs.rebalance_closure_verified_at IS NULL")
    execute("COMMENT ON COLUMN cluster_rebalance_jobs.rebalance_closure_checked_at IS NULL")
    execute("COMMENT ON COLUMN cluster_rebalance_jobs.rebalance_closure_status IS NULL")

    alter table(:cluster_rebalance_jobs) do
      remove :rebalance_closure_error_reason
      remove :rebalance_closure_blockers
      remove :rebalance_closure_results
      remove :rebalance_closure_topology_hash
      remove :rebalance_closure_verified_at
      remove :rebalance_closure_checked_at
      remove :rebalance_closure_status
    end
  end
end
