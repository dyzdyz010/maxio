defmodule Maxio.Repo.Migrations.AddTagsToMultipartUploads do
  use Ecto.Migration

  def up do
    alter table(:multipart_uploads) do
      add :tags, :map,
        null: false,
        default: %{},
        comment: "分段上传会话捕获的最终对象标签集；来自 CreateMultipartUpload 的 x-amz-tagging，Complete 时写入对象版本"
    end
  end

  def down do
    alter table(:multipart_uploads) do
      remove :tags
    end
  end
end
