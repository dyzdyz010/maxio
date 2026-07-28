defmodule Maxio.Repo.Migrations.AddObjectPartsToObjects do
  use Ecto.Migration

  def change do
    alter table(:multipart_parts) do
      add :checksum, :map,
        comment:
          "S3 UploadPart 已验证的 modeled checksum 元数据；CompleteMultipartUpload 时复制进最终对象 object_parts"
    end

    alter table(:objects) do
      add :object_parts, :map,
        comment: "已完成分段上传对象的 S3 可见 part 清单，供 GetObjectAttributes ObjectParts 分页返回；非分段对象为空"
    end
  end
end
