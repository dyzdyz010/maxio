defmodule Maxio.Repo.Migrations.AddPublicAccessBlockToBucketConfigs do
  use Ecto.Migration

  def change do
    alter table(:bucket_configs) do
      add :public_access_block, :map,
        comment:
          "S3 PublicAccessBlock 配置（BlockPublicAcls/IgnorePublicAcls/BlockPublicPolicy/RestrictPublicBuckets）；nil=未配置"
    end
  end
end
