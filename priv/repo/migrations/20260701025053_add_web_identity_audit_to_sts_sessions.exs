defmodule Maxio.Repo.Migrations.AddWebIdentityAuditToStsSessions do
  use Ecto.Migration

  def up do
    alter table(:sts_sessions) do
      modify :issuer_access_key_id, :string,
        null: true,
        comment: "签发该临时凭据的长期 Access Key ID；WebIdentity 会话无长期签发方时为空"

      add :web_identity_provider_arn, :string,
        comment: "AssumeRoleWithWebIdentity 验证通过的 OIDC provider ARN，用于审计和会话签发来源定位"

      add :web_identity_subject_sha256, :string,
        comment: "WebIdentity token sub 声明的 SHA256 十六进制摘要；避免在会话表保存原始 subject"

      add :web_identity_audience, :string,
        comment: "WebIdentity token 命中的 audience/client_id，用于审计与 STS 响应取证"
    end

    create index(:sts_sessions, [:web_identity_provider_arn],
             name: :sts_sessions_web_identity_provider_arn_index,
             comment: "按 OIDC provider ARN 审计 AssumeRoleWithWebIdentity 会话"
           )
  end

  def down do
    drop_if_exists index(:sts_sessions, [:web_identity_provider_arn],
                     name: :sts_sessions_web_identity_provider_arn_index
                   )

    execute("COMMENT ON COLUMN sts_sessions.web_identity_audience IS NULL")
    execute("COMMENT ON COLUMN sts_sessions.web_identity_subject_sha256 IS NULL")
    execute("COMMENT ON COLUMN sts_sessions.web_identity_provider_arn IS NULL")

    alter table(:sts_sessions) do
      remove :web_identity_audience
      remove :web_identity_subject_sha256
      remove :web_identity_provider_arn

      modify :issuer_access_key_id, :string,
        null: false,
        comment: "签发该临时凭据的长期 Access Key ID，用于审计和撤销定位"
    end
  end
end
