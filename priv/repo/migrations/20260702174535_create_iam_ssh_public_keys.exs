defmodule Maxio.Repo.Migrations.CreateIamSshPublicKeys do
  use Ecto.Migration

  def up do
    create table(:iam_ssh_public_keys,
             primary_key: false,
             comment: "IAM 用户 SSH 公钥表；保存 UploadSSHPublicKey 上传的 RSA 公钥正文、指纹与状态"
           ) do
      add :id, :binary_id, primary_key: true, comment: "IAM SSH public key UUID 主键"

      add :ssh_public_key_id, :string,
        null: false,
        comment: "AWS IAM SSH public key id；形如 APKA 开头的 20 位标识"

      add :user_arn,
          references(:iam_users,
            column: :user_arn,
            type: :string,
            on_update: :update_all,
            on_delete: :restrict
          ),
          null: false,
          comment: "SSH 公钥所属 IAM 用户 ARN；用户重命名时级联更新"

      add :ssh_public_key_body, :text,
        null: false,
        comment: "上传时规范化后的 SSH 公钥正文；Upload/List/Get 会按请求编码返回"

      add :ssh_public_key_body_ssh, :text,
        null: false,
        comment: "OpenSSH ssh-rsa 编码的规范化公钥正文"

      add :ssh_public_key_body_pem, :text,
        null: false,
        comment: "PEM 编码的 PUBLIC KEY 公钥正文"

      add :fingerprint_md5, :string,
        null: false,
        comment: "OpenSSH 公钥 blob 的 MD5 指纹；用于同一用户下重复公钥检测"

      add :status, :string,
        null: false,
        default: "Active",
        comment: "IAM SSH public key 状态；Active 或 Inactive"

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:iam_ssh_public_keys, [:ssh_public_key_id],
             name: :iam_ssh_public_keys_key_id_index,
             comment: "IAM SSH public key id 全局唯一索引"
           )

    create unique_index(:iam_ssh_public_keys, [:user_arn, :fingerprint_md5],
             name: :iam_ssh_public_keys_user_fingerprint_index,
             comment: "同一 IAM 用户下 SSH 公钥 MD5 指纹唯一索引；重复上传返回 DuplicateSSHPublicKey"
           )

    create index(:iam_ssh_public_keys, [:user_arn, :inserted_at],
             name: :iam_ssh_public_keys_user_index,
             comment: "按 IAM 用户列举 SSH public keys 的索引"
           )

    create constraint(:iam_ssh_public_keys, :iam_ssh_public_keys_status_check,
             check: "status IN ('Active', 'Inactive')"
           )

    execute("""
    COMMENT ON CONSTRAINT iam_ssh_public_keys_status_check
    ON iam_ssh_public_keys IS
    '限制 SSH public key 状态只能为 AWS IAM 支持的 Active 或 Inactive'
    """)

    execute("""
    COMMENT ON CONSTRAINT iam_ssh_public_keys_user_arn_fkey
    ON iam_ssh_public_keys IS
    'IAM SSH public key 绑定用户 ARN 的外键；用户重命名时级联更新，用户删除前必须先删除公钥'
    """)

    execute("COMMENT ON COLUMN iam_ssh_public_keys.inserted_at IS 'IAM SSH public key 上传时间'")
    execute("COMMENT ON COLUMN iam_ssh_public_keys.updated_at IS 'IAM SSH public key 最后更新时间'")
  end

  def down do
    execute("COMMENT ON COLUMN iam_ssh_public_keys.updated_at IS NULL")
    execute("COMMENT ON COLUMN iam_ssh_public_keys.inserted_at IS NULL")

    execute(
      "COMMENT ON CONSTRAINT iam_ssh_public_keys_user_arn_fkey ON iam_ssh_public_keys IS NULL"
    )

    execute(
      "COMMENT ON CONSTRAINT iam_ssh_public_keys_status_check ON iam_ssh_public_keys IS NULL"
    )

    drop_if_exists constraint(:iam_ssh_public_keys, :iam_ssh_public_keys_status_check)

    drop_if_exists index(:iam_ssh_public_keys, [:user_arn, :inserted_at],
                     name: :iam_ssh_public_keys_user_index
                   )

    drop_if_exists index(:iam_ssh_public_keys, [:user_arn, :fingerprint_md5],
                     name: :iam_ssh_public_keys_user_fingerprint_index
                   )

    drop_if_exists index(:iam_ssh_public_keys, [:ssh_public_key_id],
                     name: :iam_ssh_public_keys_key_id_index
                   )

    drop table(:iam_ssh_public_keys)
  end
end
