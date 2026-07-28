defmodule Maxio.Repo.Migrations.AddIamUsersCaseInsensitiveUniqueIndex do
  use Ecto.Migration

  def up do
    execute("""
    CREATE UNIQUE INDEX iam_users_user_name_ci_index
    ON iam_users (lower(user_name))
    """)

    execute("""
    COMMENT ON INDEX iam_users_user_name_ci_index IS
    'IAM user 名大小写不敏感唯一索引；防止 CreateUser 并发创建仅大小写不同的同名用户'
    """)
  end

  def down do
    execute("COMMENT ON INDEX iam_users_user_name_ci_index IS NULL")
    execute("DROP INDEX IF EXISTS iam_users_user_name_ci_index")
  end
end
