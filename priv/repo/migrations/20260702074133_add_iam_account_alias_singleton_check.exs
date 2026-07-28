defmodule Maxio.Repo.Migrations.AddIamAccountAliasSingletonCheck do
  use Ecto.Migration

  def change do
    execute(
      """
      ALTER TABLE iam_account_aliases
      ADD CONSTRAINT iam_account_aliases_singleton_key_is_one
      CHECK (singleton_key = 1)
      """,
      """
      ALTER TABLE iam_account_aliases
      DROP CONSTRAINT iam_account_aliases_singleton_key_is_one
      """
    )

    execute(
      """
      COMMENT ON CONSTRAINT iam_account_aliases_singleton_key_is_one
      ON iam_account_aliases IS '约束 singleton_key 固定为 1，防止直接插入其它键绕过单账号最多一个 alias 的数据库边界'
      """,
      """
      COMMENT ON CONSTRAINT iam_account_aliases_singleton_key_is_one
      ON iam_account_aliases IS NULL
      """
    )
  end
end
