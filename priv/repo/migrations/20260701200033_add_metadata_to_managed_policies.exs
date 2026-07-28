defmodule Maxio.Repo.Migrations.AddMetadataToManagedPolicies do
  use Ecto.Migration

  def up do
    alter table(:managed_policies) do
      add :description, :text,
        null: false,
        default: "",
        comment: "IAM customer managed policy 描述；来自 CreatePolicy Description，最大 1000 字符"

      add :tags, :map,
        null: false,
        default: %{},
        comment: "IAM customer managed policy 标签（jsonb）；CreatePolicy Tags.member.N.Key/Value"
    end
  end

  def down do
    execute("COMMENT ON COLUMN managed_policies.tags IS NULL")
    execute("COMMENT ON COLUMN managed_policies.description IS NULL")

    alter table(:managed_policies) do
      remove :tags
      remove :description
    end
  end
end
