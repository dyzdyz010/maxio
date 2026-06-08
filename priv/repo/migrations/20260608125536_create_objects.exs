defmodule Maxio.Repo.Migrations.CreateObjects do
  use Ecto.Migration

  def change do
    create table(:objects,
             primary_key: false,
             comment: "S3 对象元数据：每个 (bucket, key) 当前版本一行；对象字节由存储后端持有，本表只存元信息"
           ) do
      add :id, :binary_id, primary_key: true, comment: "对象主键（UUID）"

      add :bucket_id, references(:buckets, type: :binary_id, on_delete: :delete_all),
        null: false,
        comment: "所属桶外键（删桶级联删元数据；删桶前需先空桶，由应用层 BucketNotEmpty 拦截）"

      add :bucket_name, :string,
        null: false,
        comment: "冗余桶名（便于按桶名直接查询/列举，免 join）"

      add :key, :string,
        null: false,
        comment: "对象键（完整 S3 key，含任意 / 层级；与 bucket 唯一确定一个对象）"

      add :size, :bigint, null: false, default: 0, comment: "对象字节大小"

      add :etag, :string,
        null: false,
        comment: "实体标签：单次 PUT = MD5(内容) 的 hex（本列不含引号，渲染时加引号）"

      add :content_type, :string,
        null: false,
        default: "binary/octet-stream",
        comment: "MIME 类型（PutObject 的 Content-Type，缺省 binary/octet-stream）"

      add :metadata, :map,
        null: false,
        default: %{},
        comment: "用户自定义元数据（x-amz-meta-* 头，jsonb 键值）"

      add :storage_class, :string,
        null: false,
        default: "STANDARD",
        comment: "存储类别（S3 兼容，MVP 恒 STANDARD）"

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:objects, [:bucket_id, :key],
             comment: "桶内对象键唯一索引（同 key 再次 PUT 走 upsert 覆盖当前版本）"
           )

    create index(:objects, [:bucket_name, :key],
             comment: "按桶名 + key 前缀范围扫描索引（ListObjectsV2 prefix/start-after/分页）"
           )
  end
end
