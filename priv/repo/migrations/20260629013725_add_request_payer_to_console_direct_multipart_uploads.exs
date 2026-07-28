defmodule Maxio.Repo.Migrations.AddRequestPayerToConsoleDirectMultipartUploads do
  use Ecto.Migration

  def up do
    alter table(:console_direct_multipart_uploads) do
      add :request_payer, :boolean,
        null: false,
        default: false,
        comment:
          "本 direct multipart 会话是否由 Console 签发 x-amz-request-payer=requester；用于恢复后续 part/list/complete/abort presign"
    end
  end

  def down do
    alter table(:console_direct_multipart_uploads) do
      remove :request_payer
    end
  end
end
