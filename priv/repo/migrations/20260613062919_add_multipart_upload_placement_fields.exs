defmodule Maxio.Repo.Migrations.AddMultipartUploadPlacementFields do
  use Ecto.Migration

  def up do
    alter table(:multipart_uploads) do
      add :placement_set_id, :integer,
        comment: "分段上传临时 part 字节所在 erasure set id；NULL 表示历史会话按 upload_id 路由回退"

      add :placement_pool_id, :integer,
        comment: "分段上传临时 part 字节所在 pool id；当前多 pool 路由尚未启用，预留给迁移/再平衡"

      add :placement_topology_hash, :string,
        comment: "CreateMultipartUpload 时用于临时 part placement 的 topology 摘要"
    end

    create index(:multipart_uploads, [:placement_set_id],
             name: :multipart_uploads_placement_set_id_index
           )

    execute(
      "COMMENT ON INDEX multipart_uploads_placement_set_id_index IS '按分段上传临时 part 真实落点 set 查询，为 decommission 中断/清理提供定位依据'"
    )
  end

  def down do
    execute("COMMENT ON INDEX multipart_uploads_placement_set_id_index IS NULL")

    drop_if_exists index(:multipart_uploads, [:placement_set_id],
                     name: :multipart_uploads_placement_set_id_index
                   )

    alter table(:multipart_uploads) do
      remove :placement_topology_hash
      remove :placement_pool_id
      remove :placement_set_id
    end
  end
end
