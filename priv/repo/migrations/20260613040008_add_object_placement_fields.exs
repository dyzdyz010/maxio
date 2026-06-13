defmodule Maxio.Repo.Migrations.AddObjectPlacementFields do
  use Ecto.Migration

  def up do
    alter table(:objects) do
      add :placement_set_id, :integer,
        comment: "对象版本当前字节所在 erasure set id；NULL 表示旧行按当前 topology hash 回退"

      add :placement_pool_id, :integer, comment: "对象版本当前字节所在 pool id；当前路由尚未启用多 pool，预留给迁移/重平衡"

      add :placement_topology_hash, :string, comment: "写入或迁移时的 topology 摘要；用于识别历史拓扑估算风险"
    end

    create index(:objects, [:placement_set_id], name: :objects_placement_set_id_index)

    execute(
      "COMMENT ON INDEX objects_placement_set_id_index IS '按对象真实落点 set 查询，为 rebalance/decommission 规划与迁移扫描服务'"
    )
  end

  def down do
    execute("COMMENT ON INDEX objects_placement_set_id_index IS NULL")

    drop_if_exists index(:objects, [:placement_set_id], name: :objects_placement_set_id_index)

    alter table(:objects) do
      remove :placement_topology_hash
      remove :placement_pool_id
      remove :placement_set_id
    end
  end
end
