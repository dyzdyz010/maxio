defmodule Maxio.Repo.Migrations.CreateMfaDevices do
  use Ecto.Migration

  def up do
    create table(:mfa_devices,
             primary_key: false,
             comment: "S3 MFA Delete 与 STS MFA 上下文使用的本地 MFA 设备登记表；支持绑定 root 或 IAM user 的 TOTP 设备"
           ) do
      add :id, :binary_id, primary_key: true, comment: "MFA 设备 UUID 主键"

      add :principal_arn, :string,
        null: false,
        comment: "设备绑定的 principal ARN；S3 MFA Delete 仍只接受 root，STS 可绑定 IAM user"

      add :principal_type, :string,
        null: false,
        default: "root",
        comment: "设备绑定 principal 类型；有效值为 root 或 iam_user"

      add :serial, :string,
        null: false,
        comment: "x-amz-mfa header 或 STS SerialNumber 的 serial 部分；请求校验时必须精确匹配"

      add :device_name, :string,
        null: false,
        comment: "运维可读设备名称；同一 principal 下唯一"

      add :kind, :string,
        null: false,
        default: "totp",
        comment: "MFA 设备类型；当前仅支持 totp"

      add :status, :string,
        null: false,
        default: "pending",
        comment: "设备状态：pending 待激活，active 可用于 MFA 校验，disabled 已停用保留审计"

      add :secret_envelope, :map,
        null: false,
        comment: "TOTP seed 的 AES-GCM 加密信封；不保存明文 Base32 secret，CLI 创建时仅一次性回显"

      add :algorithm, :string,
        null: false,
        default: "sha1",
        comment: "TOTP HMAC 算法；当前固定 sha1 以兼容 RFC 6238/AWS MFA 设备"

      add :digits, :integer,
        null: false,
        default: 6,
        comment: "TOTP 动态口令位数；S3 x-amz-mfa 当前固定 6 位"

      add :period_seconds, :integer,
        null: false,
        default: 30,
        comment: "TOTP 时间步长秒数；默认 30 秒"

      add :drift_steps, :integer,
        null: false,
        default: 1,
        comment: "验证允许的前后时间步漂移窗口；默认当前步前后各 1 步"

      add :last_accepted_step, :bigint, comment: "最近一次已消费的 TOTP 时间步；通过条件 UPDATE 防止同一 code 并发重放"

      add :confirmed_at, :utc_datetime_usec, comment: "设备从 pending 成功激活的时间"
      add :last_used_at, :utc_datetime_usec, comment: "最近一次成功消费 MFA code 的时间"
      add :disabled_at, :utc_datetime_usec, comment: "设备停用时间；停用后不再参与 verifier"

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:mfa_devices, [:serial],
             name: :mfa_devices_serial_index,
             comment: "按 x-amz-mfa serial 全局唯一查找 MFA 设备"
           )

    create unique_index(:mfa_devices, [:principal_arn, :device_name],
             name: :mfa_devices_principal_device_name_index,
             comment: "同一 principal 下设备名称唯一，避免运维误识别"
           )

    create index(:mfa_devices, [:principal_arn, :status],
             name: :mfa_devices_principal_status_index,
             comment: "按 principal 和状态列出 active/pending/disabled MFA 设备"
           )

    execute("COMMENT ON COLUMN mfa_devices.inserted_at IS 'MFA 设备记录创建时间'")
    execute("COMMENT ON COLUMN mfa_devices.updated_at IS 'MFA 设备记录最后更新时间'")
  end

  def down do
    execute("COMMENT ON COLUMN mfa_devices.updated_at IS NULL")
    execute("COMMENT ON COLUMN mfa_devices.inserted_at IS NULL")

    drop_if_exists index(:mfa_devices, [:principal_arn, :status],
                     name: :mfa_devices_principal_status_index
                   )

    drop_if_exists index(:mfa_devices, [:principal_arn, :device_name],
                     name: :mfa_devices_principal_device_name_index
                   )

    drop_if_exists index(:mfa_devices, [:serial], name: :mfa_devices_serial_index)

    drop table(:mfa_devices)
  end
end
