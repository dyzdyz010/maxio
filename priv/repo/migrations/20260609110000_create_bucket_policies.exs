defmodule Maxio.Repo.Migrations.CreateBucketPolicies do
  use Ecto.Migration

  def change do
    create table(:bucket_policies,
             primary_key: false,
             comment: "S3 桶策略：每桶至多一行；存原始 JSON 文档（GetBucketPolicy 原样回放），授权时解析为 statement"
           ) do
      add :id, :binary_id, primary_key: true, comment: "桶策略主键（UUID）"

      add :bucket_name, :string,
        null: false,
        comment: "所属桶名（与 buckets.name 对应；每桶唯一一条 policy）"

      add :document, :map,
        null: false,
        comment: "策略 JSON 文档（jsonb；PutBucketPolicy 原样存，GetBucketPolicy 原样回放，铁律 5 round-trip）"

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:bucket_policies, [:bucket_name],
             comment: "桶名唯一索引（每桶至多一条 policy；PutBucketPolicy 走 upsert 覆盖）"
           )
  end
end
