defmodule Maxio.Repo.Migrations.AddChecksumToObjects do
  use Ecto.Migration

  def change do
    alter table(:objects) do
      add :checksum, :map,
        comment:
          "S3 modeled checksum 元数据；仅保存客户端通过 x-amz-checksum-* 或校验 trailer 声明并已验证的对象级 checksum，供 GetObjectAttributes 返回"
    end
  end
end
