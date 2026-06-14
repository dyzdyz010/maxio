defmodule Maxio.Repo.Migrations.AddTransitiveTagKeysToStsSessions do
  use Ecto.Migration

  def up do
    alter table(:sts_sessions) do
      add :transitive_tag_keys, {:array, :string},
        null: false,
        default: [],
        comment: "AssumeRole 会话中声明为可跨角色链继承的 session tag key 列表；仅这些 key 会在后续 AssumeRole 中继续传播"
    end
  end

  def down do
    execute("COMMENT ON COLUMN sts_sessions.transitive_tag_keys IS NULL")

    alter table(:sts_sessions) do
      remove :transitive_tag_keys
    end
  end
end
