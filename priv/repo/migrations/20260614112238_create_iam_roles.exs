defmodule Maxio.Repo.Migrations.CreateIamRoles do
  use Ecto.Migration

  def up do
    create table(:iam_roles,
             primary_key: false,
             comment: "IAM 角色表；保存 AssumeRole 目标角色、信任策略和会话上限"
           ) do
      add :id, :binary_id, primary_key: true, comment: "IAM 角色 UUID 主键"

      add :role_name, :string,
        null: false,
        comment: "角色名称；用于组成 arn:aws:iam:::role/<role_name>"

      add :role_arn, :string,
        null: false,
        comment: "角色 ARN；STS AssumeRole 的 RoleArn 参数按此精确查找"

      add :trust_policy, :map,
        null: false,
        comment: "角色信任策略 JSON；resource-based policy，决定哪些 principal 可执行 sts:AssumeRole"

      add :max_session_duration_seconds, :integer,
        null: false,
        default: 3600,
        comment: "角色会话最长秒数；AssumeRole DurationSeconds 不得超过该上限"

      add :tags, :map,
        null: false,
        default: %{},
        comment: "角色标签快照；AssumeRole 会话继承用于 IAM 条件键评估"

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:iam_roles, [:role_name],
             name: :iam_roles_role_name_index,
             comment: "IAM 角色名称全局唯一索引"
           )

    create unique_index(:iam_roles, [:role_arn],
             name: :iam_roles_role_arn_index,
             comment: "IAM 角色 ARN 全局唯一索引；AssumeRole 按 ARN 定位"
           )

    execute("COMMENT ON COLUMN iam_roles.inserted_at IS 'IAM 角色记录创建时间'")
    execute("COMMENT ON COLUMN iam_roles.updated_at IS 'IAM 角色记录最后更新时间'")
  end

  def down do
    execute("COMMENT ON COLUMN iam_roles.updated_at IS NULL")
    execute("COMMENT ON COLUMN iam_roles.inserted_at IS NULL")

    drop_if_exists index(:iam_roles, [:role_arn], name: :iam_roles_role_arn_index)
    drop_if_exists index(:iam_roles, [:role_name], name: :iam_roles_role_name_index)

    drop table(:iam_roles)
  end
end
