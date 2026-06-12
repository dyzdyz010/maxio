defmodule Maxio.Repo.Migrations.AddAclGrantsToBucketsAndObjects do
  use Ecto.Migration

  def change do
    alter table(:buckets) do
      add :acl_grants, :map,
        null: false,
        default: %{"grants" => []},
        comment:
          "桶的显式 ACL grant 文档（jsonb：%{grants: [...]}；元素含 grantee.type/id/uri/display_name 与 permission；为空时按 acl_canned 展开）"
    end

    alter table(:objects) do
      add :acl_grants, :map,
        null: false,
        default: %{"grants" => []},
        comment:
          "对象的显式 ACL grant 文档（jsonb：%{grants: [...]}；由 x-amz-grant-* 或 ACL XML 写入；为空时按 acl_canned 展开）"
    end
  end
end
