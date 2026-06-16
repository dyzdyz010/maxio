defmodule Maxio.Repo.Migrations.AddMetricsToBucketConfigs do
  use Ecto.Migration

  def change do
    alter table(:bucket_configs) do
      add :metrics, :map,
        comment: "S3 Bucket Metrics 配置（%{\"Configurations\" => [...]} 数组形态）；nil=未配置"
    end
  end
end
