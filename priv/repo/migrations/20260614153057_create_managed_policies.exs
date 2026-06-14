defmodule Maxio.Repo.Migrations.CreateManagedPolicies do
  use Ecto.Migration

  def change do
    create table(:managed_policies,
             primary_key: false,
             comment:
               "IAM managed policy：按 policy_arn 独立持久化的策略文档；AssumeRole PolicyArns 在签发时读取并快照为 session permissions boundary"
           ) do
      add :id, :binary_id, primary_key: true, comment: "managed policy 主键（UUID）"

      add :policy_arn, :text,
        null: false,
        comment:
          "managed policy ARN（当前支持本地单账户 arn:aws:iam:::policy/<path><name>；path 最长 512 字节、policy name 最长 128 字节）"

      add :document, :map,
        null: false,
        comment: "identity policy JSON 文档（jsonb；不允许 Principal，签发 STS session 时作为边界策略快照）"

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:managed_policies, [:policy_arn],
             comment: "policy_arn 精确唯一索引（同 ARN managed policy 不可重复创建；fixture/upsert 仅覆盖同 ARN）"
           )
  end
end
