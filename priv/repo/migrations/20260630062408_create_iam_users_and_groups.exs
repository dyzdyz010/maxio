defmodule Maxio.Repo.Migrations.CreateIamUsersAndGroups do
  use Ecto.Migration

  def up do
    create table(:iam_users,
             primary_key: false,
             comment: "IAM 用户表；显式用户可拥有一个或多个 access key，并通过 group membership 继承组 identity policy"
           ) do
      add :id, :binary_id, primary_key: true, comment: "IAM user UUID 主键"

      add :user_name, :string,
        null: false,
        comment: "IAM 用户名；本地单账户内唯一，用于 arn:aws:iam:::user/<user_name>"

      add :user_arn, :string,
        null: false,
        comment: "IAM user ARN；access_keys.principal_arn 指向该 ARN 后代表此用户"

      add :status, :string,
        null: false,
        default: "active",
        comment: "用户状态：active | inactive；inactive 用户的长期 access key 鉴权 fail-closed"

      add :tags, :map,
        null: false,
        default: %{},
        comment: "用户标签；用于后续 IAM condition 与 Console 展示"

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:iam_users, [:user_name],
             name: :iam_users_user_name_index,
             comment: "IAM 用户名全局唯一索引"
           )

    create unique_index(:iam_users, [:user_arn],
             name: :iam_users_user_arn_index,
             comment: "IAM user ARN 全局唯一索引；授权与 access key 绑定按 ARN 定位"
           )

    execute("COMMENT ON COLUMN iam_users.inserted_at IS 'IAM user 记录创建时间'")
    execute("COMMENT ON COLUMN iam_users.updated_at IS 'IAM user 记录最后更新时间'")

    create table(:iam_groups,
             primary_key: false,
             comment: "IAM 组表；组自身不登录，成员用户在授权时继承绑定到 group ARN 的 identity policy"
           ) do
      add :id, :binary_id, primary_key: true, comment: "IAM group UUID 主键"

      add :group_name, :string,
        null: false,
        comment: "IAM 组名；本地单账户内唯一，用于 arn:aws:iam:::group/<group_name>"

      add :group_arn, :string,
        null: false,
        comment: "IAM group ARN；principal_policies 可绑定到该 ARN 作为组策略"

      add :status, :string,
        null: false,
        default: "active",
        comment: "组状态：active | inactive；inactive 组策略不参与成员授权"

      add :tags, :map,
        null: false,
        default: %{},
        comment: "组标签；用于 Console 展示与后续 IAM condition 扩展"

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:iam_groups, [:group_name],
             name: :iam_groups_group_name_index,
             comment: "IAM 组名全局唯一索引"
           )

    create unique_index(:iam_groups, [:group_arn],
             name: :iam_groups_group_arn_index,
             comment: "IAM group ARN 全局唯一索引；组策略与 membership 按 ARN 定位"
           )

    execute("COMMENT ON COLUMN iam_groups.inserted_at IS 'IAM group 记录创建时间'")
    execute("COMMENT ON COLUMN iam_groups.updated_at IS 'IAM group 记录最后更新时间'")

    create table(:iam_group_memberships,
             primary_key: false,
             comment:
               "IAM 用户-组 membership 表；授权时从 active user 的 active group membership 展开组 identity policy"
           ) do
      add :id, :binary_id, primary_key: true, comment: "IAM group membership UUID 主键"

      add :user_arn,
          references(:iam_users,
            column: :user_arn,
            type: :string,
            on_delete: :delete_all
          ),
          null: false,
          comment: "成员 IAM user ARN；用户删除时级联清理 membership"

      add :group_arn,
          references(:iam_groups,
            column: :group_arn,
            type: :string,
            on_delete: :delete_all
          ),
          null: false,
          comment: "所属 IAM group ARN；组删除时级联清理 membership"

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:iam_group_memberships, [:user_arn, :group_arn],
             name: :iam_group_memberships_user_group_index,
             comment: "同一 user 与同一 group 的 membership 只能存在一次"
           )

    create index(:iam_group_memberships, [:group_arn, :user_arn],
             name: :iam_group_memberships_group_user_index,
             comment: "按 group 反查成员用户，用于 CLI/Console 列表与删除前取证"
           )

    execute("COMMENT ON COLUMN iam_group_memberships.inserted_at IS 'IAM group membership 创建时间'")

    execute("COMMENT ON COLUMN iam_group_memberships.updated_at IS 'IAM group membership 最后更新时间'")
  end

  def down do
    execute("COMMENT ON COLUMN iam_group_memberships.updated_at IS NULL")
    execute("COMMENT ON COLUMN iam_group_memberships.inserted_at IS NULL")

    drop_if_exists index(:iam_group_memberships, [:group_arn, :user_arn],
                     name: :iam_group_memberships_group_user_index
                   )

    drop_if_exists index(:iam_group_memberships, [:user_arn, :group_arn],
                     name: :iam_group_memberships_user_group_index
                   )

    drop table(:iam_group_memberships)

    execute("COMMENT ON COLUMN iam_groups.updated_at IS NULL")
    execute("COMMENT ON COLUMN iam_groups.inserted_at IS NULL")

    drop_if_exists index(:iam_groups, [:group_arn], name: :iam_groups_group_arn_index)
    drop_if_exists index(:iam_groups, [:group_name], name: :iam_groups_group_name_index)
    drop table(:iam_groups)

    execute("COMMENT ON COLUMN iam_users.updated_at IS NULL")
    execute("COMMENT ON COLUMN iam_users.inserted_at IS NULL")

    drop_if_exists index(:iam_users, [:user_arn], name: :iam_users_user_arn_index)
    drop_if_exists index(:iam_users, [:user_name], name: :iam_users_user_name_index)
    drop table(:iam_users)
  end
end
