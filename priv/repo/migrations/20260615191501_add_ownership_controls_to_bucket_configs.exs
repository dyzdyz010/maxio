defmodule Maxio.Repo.Migrations.AddOwnershipControlsToBucketConfigs do
  use Ecto.Migration

  def change do
    alter table(:bucket_configs) do
      add :ownership_controls, :map, comment: "S3 Object Ownership 控制配置（ObjectOwnership）；nil=未配置"
    end
  end
end
