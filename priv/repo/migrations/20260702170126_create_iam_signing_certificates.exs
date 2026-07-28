defmodule Maxio.Repo.Migrations.CreateIamSigningCertificates do
  use Ecto.Migration

  def up do
    create table(:iam_signing_certificates,
             primary_key: false,
             comment: "IAM 用户/根账号签名证书表；保存 UploadSigningCertificate 上传的 X.509 证书正文和状态"
           ) do
      add :id, :binary_id, primary_key: true, comment: "IAM signing certificate UUID 主键"

      add :certificate_id, :string,
        null: false,
        comment: "AWS IAM signing certificate id；形如 TA 开头的 24 到 128 位标识"

      add :principal_type, :string,
        null: false,
        comment: "证书所属主体类型；root 表示根账号，iam_user 表示显式 IAM 用户"

      add :user_arn,
          references(:iam_users,
            column: :user_arn,
            type: :string,
            on_update: :update_all,
            on_delete: :restrict
          ),
          comment: "证书所属 IAM 用户 ARN；root 证书为 NULL，用户重命名时级联更新"

      add :certificate_body, :text,
        null: false,
        comment: "PEM 编码的 X.509 signing certificate 正文；List/Upload 会原样返回"

      add :certificate_fingerprint_sha256, :string,
        null: false,
        comment: "证书 DER 的 SHA256 指纹；用于全局重复证书检测"

      add :status, :string,
        null: false,
        default: "Active",
        comment: "IAM signing certificate 状态；Active、Inactive 或 Expired"

      add :expiration, :utc_datetime_usec, comment: "从证书 NotAfter 解析出的过期时间；用于上传时 fail-closed 校验"

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:iam_signing_certificates, [:certificate_id],
             name: :iam_signing_certificates_certificate_id_index,
             comment: "IAM signing certificate id 全局唯一索引"
           )

    create unique_index(:iam_signing_certificates, [:certificate_fingerprint_sha256],
             name: :iam_signing_certificates_fingerprint_sha256_index,
             comment: "IAM signing certificate SHA256 指纹全局唯一索引；重复上传返回 DuplicateCertificate"
           )

    create index(:iam_signing_certificates, [:principal_type, :user_arn, :inserted_at],
             name: :iam_signing_certificates_principal_index,
             comment: "按 root/IAM 用户主体列举 signing certificates 的索引"
           )

    create constraint(:iam_signing_certificates, :iam_signing_certificates_principal_type_check,
             check: "principal_type IN ('root', 'iam_user')"
           )

    execute("""
    COMMENT ON CONSTRAINT iam_signing_certificates_principal_type_check
    ON iam_signing_certificates IS
    '限制 signing certificate 主体类型只能为 root 或 iam_user'
    """)

    create constraint(:iam_signing_certificates, :iam_signing_certificates_status_check,
             check: "status IN ('Active', 'Inactive', 'Expired')"
           )

    execute("""
    COMMENT ON CONSTRAINT iam_signing_certificates_status_check
    ON iam_signing_certificates IS
    '限制 signing certificate 状态只能为 AWS IAM 支持的 Active、Inactive、Expired'
    """)

    create constraint(:iam_signing_certificates, :iam_signing_certificates_principal_shape_check,
             check:
               "(principal_type = 'root' AND user_arn IS NULL) OR (principal_type = 'iam_user' AND user_arn IS NOT NULL)"
           )

    execute("""
    COMMENT ON CONSTRAINT iam_signing_certificates_principal_shape_check
    ON iam_signing_certificates IS
    '保证 root 证书没有 user_arn，IAM 用户证书必须绑定 user_arn'
    """)

    execute("""
    COMMENT ON CONSTRAINT iam_signing_certificates_user_arn_fkey
    ON iam_signing_certificates IS
    'IAM signing certificate 绑定用户 ARN 的外键；用户重命名时级联更新，用户删除前必须先删除证书'
    """)

    execute(
      "COMMENT ON COLUMN iam_signing_certificates.inserted_at IS 'IAM signing certificate 上传时间'"
    )

    execute(
      "COMMENT ON COLUMN iam_signing_certificates.updated_at IS 'IAM signing certificate 最后更新时间'"
    )
  end

  def down do
    execute("COMMENT ON COLUMN iam_signing_certificates.updated_at IS NULL")
    execute("COMMENT ON COLUMN iam_signing_certificates.inserted_at IS NULL")

    execute(
      "COMMENT ON CONSTRAINT iam_signing_certificates_user_arn_fkey ON iam_signing_certificates IS NULL"
    )

    execute(
      "COMMENT ON CONSTRAINT iam_signing_certificates_principal_shape_check ON iam_signing_certificates IS NULL"
    )

    execute(
      "COMMENT ON CONSTRAINT iam_signing_certificates_status_check ON iam_signing_certificates IS NULL"
    )

    execute(
      "COMMENT ON CONSTRAINT iam_signing_certificates_principal_type_check ON iam_signing_certificates IS NULL"
    )

    drop_if_exists constraint(
                     :iam_signing_certificates,
                     :iam_signing_certificates_principal_shape_check
                   )

    drop_if_exists constraint(:iam_signing_certificates, :iam_signing_certificates_status_check)

    drop_if_exists constraint(
                     :iam_signing_certificates,
                     :iam_signing_certificates_principal_type_check
                   )

    drop_if_exists index(:iam_signing_certificates, [:principal_type, :user_arn, :inserted_at],
                     name: :iam_signing_certificates_principal_index
                   )

    drop_if_exists index(:iam_signing_certificates, [:certificate_fingerprint_sha256],
                     name: :iam_signing_certificates_fingerprint_sha256_index
                   )

    drop_if_exists index(:iam_signing_certificates, [:certificate_id],
                     name: :iam_signing_certificates_certificate_id_index
                   )

    drop table(:iam_signing_certificates)
  end
end
