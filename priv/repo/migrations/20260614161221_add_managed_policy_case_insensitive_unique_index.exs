defmodule Maxio.Repo.Migrations.AddManagedPolicyCaseInsensitiveUniqueIndex do
  use Ecto.Migration

  def up do
    alter table(:managed_policies) do
      modify :policy_arn, :text, null: false
    end

    execute("""
    COMMENT ON COLUMN managed_policies.policy_arn IS
    'managed policy ARN（当前支持本地单账户 arn:aws:iam:::policy/<path><name>；path 最长 512 字节、policy name 最长 128 字节）'
    """)

    execute("""
    CREATE UNIQUE INDEX managed_policies_policy_name_lower_index
    ON managed_policies (lower(regexp_replace(policy_arn, '^.*/', '')))
    """)

    execute("""
    COMMENT ON INDEX managed_policies_policy_name_lower_index IS
    'IAM managed policy 名称大小写不敏感唯一索引；从 policy_arn 最后一段提取 policy name，确保同账号内 ReadOnly 与 readonly 不可并存'
    """)
  end

  def down do
    execute("COMMENT ON INDEX managed_policies_policy_name_lower_index IS NULL")
    execute("DROP INDEX managed_policies_policy_name_lower_index")

    alter table(:managed_policies) do
      modify :policy_arn, :string, null: false
    end

    execute("""
    COMMENT ON COLUMN managed_policies.policy_arn IS
    'managed policy ARN（当前支持本地单账户 arn:aws:iam:::policy/<path>）'
    """)
  end
end
