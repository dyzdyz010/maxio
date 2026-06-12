defmodule Maxio.Repo.Migrations.AddAclFieldsToMultipartUploads do
  use Ecto.Migration

  def change do
    alter table(:multipart_uploads) do
      add :acl_canned, :string,
        null: false,
        default: "private",
        comment: "分段上传会话捕获的 canned ACL；Complete 时写入最终对象及 sidecar"

      add :acl_grants, :map,
        null: false,
        default: %{"grants" => []},
        comment: "分段上传会话捕获的显式 ACL grant 文档（x-amz-grant-*）；Complete 时写入最终对象及 sidecar"
    end
  end
end
