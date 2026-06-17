defmodule Maxio.Repo.Migrations.AddRestoreFieldsToObjects do
  use Ecto.Migration

  def change do
    alter table(:objects) do
      add :restore_status, :string,
        comment: "S3 RestoreObject 恢复状态：ongoing 或 restored；NULL 表示未发起恢复或不适用"

      add :restore_expiry, :utc_datetime_usec,
        comment: "S3 RestoreObject 临时恢复副本过期时间；仅 restore_status=restored 时用于 x-amz-restore 回显"
    end
  end
end
