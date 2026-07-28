defmodule Maxio.Repo.Migrations.CreateIamAccountPasswordPolicies do
  use Ecto.Migration

  def change do
    create table(:iam_account_password_policies,
             primary_key: false,
             comment:
               "IAM 账号密码策略：AWS 每个账号最多一个自定义 AccountPasswordPolicy；用于 IAM Query Get/Update/DeleteAccountPasswordPolicy"
           ) do
      add :id, :binary_id, primary_key: true, comment: "账号密码策略主键（UUID）"

      add :singleton_key, :integer,
        null: false,
        default: 1,
        comment: "单账号唯一哨兵键；固定为 1，通过唯一索引和 CHECK 约束保证最多一条密码策略"

      add :minimum_password_length, :integer,
        null: false,
        default: 6,
        comment: "IAM 用户控制台密码最小长度；AWS 范围 6..128，未传 Update 参数时默认 6"

      add :require_symbols, :boolean,
        null: false,
        default: false,
        comment: "是否要求密码至少包含一个 AWS 文档列出的符号字符；未传 Update 参数时默认 false"

      add :require_numbers, :boolean,
        null: false,
        default: false,
        comment: "是否要求密码至少包含一个数字 0..9；未传 Update 参数时默认 false"

      add :require_uppercase_characters, :boolean,
        null: false,
        default: false,
        comment: "是否要求密码至少包含一个大写英文字母 A..Z；未传 Update 参数时默认 false"

      add :require_lowercase_characters, :boolean,
        null: false,
        default: false,
        comment: "是否要求密码至少包含一个小写英文字母 a..z；未传 Update 参数时默认 false"

      add :allow_users_to_change_password, :boolean,
        null: false,
        default: false,
        comment: "是否允许 IAM 用户修改自己的控制台密码；未传 Update 参数时默认 false"

      add :hard_expiry, :boolean,
        null: false,
        default: false,
        comment: "密码过期后是否禁止用户自助设置新密码；未传 Update 参数时默认 false"

      add :max_password_age, :integer, comment: "密码有效天数；AWS 范围 1..1095；NULL 表示未配置/默认 0，即密码不过期"

      add :password_reuse_prevention, :integer,
        comment: "禁止复用的历史密码个数；AWS 范围 1..24；NULL 表示未配置/默认 0，即不限制复用"

      add :inserted_at, :utc_datetime_usec,
        null: false,
        comment: "账号密码策略创建时间（UTC，微秒）"

      add :updated_at, :utc_datetime_usec,
        null: false,
        comment: "账号密码策略最近更新时间（UTC，微秒）"
    end

    create unique_index(:iam_account_password_policies, [:singleton_key],
             name: :iam_account_password_policies_singleton_key_index,
             comment: "单账号唯一索引（singleton_key 固定为 1，保证最多一条账号密码策略）"
           )

    execute(
      """
      ALTER TABLE iam_account_password_policies
      ADD CONSTRAINT iam_account_password_policies_singleton_key_is_one
      CHECK (singleton_key = 1)
      """,
      """
      ALTER TABLE iam_account_password_policies
      DROP CONSTRAINT iam_account_password_policies_singleton_key_is_one
      """
    )

    execute(
      """
      COMMENT ON CONSTRAINT iam_account_password_policies_singleton_key_is_one
      ON iam_account_password_policies IS '约束 singleton_key 固定为 1，防止直接插入其它键绕过单账号最多一条密码策略的数据库边界'
      """,
      """
      COMMENT ON CONSTRAINT iam_account_password_policies_singleton_key_is_one
      ON iam_account_password_policies IS NULL
      """
    )

    execute(
      """
      ALTER TABLE iam_account_password_policies
      ADD CONSTRAINT iam_account_password_policies_minimum_password_length_range
      CHECK (minimum_password_length BETWEEN 6 AND 128)
      """,
      """
      ALTER TABLE iam_account_password_policies
      DROP CONSTRAINT iam_account_password_policies_minimum_password_length_range
      """
    )

    execute(
      """
      COMMENT ON CONSTRAINT iam_account_password_policies_minimum_password_length_range
      ON iam_account_password_policies IS '约束 minimum_password_length 符合 AWS AccountPasswordPolicy 范围 6..128'
      """,
      """
      COMMENT ON CONSTRAINT iam_account_password_policies_minimum_password_length_range
      ON iam_account_password_policies IS NULL
      """
    )

    execute(
      """
      ALTER TABLE iam_account_password_policies
      ADD CONSTRAINT iam_account_password_policies_max_password_age_range
      CHECK (max_password_age IS NULL OR max_password_age BETWEEN 1 AND 1095)
      """,
      """
      ALTER TABLE iam_account_password_policies
      DROP CONSTRAINT iam_account_password_policies_max_password_age_range
      """
    )

    execute(
      """
      COMMENT ON CONSTRAINT iam_account_password_policies_max_password_age_range
      ON iam_account_password_policies IS '约束 max_password_age 符合 AWS AccountPasswordPolicy 范围 1..1095；NULL 表示默认 0'
      """,
      """
      COMMENT ON CONSTRAINT iam_account_password_policies_max_password_age_range
      ON iam_account_password_policies IS NULL
      """
    )

    execute(
      """
      ALTER TABLE iam_account_password_policies
      ADD CONSTRAINT iam_account_password_policies_reuse_prevention_range
      CHECK (password_reuse_prevention IS NULL OR password_reuse_prevention BETWEEN 1 AND 24)
      """,
      """
      ALTER TABLE iam_account_password_policies
      DROP CONSTRAINT iam_account_password_policies_reuse_prevention_range
      """
    )

    execute(
      """
      COMMENT ON CONSTRAINT iam_account_password_policies_reuse_prevention_range
      ON iam_account_password_policies IS '约束 password_reuse_prevention 符合 AWS AccountPasswordPolicy 范围 1..24；NULL 表示默认 0'
      """,
      """
      COMMENT ON CONSTRAINT iam_account_password_policies_reuse_prevention_range
      ON iam_account_password_policies IS NULL
      """
    )
  end
end
