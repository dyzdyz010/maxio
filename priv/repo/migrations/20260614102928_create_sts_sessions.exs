defmodule Maxio.Repo.Migrations.CreateStsSessions do
  use Ecto.Migration

  def up do
    create table(:sts_sessions,
             primary_key: false,
             comment: "STS 临时会话凭据表；与长期 access_keys 分离，避免污染长期凭据生命周期、root 计数和控制台列表"
           ) do
      add :id, :binary_id, primary_key: true, comment: "STS 会话 UUID 主键"

      add :access_key_id, :string,
        null: false,
        comment: "临时 Access Key ID；SigV4 Credential 首段，通常使用 ASIA 前缀"

      add :secret_key, :string,
        null: false,
        comment: "临时 Secret Access Key；MVP 明文保存，后续统一接入 at-rest 加密治理"

      add :session_token_sha256, :string,
        null: false,
        comment: "Session Token 的 SHA256 十六进制摘要；数据库绝不保存明文 session token"

      add :issuer_access_key_id, :string,
        null: false,
        comment: "签发该临时凭据的长期 Access Key ID，用于审计和撤销定位"

      add :principal_arn, :string,
        null: false,
        comment: "临时凭据对应的授权 principal ARN；GetSessionToken 为父 principal ARN，AssumeRole 为角色 ARN"

      add :principal_type, :string,
        null: false,
        comment: "临时凭据授权 principal 类型：root、iam_user 或 assumed_role"

      add :session_name, :string,
        null: false,
        comment: "会话名称；用于 CLI、日志和审计展示"

      add :status, :string,
        null: false,
        default: "active",
        comment: "会话状态：active 可用，revoked 已撤销；非 active 一律鉴权拒绝"

      add :issued_at, :utc_datetime_usec,
        null: false,
        comment: "临时凭据签发时间"

      add :expires_at, :utc_datetime_usec,
        null: false,
        comment: "临时凭据过期时间；鉴权时使用请求参考时钟 fail-closed 校验"

      add :revoked_at, :utc_datetime_usec, comment: "临时凭据撤销时间；未撤销时为空"

      add :tags, :map,
        null: false,
        default: %{},
        comment: "继承自父 principal 的标签快照，用于当前 IAM 条件键评估"

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:sts_sessions, [:access_key_id],
             name: :sts_sessions_access_key_id_index,
             comment: "临时 Access Key ID 全局唯一索引；鉴权按此定位 STS 会话"
           )

    create index(:sts_sessions, [:issuer_access_key_id],
             name: :sts_sessions_issuer_access_key_id_index,
             comment: "按签发方 Access Key ID 列出和审计临时会话"
           )

    create index(:sts_sessions, [:principal_arn],
             name: :sts_sessions_principal_arn_index,
             comment: "按真实 principal ARN 列出临时会话"
           )

    create index(:sts_sessions, [:status, :expires_at],
             name: :sts_sessions_status_expires_at_index,
             comment: "按状态和过期时间扫描可用或待清理的临时会话"
           )

    execute("COMMENT ON COLUMN sts_sessions.inserted_at IS 'STS 会话记录创建时间'")
    execute("COMMENT ON COLUMN sts_sessions.updated_at IS 'STS 会话记录最后更新时间'")
  end

  def down do
    execute("COMMENT ON COLUMN sts_sessions.updated_at IS NULL")
    execute("COMMENT ON COLUMN sts_sessions.inserted_at IS NULL")

    drop_if_exists index(:sts_sessions, [:status, :expires_at],
                     name: :sts_sessions_status_expires_at_index
                   )

    drop_if_exists index(:sts_sessions, [:principal_arn], name: :sts_sessions_principal_arn_index)

    drop_if_exists index(:sts_sessions, [:issuer_access_key_id],
                     name: :sts_sessions_issuer_access_key_id_index
                   )

    drop_if_exists index(:sts_sessions, [:access_key_id], name: :sts_sessions_access_key_id_index)

    drop table(:sts_sessions)
  end
end
