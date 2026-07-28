defmodule Maxio.Repo.Migrations.AddIamRolesCaseInsensitiveUniqueIndex do
  use Ecto.Migration

  def up do
    execute("""
    CREATE UNIQUE INDEX iam_roles_role_name_ci_index
    ON iam_roles (lower(role_name))
    """)

    execute("""
    COMMENT ON INDEX iam_roles_role_name_ci_index IS
    'IAM role 名大小写不敏感唯一索引；防止 CreateRole 并发创建仅大小写不同的同名角色'
    """)
  end

  def down do
    execute("COMMENT ON INDEX iam_roles_role_name_ci_index IS NULL")
    execute("DROP INDEX IF EXISTS iam_roles_role_name_ci_index")
  end
end
