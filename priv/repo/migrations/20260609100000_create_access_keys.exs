defmodule Maxio.Repo.Migrations.CreateAccessKeys do
  use Ecto.Migration

  def change do
    create table(:access_keys,
             primary_key: false,
             comment:
               "S3 访问密钥（SigV4 凭据）：每个 access key 一行；root 由 boot 幂等引导，其余经 mix maxio.iam.create_key 创建"
           ) do
      add :id, :binary_id, primary_key: true, comment: "访问密钥主键（UUID）"

      add :access_key_id, :string,
        null: false,
        comment: "Access Key ID（SigV4 Credential 的首段；查 secret 与 principal 的键）"

      add :secret_key, :string,
        null: false,
        comment: "Secret Access Key（SigV4 签名密钥；MVP 明文存储——at-rest 加密留后续里程碑，见计划 defer）"

      add :principal_arn, :string,
        null: false,
        comment: "该密钥对应的 principal ARN（root=arn:aws:iam:::root；iam_user=arn:aws:iam:::user/<ak>）"

      add :type, :string,
        null: false,
        default: "iam_user",
        comment: "principal 类型：root | iam_user（决定 Authz 是否走 root 全权短路）"

      add :status, :string,
        null: false,
        default: "active",
        comment: "密钥状态：active | inactive（inactive 视同不存在，鉴权拒绝）"

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:access_keys, [:access_key_id],
             comment: "Access Key ID 全局唯一索引（鉴权按此 O(1) 查 secret/principal）"
           )
  end
end
