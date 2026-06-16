defmodule Maxio.Repo.Migrations.AddAnalyticsToBucketConfigs do
  use Ecto.Migration

  def change do
    alter table(:bucket_configs) do
      add :analytics, :map,
        comment: "S3 Bucket Analytics 配置（%{\"Configurations\" => [...]} 数组形态）；nil=未配置"
    end
  end
end
