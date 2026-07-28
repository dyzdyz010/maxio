defmodule Maxio.Repo.Migrations.AddQuotaToBucketConfigs do
  use Ecto.Migration

  def change do
    execute(
      """
      ALTER TABLE bucket_configs
        ADD COLUMN IF NOT EXISTS quota jsonb
      """,
      """
      ALTER TABLE bucket_configs
        DROP COLUMN IF EXISTS quota
      """
    )

    execute(
      """
      COMMENT ON COLUMN bucket_configs.quota IS
        '桶配额配置（jsonb）：%{type: hard, size_bytes: 正整数}；nil=未配置。写路径按所有已提交非 delete-marker 版本的逻辑字节做 hard quota fail-closed 校验'
      """,
      "COMMENT ON COLUMN bucket_configs.quota IS NULL"
    )
  end
end
