defmodule Maxio.Repo.Migrations.AddTagsToAccessKeys do
  use Ecto.Migration

  def change do
    alter table(:access_keys) do
      add :tags, :map,
        null: false,
        default: %{},
        comment: "principal tags（IAM ABAC：展开为 aws:PrincipalTag/<key> 条件键；仅存自定义标签，默认空）"
    end
  end
end
