defmodule Maxio.Repo.Migrations.UpdateStsSessionSecretComment do
  use Ecto.Migration

  def up do
    execute "ALTER TABLE sts_sessions ALTER COLUMN secret_key TYPE text"

    execute """
    COMMENT ON COLUMN sts_sessions.secret_key IS
    'STS 临时 Secret Access Key 的本地 AES-GCM envelope 文本；旧明文行仅用于滚动升级兼容，鉴权读取时按临时 access_key_id 作为 AEAD AAD 解包'
    """
  end

  def down do
    execute """
    COMMENT ON COLUMN sts_sessions.secret_key IS
    '临时 Secret Access Key；MVP 明文保存，后续统一接入 at-rest 加密治理'
    """
  end
end
