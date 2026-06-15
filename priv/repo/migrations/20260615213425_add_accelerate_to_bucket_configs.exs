defmodule Maxio.Repo.Migrations.AddAccelerateToBucketConfigs do
  use Ecto.Migration

  def change do
    alter table(:bucket_configs) do
      add :accelerate, :map,
        comment: "S3 Bucket Accelerate 配置（AccelerateConfiguration/Status）；nil=未配置"
    end
  end
end
