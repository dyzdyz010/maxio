defmodule Maxio.Repo.Migrations.CreateIamInstanceProfiles do
  use Ecto.Migration

  def up do
    create table(:iam_instance_profiles,
             primary_key: false,
             comment: "IAM instance profile 表；为 EC2/STS 兼容面保存 profile 元数据，并显式记录至多一个关联 role"
           ) do
      add :id, :binary_id, primary_key: true, comment: "IAM instance profile UUID 主键"

      add :instance_profile_name, :string,
        null: false,
        comment: "IAM instance profile 名称；本地单账户内唯一"

      add :instance_profile_arn, :string,
        null: false,
        comment: "IAM instance profile ARN；形如 arn:aws:iam:::instance-profile/<path>/<name>"

      add :path, :string,
        null: false,
        default: "/",
        comment: "IAM instance profile 路径；以 / 开头和结尾，支持 IAM path 字符"

      add :role_arn,
          references(:iam_roles,
            column: :role_arn,
            type: :string,
            on_delete: :nothing
          ),
          comment: "关联到该 instance profile 的 IAM role ARN；NULL 表示尚未添加 role"

      add :tags, :map,
        null: false,
        default: %{},
        comment: "IAM instance profile 标签；用于 Query API tag round-trip 与后续 Console 展示"

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:iam_instance_profiles, [:instance_profile_name],
             name: :iam_instance_profiles_name_index,
             comment: "IAM instance profile 名称全局唯一索引"
           )

    execute("""
    CREATE UNIQUE INDEX iam_instance_profiles_name_ci_index
    ON iam_instance_profiles (lower(instance_profile_name))
    """)

    execute("""
    COMMENT ON INDEX iam_instance_profiles_name_ci_index IS
    'IAM instance profile 名称大小写不敏感唯一索引；防止仅大小写不同的重复 profile'
    """)

    create unique_index(:iam_instance_profiles, [:instance_profile_arn],
             name: :iam_instance_profiles_arn_index,
             comment: "IAM instance profile ARN 全局唯一索引"
           )

    create index(:iam_instance_profiles, [:role_arn, :instance_profile_name],
             name: :iam_instance_profiles_role_arn_name_index,
             comment: "按 role ARN 反查 instance profiles；用于 ListInstanceProfilesForRole 与删除保护"
           )

    execute(
      "COMMENT ON CONSTRAINT iam_instance_profiles_role_arn_fkey ON iam_instance_profiles IS 'instance profile 关联 role 的外键；role 被 profile 使用时禁止静默删除'"
    )

    execute("COMMENT ON COLUMN iam_instance_profiles.inserted_at IS 'IAM instance profile 创建时间'")
    execute("COMMENT ON COLUMN iam_instance_profiles.updated_at IS 'IAM instance profile 最后更新时间'")
  end

  def down do
    execute("COMMENT ON COLUMN iam_instance_profiles.updated_at IS NULL")
    execute("COMMENT ON COLUMN iam_instance_profiles.inserted_at IS NULL")

    execute(
      "COMMENT ON CONSTRAINT iam_instance_profiles_role_arn_fkey ON iam_instance_profiles IS NULL"
    )

    drop_if_exists index(:iam_instance_profiles, [:role_arn, :instance_profile_name],
                     name: :iam_instance_profiles_role_arn_name_index
                   )

    drop_if_exists index(:iam_instance_profiles, [:instance_profile_arn],
                     name: :iam_instance_profiles_arn_index
                   )

    execute("COMMENT ON INDEX iam_instance_profiles_name_ci_index IS NULL")
    execute("DROP INDEX IF EXISTS iam_instance_profiles_name_ci_index")

    drop_if_exists index(:iam_instance_profiles, [:instance_profile_name],
                     name: :iam_instance_profiles_name_index
                   )

    drop table(:iam_instance_profiles)
  end
end
