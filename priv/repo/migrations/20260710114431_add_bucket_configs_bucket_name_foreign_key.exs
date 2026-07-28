defmodule Maxio.Repo.Migrations.AddBucketConfigsBucketNameForeignKey do
  use Ecto.Migration

  def up do
    execute("""
    DELETE FROM bucket_configs AS config
    WHERE NOT EXISTS (
      SELECT 1
      FROM buckets AS bucket
      WHERE bucket.name = config.bucket_name
    )
    """)

    execute("""
    ALTER TABLE bucket_configs
    ADD CONSTRAINT bucket_configs_bucket_name_fkey
    FOREIGN KEY (bucket_name)
    REFERENCES buckets(name)
    ON DELETE CASCADE
    """)

    execute("""
    COMMENT ON COLUMN bucket_configs.bucket_name IS
    '所属桶名外键，引用 buckets.name；删除桶时级联删除全部高级配置，防止同名重建继承旧配置'
    """)

    execute("""
    COMMENT ON CONSTRAINT bucket_configs_bucket_name_fkey ON bucket_configs IS
    '保证每条桶配置归属于现存桶，并在 DeleteBucket 删除桶元数据时级联清理'
    """)
  end

  def down do
    execute("""
    COMMENT ON CONSTRAINT bucket_configs_bucket_name_fkey ON bucket_configs IS NULL
    """)

    execute("""
    ALTER TABLE bucket_configs
    DROP CONSTRAINT bucket_configs_bucket_name_fkey
    """)

    execute("""
    COMMENT ON COLUMN bucket_configs.bucket_name IS
    '桶名（唯一；与 buckets.name 对应，由应用层保证桶存在）'
    """)
  end
end
