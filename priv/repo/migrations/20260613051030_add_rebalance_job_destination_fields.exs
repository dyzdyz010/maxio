defmodule Maxio.Repo.Migrations.AddRebalanceJobDestinationFields do
  use Ecto.Migration

  def up do
    alter table(:cluster_rebalance_jobs) do
      add :destination_set_id, :integer,
        comment: "decommission copy-pass 的目标 erasure set id；nil 表示尚未绑定目的地"

      add :source_cleanup_status, :string,
        null: false,
        default: "not_started",
        comment: "源 shard 清理状态；当前 copy-pass 固定 not_started，不删除源 shard"
    end

    create index(:cluster_rebalance_jobs, [:destination_set_id],
             name: :cluster_rebalance_jobs_destination_set_index
           )

    execute(
      "COMMENT ON INDEX cluster_rebalance_jobs_destination_set_index IS '按 decommission copy-pass 目标 erasure set 查询任务'"
    )
  end

  def down do
    execute("COMMENT ON INDEX cluster_rebalance_jobs_destination_set_index IS NULL")
    execute("COMMENT ON COLUMN cluster_rebalance_jobs.source_cleanup_status IS NULL")
    execute("COMMENT ON COLUMN cluster_rebalance_jobs.destination_set_id IS NULL")

    drop_if_exists index(:cluster_rebalance_jobs, [:destination_set_id],
                     name: :cluster_rebalance_jobs_destination_set_index
                   )

    alter table(:cluster_rebalance_jobs) do
      remove :source_cleanup_status
      remove :destination_set_id
    end
  end
end
