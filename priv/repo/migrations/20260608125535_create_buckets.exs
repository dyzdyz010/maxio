defmodule Maxio.Repo.Migrations.CreateBuckets do
  use Ecto.Migration

  def change do
    create table(:buckets,
             primary_key: false,
             comment: "S3 桶元数据：每个桶一行，全局命名空间唯一；对象字节不在此表，归存储后端"
           ) do
      add :id, :binary_id, primary_key: true, comment: "桶主键（UUID）"

      add :name, :string,
        null: false,
        comment: "桶名（S3 全局唯一，3-63 字符，命名规则见 Buckets.validate_name）"

      add :region, :string,
        null: false,
        default: "us-east-1",
        comment: "桶所在区域（GetBucketLocation 返回；us-east-1 返回空 LocationConstraint）"

      add :owner, :string,
        null: false,
        comment: "创建者 principal（M1 恒为 root 的 access key / arn）"

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:buckets, [:name],
             comment: "桶名全局唯一索引（命中冲突 → BucketAlreadyExists/BucketAlreadyOwnedByYou）"
           )
  end
end
