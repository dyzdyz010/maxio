defmodule Maxio.Repo.Migrations.CreatePrincipalPolicies do
  use Ecto.Migration

  def change do
    create table(:principal_policies,
             primary_key: false,
             comment:
               "IAM identity policy：绑定到 principal_arn 的内联策略；授权时作为该 principal 的隐式身份策略参与同一 Evaluator"
           ) do
      add :id, :binary_id, primary_key: true, comment: "identity policy 主键（UUID）"

      add :principal_arn, :string,
        null: false,
        comment: "绑定的 principal ARN（例如 arn:aws:iam:::user/<access_key> 或 arn:aws:iam:::root）"

      add :policy_name, :string,
        null: false,
        comment: "principal 内策略名；同一 principal 下唯一，用于 CLI/管理面覆盖与删除"

      add :document, :map,
        null: false,
        comment: "identity policy JSON 文档（jsonb；不允许 Principal，principal 由绑定关系隐式提供）"

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:principal_policies, [:principal_arn, :policy_name],
             comment: "principal_arn + policy_name 唯一索引（同名策略 upsert 覆盖）"
           )
  end
end
