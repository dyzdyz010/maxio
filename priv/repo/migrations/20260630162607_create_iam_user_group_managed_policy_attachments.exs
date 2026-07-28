defmodule Maxio.Repo.Migrations.CreateIamUserGroupManagedPolicyAttachments do
  use Ecto.Migration

  def up do
    create table(:iam_user_managed_policy_attachments,
             primary_key: false,
             comment:
               "IAM user 与 managed policy 的绑定表；绑定后的 managed policy 作为 user identity policy 参与 S3 授权"
           ) do
      add :id, :binary_id,
        primary_key: true,
        comment: "user managed policy attachment 主键（UUID）"

      add :user_arn,
          references(:iam_users,
            column: :user_arn,
            type: :string,
            on_delete: :delete_all
          ),
          null: false,
          comment: "被绑定 managed policy 的 IAM user ARN；user 删除时级联清理绑定"

      add :policy_arn,
          references(:managed_policies,
            column: :policy_arn,
            type: :text,
            on_delete: :restrict
          ),
          null: false,
          comment: "绑定到 user 的 managed policy ARN；已绑定 policy 不允许静默删除"

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:iam_user_managed_policy_attachments, [:user_arn, :policy_arn],
             name: :iam_user_managed_policy_attachments_user_policy_index,
             comment: "同一 user 与同一 managed policy 只能绑定一次"
           )

    create index(:iam_user_managed_policy_attachments, [:policy_arn],
             name: :iam_user_managed_policy_attachments_policy_arn_index,
             comment: "按 managed policy ARN 反查 user attachment；用于删除 policy 前的引用检查"
           )

    execute(
      "COMMENT ON COLUMN iam_user_managed_policy_attachments.inserted_at IS 'user managed policy attachment 创建时间'"
    )

    execute(
      "COMMENT ON COLUMN iam_user_managed_policy_attachments.updated_at IS 'user managed policy attachment 最后更新时间'"
    )

    create table(:iam_group_managed_policy_attachments,
             primary_key: false,
             comment:
               "IAM group 与 managed policy 的绑定表；active user 会继承 active group 上绑定的 managed policy"
           ) do
      add :id, :binary_id,
        primary_key: true,
        comment: "group managed policy attachment 主键（UUID）"

      add :group_arn,
          references(:iam_groups,
            column: :group_arn,
            type: :string,
            on_delete: :delete_all
          ),
          null: false,
          comment: "被绑定 managed policy 的 IAM group ARN；group 删除时级联清理绑定"

      add :policy_arn,
          references(:managed_policies,
            column: :policy_arn,
            type: :text,
            on_delete: :restrict
          ),
          null: false,
          comment: "绑定到 group 的 managed policy ARN；已绑定 policy 不允许静默删除"

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:iam_group_managed_policy_attachments, [:group_arn, :policy_arn],
             name: :iam_group_managed_policy_attachments_group_policy_index,
             comment: "同一 group 与同一 managed policy 只能绑定一次"
           )

    create index(:iam_group_managed_policy_attachments, [:policy_arn],
             name: :iam_group_managed_policy_attachments_policy_arn_index,
             comment: "按 managed policy ARN 反查 group attachment；用于删除 policy 前的引用检查"
           )

    execute(
      "COMMENT ON COLUMN iam_group_managed_policy_attachments.inserted_at IS 'group managed policy attachment 创建时间'"
    )

    execute(
      "COMMENT ON COLUMN iam_group_managed_policy_attachments.updated_at IS 'group managed policy attachment 最后更新时间'"
    )
  end

  def down do
    execute("COMMENT ON COLUMN iam_group_managed_policy_attachments.updated_at IS NULL")
    execute("COMMENT ON COLUMN iam_group_managed_policy_attachments.inserted_at IS NULL")

    drop_if_exists index(:iam_group_managed_policy_attachments, [:policy_arn],
                     name: :iam_group_managed_policy_attachments_policy_arn_index
                   )

    drop_if_exists index(:iam_group_managed_policy_attachments, [:group_arn, :policy_arn],
                     name: :iam_group_managed_policy_attachments_group_policy_index
                   )

    drop table(:iam_group_managed_policy_attachments)

    execute("COMMENT ON COLUMN iam_user_managed_policy_attachments.updated_at IS NULL")
    execute("COMMENT ON COLUMN iam_user_managed_policy_attachments.inserted_at IS NULL")

    drop_if_exists index(:iam_user_managed_policy_attachments, [:policy_arn],
                     name: :iam_user_managed_policy_attachments_policy_arn_index
                   )

    drop_if_exists index(:iam_user_managed_policy_attachments, [:user_arn, :policy_arn],
                     name: :iam_user_managed_policy_attachments_user_policy_index
                   )

    drop table(:iam_user_managed_policy_attachments)
  end
end
