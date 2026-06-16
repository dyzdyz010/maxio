defmodule Maxio.Repo.Migrations.AddNotificationToBucketConfigs do
  use Ecto.Migration

  def change do
    alter table(:bucket_configs) do
      add :notification, :map,
        comment: "S3 Bucket Notification 配置（NotificationConfiguration）；nil=未配置或已关闭"
    end
  end
end
