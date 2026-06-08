defmodule Maxio.Repo.Migrations.AddAclToBucketsAndObjects do
  use Ecto.Migration

  def change do
    alter table(:buckets) do
      add :acl_canned, :string,
        null: false,
        default: "private",
        comment:
          "桶的 canned ACL 名（private|public-read|public-read-write|authenticated-read 等；GetBucketAcl 展开为 grant XML，授权时折叠为等价 statement）"
    end

    alter table(:objects) do
      add :acl_canned, :string,
        null: false,
        default: "private",
        comment: "对象的 canned ACL 名（默认 private；PutObject 的 x-amz-acl 写入；授权时折叠为等价 statement）"
    end
  end
end
