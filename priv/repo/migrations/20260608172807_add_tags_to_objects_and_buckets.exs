defmodule Maxio.Repo.Migrations.AddTagsToObjectsAndBuckets do
  use Ecto.Migration

  def change do
    alter table(:objects) do
      add :tags, :map,
        null: false,
        default: %{},
        comment: "对象标签集（jsonb，Key→Value 映射；≤10 个，挂在版本行；x-amz-tagging 头或 PutObjectTagging 写入）"
    end

    alter table(:buckets) do
      add :tags, :map,
        null: false,
        default: %{},
        comment: "桶标签集（jsonb，Key→Value 映射；≤50 个；PutBucketTagging 写入；成本分配标签）"
    end
  end
end
