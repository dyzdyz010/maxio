defmodule Maxio.Repo.Migrations.AddSessionPolicyToStsSessions do
  use Ecto.Migration

  def up do
    alter table(:sts_sessions) do
      add :session_policy, :map,
        comment: "AssumeRole 请求内联 session policy 文档；用于限制该临时会话的实际授权上限，不可扩大 role 权限"
    end
  end

  def down do
    execute("COMMENT ON COLUMN sts_sessions.session_policy IS NULL")

    alter table(:sts_sessions) do
      remove :session_policy
    end
  end
end
