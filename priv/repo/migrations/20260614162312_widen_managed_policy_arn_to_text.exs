defmodule Maxio.Repo.Migrations.WidenManagedPolicyArnToText do
  use Ecto.Migration

  def up do
    alter table(:managed_policies) do
      modify :policy_arn, :text, null: false
    end

    execute("""
    COMMENT ON COLUMN managed_policies.policy_arn IS
    'managed policy ARN（当前支持本地单账户 arn:aws:iam:::policy/<path><name>；path 最长 512 字节、policy name 最长 128 字节）'
    """)
  end

  def down do
    alter table(:managed_policies) do
      modify :policy_arn, :string, null: false
    end

    execute("""
    COMMENT ON COLUMN managed_policies.policy_arn IS
    'managed policy ARN（当前支持本地单账户 arn:aws:iam:::policy/<path>）'
    """)
  end
end
