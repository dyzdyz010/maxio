defmodule Maxio.Repo.Migrations.AddIamGroupsCaseInsensitiveUniqueIndex do
  use Ecto.Migration

  def up do
    execute("""
    CREATE UNIQUE INDEX iam_groups_group_name_ci_index
    ON iam_groups (lower(group_name))
    """)

    execute("""
    COMMENT ON INDEX iam_groups_group_name_ci_index IS
    'IAM group 名大小写不敏感唯一索引；防止 CreateGroup 并发创建仅大小写不同的同名组'
    """)
  end

  def down do
    execute("COMMENT ON INDEX iam_groups_group_name_ci_index IS NULL")
    execute("DROP INDEX IF EXISTS iam_groups_group_name_ci_index")
  end
end
