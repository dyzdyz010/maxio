defmodule Maxio.Repo.Migrations.AddVersioningToObjects do
  use Ecto.Migration

  def change do
    alter table(:objects) do
      add :version_id, :string,
        null: false,
        default: "null",
        comment:
          "对象版本 ID（ULID，时间有序、URL-safe）；保留串 null 表示无版本（Unversioned/Suspended 写入的版本）。与 (bucket_id,key) 共同唯一确定一个版本行"

      add :is_latest, :boolean,
        null: false,
        default: true,
        comment: "是否为该 (bucket,key) 的当前版本（每 key 至多一行为 true；GET/ListObjectsV2 默认取此行）"

      add :is_delete_marker, :boolean,
        null: false,
        default: false,
        comment:
          "是否为删除标记（无字节、无 ACL；当前版本为删除标记时 GET 返回 404 + x-amz-delete-marker，ListObjectsV2 不返回）"
    end

    # 去掉旧的 (bucket_id,key) 唯一索引，改为 (bucket_id,key,version_id) 唯一（多版本）。
    drop unique_index(:objects, [:bucket_id, :key], name: :objects_bucket_id_key_index)

    create unique_index(:objects, [:bucket_id, :key, :version_id],
             name: :objects_bucket_id_key_version_id_index,
             comment: "桶内 (key, version_id) 唯一索引（多版本：同 key 多版本各一行；null 版本至多一行）"
           )

    # 加速「取某 key 的当前版本」与「列某 key 的全部版本（newest-first）」。
    create index(:objects, [:bucket_id, :key, :is_latest],
             name: :objects_bucket_key_latest_index,
             comment: "按 (bucket,key) 取当前版本（is_latest=true）索引"
           )
  end
end
