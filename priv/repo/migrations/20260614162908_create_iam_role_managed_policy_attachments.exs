defmodule Maxio.Repo.Migrations.CreateIamRoleManagedPolicyAttachments do
  use Ecto.Migration

  def up do
    create table(:iam_role_managed_policy_attachments,
             primary_key: false,
             comment:
               "IAM role 与 managed policy 的绑定表；绑定后的 managed policy 作为 role identity policy 参与 S3 授权"
           ) do
      add :id, :binary_id, primary_key: true, comment: "role managed policy attachment 主键（UUID）"

      add :role_arn,
          references(:iam_roles,
            column: :role_arn,
            type: :string,
            on_delete: :delete_all
          ),
          null: false,
          comment: "被绑定 managed policy 的 IAM role ARN；role 删除时级联清理绑定"

      add :policy_arn,
          references(:managed_policies,
            column: :policy_arn,
            type: :text,
            on_delete: :restrict
          ),
          null: false,
          comment: "绑定到 role 的 managed policy ARN；已绑定 policy 不允许静默删除"

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:iam_role_managed_policy_attachments, [:role_arn, :policy_arn],
             name: :iam_role_managed_policy_attachments_role_policy_index,
             comment: "同一 role 与同一 managed policy 只能绑定一次"
           )

    create index(:iam_role_managed_policy_attachments, [:policy_arn],
             name: :iam_role_managed_policy_attachments_policy_arn_index,
             comment: "按 managed policy ARN 反查 attachment；用于删除 policy 前的引用检查"
           )

    execute("""
    COMMENT ON COLUMN iam_role_managed_policy_attachments.inserted_at IS
    'role managed policy attachment 创建时间'
    """)

    execute("""
    COMMENT ON COLUMN iam_role_managed_policy_attachments.updated_at IS
    'role managed policy attachment 最后更新时间'
    """)
  end

  def down do
    execute("COMMENT ON COLUMN iam_role_managed_policy_attachments.updated_at IS NULL")
    execute("COMMENT ON COLUMN iam_role_managed_policy_attachments.inserted_at IS NULL")

    drop_if_exists index(:iam_role_managed_policy_attachments, [:policy_arn],
                     name: :iam_role_managed_policy_attachments_policy_arn_index
                   )

    drop_if_exists index(:iam_role_managed_policy_attachments, [:role_arn, :policy_arn],
                     name: :iam_role_managed_policy_attachments_role_policy_index
                   )

    drop table(:iam_role_managed_policy_attachments)
  end
end
