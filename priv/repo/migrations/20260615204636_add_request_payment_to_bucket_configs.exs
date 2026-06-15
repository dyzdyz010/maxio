defmodule Maxio.Repo.Migrations.AddRequestPaymentToBucketConfigs do
  use Ecto.Migration

  def change do
    alter table(:bucket_configs) do
      add :request_payment, :map,
        comment:
          "S3 Bucket RequestPayment 配置（RequestPaymentConfiguration/Payer）；nil=默认 BucketOwner"
    end
  end
end
