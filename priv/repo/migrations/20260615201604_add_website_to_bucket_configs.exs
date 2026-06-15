defmodule Maxio.Repo.Migrations.AddWebsiteToBucketConfigs do
  use Ecto.Migration

  def change do
    alter table(:bucket_configs) do
      add :website, :map,
        comment:
          "S3 Bucket Website 配置（WebsiteConfiguration：IndexDocument/ErrorDocument/RedirectAllRequestsTo/RoutingRules）；nil=未配置"
    end
  end
end
