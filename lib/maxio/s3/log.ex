defmodule Maxio.S3.Log do
  @moduledoc """
  S3 管线统一结构化日志辅助（AGENTS.md 铁律 4：后端无 GUI，必须 CLI + 结构化日志可观测）。

  所有 S3 关键阶段（鉴权 / 分发 / put / get / 错误）经此模块打日志，统一把
  request_id / bucket / key / action / auth_type / reason 等放进 Logger metadata，
  便于按 request_id 串联一次请求的全链路。绝不静默——签名/校验失败必须经 warn/2 留痕。
  """
  require Logger

  @md_keys [
    :request_id,
    :bucket,
    :key,
    :version_id,
    :action,
    :required_action,
    :method,
    :auth_type,
    :payload_mode,
    :reason,
    :code,
    :status,
    :size,
    :expires,
    :resource,
    :decision,
    :policy_source,
    :principal_type,
    :endpoint_source,
    :principal_arn,
    :target_principal_arn,
    :user_name,
    :user_arn,
    :access_key_id,
    :account_id,
    :owner,
    :authenticated,
    :provider_arn,
    :issuer_url,
    :issuer_host_path,
    :mfa_serial_hash,
    :mfa_device_status,
    :mfa_outcome,
    :mfa_reason,
    :mfa_window_offset,
    :event_name,
    :write_authority,
    :matched_tasks,
    :destination_bucket,
    :replication_status,
    :destination_type,
    :destination_arn,
    :configuration_id,
    :notification_event_id,
    :attempts,
    # MinIO admin control-plane request fields. Policy documents and credentials
    # are intentionally absent from this allowlist.
    :admin_action,
    :admin_endpoint,
    :target_policy,
    :target_user,
    :user_count,
    :enabled_count,
    :disabled_count,
    :credential_bearing_count,
    :minio_view_partial_count,
    :omitted_non_root_path_policies,
    :credential_bearing,
    :managed_policies,
    :inline_policies,
    :group_inherited,
    :role_attached,
    :minio_view_partial,
    :omitted_reason,
    :surface,
    # 运行时配置面固定字段（设计 §6）。formatter 侧的 metadata 白名单必须同步放行，
    # 否则结构化字段被静默丢弃——ObjectMutation 已有前车之鉴。
    :config_subsystem,
    :config_key,
    :config_version,
    :config_apply_mode,
    :config_source,
    :config_digest,
    :config_local_digest
  ]

  @doc "把关键字参数中已知的 S3 元数据键提取为 Logger metadata keyword 列表。"
  @spec context(keyword()) :: keyword()
  def context(fields) when is_list(fields) do
    Enum.filter(fields, fn {k, _v} -> k in @md_keys end)
  end

  @doc "info 级结构化日志。"
  @spec info(String.t(), keyword()) :: :ok
  def info(message, fields \\ []) do
    Logger.info(message, context(fields))
  end

  @doc "warning 级结构化日志（用于签名失败 / 授权拒绝 / 校验失败等非静默场景）。"
  @spec warn(String.t(), keyword()) :: :ok
  def warn(message, fields \\ []) do
    Logger.warning(message, context(fields))
  end

  @doc "error 级结构化日志（兜底 500 等）。"
  @spec error(String.t(), keyword()) :: :ok
  def error(message, fields \\ []) do
    Logger.error(message, context(fields))
  end
end
