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
          "MFA Delete 状态（Enabled|Disabled）；仅当曾配置时 GetBucketVersioning 才回显 <MfaDelete>。MVP 不强制 MFA 校验（无设备），仅存储/回显（defer，文档化）"
    end
  end
end
