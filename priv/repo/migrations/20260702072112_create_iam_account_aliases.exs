defmodule Maxio.Repo.Migrations.CreateIamAccountAliases do
  use Ecto.Migration

  def change do
    create table(:iam_account_aliases,
             primary_key: false,
             comment:
               "IAM 账号别名：AWS 每个账号最多一个 account alias；用于 IAM Query Create/List/DeleteAccountAlias"
           ) do
      add :id, :binary_id, primary_key: true, comment: "账号别名主键（UUID）"

      add :account_alias, :string,
        null: false,
        comment: "账号别名值：3..63 位小写字母、数字、单连字符；不能以连字符开头/结尾或出现连续连字符"

      add :singleton_key, :integer,
        null: false,
        default: 1,
        comment: "单账号唯一哨兵键；固定为 1，通过唯一索引保证本地单账号最多一个 alias"

      add :inserted_at, :utc_datetime_usec,
        null: false,
        comment: "账号别名创建时间（UTC，微秒）"

      add :updated_at, :utc_datetime_usec,
        null: false,
        comment: "账号别名最近更新时间（UTC，微秒）"
    end

    create unique_index(:iam_account_aliases, [:account_alias],
             name: :iam_account_aliases_account_alias_index,
             comment: "账号别名值唯一索引（防止重复创建相同 alias）"
           )

    create unique_index(:iam_account_aliases, [:singleton_key],
             name: :iam_account_aliases_singleton_key_index,
             comment: "单账号唯一索引（singleton_key 固定为 1，保证最多一个 account alias）"
           )
  end
end
