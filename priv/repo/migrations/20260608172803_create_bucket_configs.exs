defmodule Maxio.Repo.Migrations.CreateBucketConfigs do
  use Ecto.Migration

  def change do
    create table(:bucket_configs,
             primary_key: false,
             comment: "每桶一行的高级特性配置载体：CORS / Lifecycle / 默认加密配置各存一个 jsonb（解析校验后的结构），按需 upsert"
           ) do
      add :id, :binary_id, primary_key: true, comment: "主键（UUID）"

      add :bucket_name, :string,
        null: false,
        comment: "桶名（唯一；与 buckets.name 对应，应用层保证桶存在）"

      add :cors, :map,
        null: true,
        comment: "CORS 配置（jsonb 数组）：[CORSRule]，每 rule = %{id, allowed_methods, allowed_origins, allowed_headers, expose_headers, max_age_seconds}；nil=未配置"

      add :lifecycle, :map,
        null: true,
        comment: "生命周期配置（jsonb 数组）：[Rule]（仅存储+校验+出站；后台过期执行 DEFER 未实现，见 README）；nil=未配置"

      add :encryption, :map,
        null: true,
        comment: "默认加密配置（jsonb）：%{algorithm:AES256, kms_key_id, bucket_key_enabled}（MVP 仅 SSE-S3 AES256 生效）；nil=未配置"

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:bucket_configs, [:bucket_name],
             comment: "桶名唯一索引（每桶至多一行高级配置）"
           )
  end
end
