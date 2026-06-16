defmodule Maxio.Repo.Migrations.AddInventoryToBucketConfigs do
  use Ecto.Migration

  def change do
    alter table(:bucket_configs) do
      add :inventory, :map,
        comment: "S3 Bucket Inventory 配置（%{\"Configurations\" => [...]} 数组形态）；nil=未配置"
    end
  end
end
