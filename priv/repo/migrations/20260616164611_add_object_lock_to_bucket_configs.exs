defmodule Maxio.Repo.Migrations.AddObjectLockToBucketConfigs do
  use Ecto.Migration

  def change do
    alter table(:bucket_configs) do
      add :object_lock, :map, comment: "S3 Object Lock 默认保留配置，jsonb；保存桶级控制面配置，不代表对象级保留状态"
    end
  end
end
