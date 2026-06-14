defmodule Maxio.Repo.Migrations.AddAssumeRoleContextToStsSessions do
  use Ecto.Migration

  def up do
    alter table(:sts_sessions) do
      add :source_identity, :string,
        comment: "AssumeRole SourceIdentity；用于审计并作为后续 S3 授权上下文 aws:SourceIdentity"

      add :mfa_authenticated, :boolean,
        null: false,
        default: false,
        comment:
          "STS 签发时是否已通过 MFA 校验；GetSessionToken 后续 S3 授权暴露该键，AssumeRole 仅用于 trust context 与审计"

      add :mfa_serial_hash, :string, comment: "STS 签发时通过校验的 MFA 设备序列号 SHA256；不保存 serial 原文"
    end
  end

  def down do
    execute("COMMENT ON COLUMN sts_sessions.mfa_serial_hash IS NULL")
    execute("COMMENT ON COLUMN sts_sessions.mfa_authenticated IS NULL")
    execute("COMMENT ON COLUMN sts_sessions.source_identity IS NULL")

    alter table(:sts_sessions) do
      remove :mfa_serial_hash
      remove :mfa_authenticated
      remove :source_identity
    end
  end
end
