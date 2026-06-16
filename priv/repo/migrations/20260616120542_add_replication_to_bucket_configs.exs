defmodule Maxio.Repo.Migrations.AddReplicationToBucketConfigs do
  use Ecto.Migration

  def change do
    alter table(:bucket_configs) do
      add :replication, :map,
        comment: "S3 Bucket Replication 配置（ReplicationConfiguration 控制面 XML 归一化结构）；nil=未配置"
    end
  end
end
