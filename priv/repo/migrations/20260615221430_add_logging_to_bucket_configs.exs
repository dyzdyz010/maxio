defmodule Maxio.Repo.Migrations.AddLoggingToBucketConfigs do
  use Ecto.Migration

  def change do
    alter table(:bucket_configs) do
      add :logging, :map,
        comment: "S3 Bucket Logging 配置（BucketLoggingStatus/LoggingEnabled）；nil=未配置或已关闭"
    end
  end
end
