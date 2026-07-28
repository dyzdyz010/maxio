defmodule Maxio.Repo.Migrations.CreateIamServerCertificates do
  use Ecto.Migration

  def up do
    create table(:iam_server_certificates,
             primary_key: false,
             comment: "IAM server certificate 表；保存上传证书元数据、证书正文、证书链与私钥指纹，私钥原文不持久化"
           ) do
      add :id, :binary_id, primary_key: true, comment: "IAM server certificate UUID 主键"

      add :server_certificate_name, :string,
        null: false,
        comment: "IAM server certificate 名称；本地单账户内唯一"

      add :server_certificate_arn, :string,
        null: false,
        comment: "IAM server certificate ARN；形如 arn:aws:iam:::server-certificate/<path>/<name>"

      add :path, :string,
        null: false,
        default: "/",
        comment: "IAM server certificate 路径；以 / 开头和结尾，支持 IAM path 字符"

      add :certificate_body, :text,
        null: false,
        comment: "PEM 编码的 X.509 叶子证书正文；GetServerCertificate 会返回"

      add :certificate_chain, :text, comment: "PEM 编码的中间证书链；未上传时为 NULL，GetServerCertificate 可返回"

      add :private_key_fingerprint, :string,
        null: false,
        comment: "上传私钥的 SHA256 指纹；用于审计与防私钥原文持久化，不可还原私钥"

      add :expiration, :utc_datetime_usec,
        null: false,
        comment: "从叶子证书 NotAfter 解析出的过期时间"

      add :tags, :map,
        null: false,
        default: %{},
        comment: "IAM server certificate 标签；用于 Query API tag round-trip 与后续 Console 展示"

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:iam_server_certificates, [:server_certificate_name],
             name: :iam_server_certificates_name_index,
             comment: "IAM server certificate 名称全局唯一索引"
           )

    execute("""
    CREATE UNIQUE INDEX iam_server_certificates_name_ci_index
    ON iam_server_certificates (lower(server_certificate_name))
    """)

    execute("""
    COMMENT ON INDEX iam_server_certificates_name_ci_index IS
    'IAM server certificate 名称大小写不敏感唯一索引；防止仅大小写不同的重复证书'
    """)

    create unique_index(:iam_server_certificates, [:server_certificate_arn],
             name: :iam_server_certificates_arn_index,
             comment: "IAM server certificate ARN 全局唯一索引"
           )

    create index(:iam_server_certificates, [:path, :server_certificate_name],
             name: :iam_server_certificates_path_name_index,
             comment: "按 path/name 枚举 server certificates；用于 ListServerCertificates PathPrefix"
           )

    execute(
      "COMMENT ON COLUMN iam_server_certificates.inserted_at IS 'IAM server certificate 上传时间'"
    )

    execute(
      "COMMENT ON COLUMN iam_server_certificates.updated_at IS 'IAM server certificate 最后更新时间'"
    )
  end

  def down do
    execute("COMMENT ON COLUMN iam_server_certificates.updated_at IS NULL")
    execute("COMMENT ON COLUMN iam_server_certificates.inserted_at IS NULL")

    drop_if_exists index(:iam_server_certificates, [:path, :server_certificate_name],
                     name: :iam_server_certificates_path_name_index
                   )

    drop_if_exists index(:iam_server_certificates, [:server_certificate_arn],
                     name: :iam_server_certificates_arn_index
                   )

    execute("COMMENT ON INDEX iam_server_certificates_name_ci_index IS NULL")
    execute("DROP INDEX IF EXISTS iam_server_certificates_name_ci_index")

    drop_if_exists index(:iam_server_certificates, [:server_certificate_name],
                     name: :iam_server_certificates_name_index
                   )

    drop table(:iam_server_certificates)
  end
end
