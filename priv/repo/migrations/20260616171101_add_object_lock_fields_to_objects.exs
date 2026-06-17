defmodule Maxio.Repo.Migrations.AddObjectLockFieldsToObjects do
  use Ecto.Migration

  def change do
    alter table(:objects) do
      add :object_lock_mode, :string,
        comment: "S3 Object Lock 保留模式：GOVERNANCE 或 COMPLIANCE；NULL 表示未设置对象级保留"

      add :object_lock_retain_until, :utc_datetime_usec,
        comment: "S3 Object Lock 保留截止时间；到期前受保留模式保护；NULL 表示未设置对象级保留期限"

      add :object_lock_legal_hold, :string,
        comment: "S3 Object Lock Legal Hold 状态：ON 或 OFF；NULL 表示未显式设置"
    end
  end
end
