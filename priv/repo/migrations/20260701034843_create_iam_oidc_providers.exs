defmodule Maxio.Repo.Migrations.CreateIamOidcProviders do
  use Ecto.Migration

  def up do
    create table(:iam_oidc_providers,
             primary_key: false,
             comment: "IAM OIDC 身份提供商表；用于 STS AssumeRoleWithWebIdentity 的 provider 元数据与 JWKS 快照"
           ) do
      add :id, :binary_id, primary_key: true, comment: "IAM OIDC provider UUID 主键"

      add :provider_arn, :text,
        null: false,
        comment: "OIDC provider ARN；格式为 arn:aws:iam:::oidc-provider/<issuer_host_path>"

      add :issuer_url, :text,
        null: false,
        comment: "OIDC issuer HTTPS URL；规范化后不含末尾斜杠、query 或 fragment"

      add :issuer_host_path, :text,
        null: false,
        comment: "由 issuer 派生的 host/path；作为 trust policy Principal.Federated 的资源后缀"

      add :client_ids, {:array, :string},
        null: false,
        default: [],
        comment: "允许的 OIDC audience/client_id 列表；WebIdentity token aud 必须命中其中之一"

      add :thumbprints, {:array, :string},
        null: false,
        default: [],
        comment: "OIDC provider 证书 thumbprint 列表；当前作为 IAM API 元数据持久化，TLS pinning parity 后续实现"

      add :jwks, :map,
        null: false,
        default: %{},
        comment: "OIDC provider JWKS 快照；STS WebIdentity 验签只使用已持久化 key，不在请求路径拉取网络"

      add :jwks_fetched_at, :utc_datetime_usec, comment: "JWKS 快照最近一次成功发现/更新的时间；为空表示尚无可用 key"

      add :discovery_document, :map,
        null: false,
        default: %{},
        comment: "OIDC discovery document 快照；用于运维取证，不保存 secret"

      add :status, :string,
        null: false,
        default: "active",
        comment: "provider 状态：active | disabled；非 active provider 不参与 STS WebIdentity 验证"

      add :tags, :map,
        null: false,
        default: %{},
        comment: "provider 标签；当前用于 IAM API 展示，Tag/Untag API 后续实现"

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:iam_oidc_providers, [:provider_arn],
             name: :iam_oidc_providers_provider_arn_index,
             comment: "OIDC provider ARN 全局唯一索引；trust policy 按 ARN 精确引用"
           )

    create unique_index(:iam_oidc_providers, [:issuer_host_path],
             name: :iam_oidc_providers_issuer_host_path_index,
             comment: "OIDC issuer host/path 全局唯一索引；防止同 issuer 多 provider 歧义"
           )

    execute("COMMENT ON COLUMN iam_oidc_providers.inserted_at IS 'IAM OIDC provider 记录创建时间'")

    execute("COMMENT ON COLUMN iam_oidc_providers.updated_at IS 'IAM OIDC provider 记录最后更新时间'")
  end

  def down do
    execute("COMMENT ON COLUMN iam_oidc_providers.updated_at IS NULL")
    execute("COMMENT ON COLUMN iam_oidc_providers.inserted_at IS NULL")

    drop_if_exists index(:iam_oidc_providers, [:issuer_host_path],
                     name: :iam_oidc_providers_issuer_host_path_index
                   )

    drop_if_exists index(:iam_oidc_providers, [:provider_arn],
                     name: :iam_oidc_providers_provider_arn_index
                   )

    drop table(:iam_oidc_providers)
  end
end
