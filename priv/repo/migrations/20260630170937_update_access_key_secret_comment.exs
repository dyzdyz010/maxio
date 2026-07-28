defmodule Maxio.Repo.Migrations.UpdateAccessKeySecretComment do
  use Ecto.Migration

  def up do
    execute "ALTER TABLE access_keys ALTER COLUMN secret_key TYPE text"

    execute """
    COMMENT ON COLUMN access_keys.secret_key IS
    'Secret Access Key 的本地 AES-GCM envelope 文本；旧明文行仅用于滚动升级兼容，鉴权读取时按 access_key_id 作为 AEAD AAD 解包'
    """
  end

  def down do
    execute """
    COMMENT ON COLUMN access_keys.secret_key IS
    'Secret Access Key（SigV4 签名密钥；MVP 明文存储——at-rest 加密留后续里程碑，见计划 defer）'
    """
  end
end
