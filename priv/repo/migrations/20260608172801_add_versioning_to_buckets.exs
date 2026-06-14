defmodule Maxio.Repo.Migrations.AddVersioningToBuckets do
  use Ecto.Migration

  def change do
    alter table(:buckets) do
      add :versioning, :string,
        null: false,
        default: "Unversioned",
        comment:
          "桶版本化状态三态：Unversioned（从未设置，GetBucketVersioning 不回 <Status>）| Enabled（每次 PUT 生成唯一 version_id）| Suspended（PUT 用 null 版本就地覆盖）"

      add :mfa_delete, :string,
        null: true,
        comment:
          "MFA Delete 状态（Enabled|Disabled）；仅当曾配置时 GetBucketVersioning 才回显 <MfaDelete>。S3 API 对受保护操作要求 root principal、HTTPS 且已签名的 x-amz-mfa，并通过配置的 verifier；未配置 verifier fail-closed"
    end
  end
end
