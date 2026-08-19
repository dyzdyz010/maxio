defmodule Maxio.Config.CorruptValueError do
  @moduledoc """
  PG 里某个**白名单内**配置键的值无法按 `Maxio.Config.Schema` 声明的类型解码。

  这不是"配置写错了"，而是**写路径校验被绕过了**（例如有人直接 UPDATE 了 runtime_configs）。
  绝不允许静默替换成默认值继续跑：那会让一个被篡改过的配置面看起来完全健康。
  `Maxio.Config.Store` 在物化快照时遇到它一律 fail-fast（设计 §5）。

  与之相对的是**白名单外**的 orphan 键（例如回滚到旧版本二进制后 DB 里留着新键）：
  那不是完整性问题，只需忽略 + 结构化告警 + 在 `mix maxio.config.status` 里报出来。
  """

  defexception [:subsystem, :key, :reason]

  @type t :: %__MODULE__{subsystem: atom(), key: atom(), reason: String.t()}

  @impl true
  def message(%__MODULE__{subsystem: subsystem, key: key, reason: reason}) do
    "runtime config #{subsystem}.#{key} stored in Postgres cannot be decoded by " <>
      "Maxio.Config.Schema: #{reason}. This means the write path validation was bypassed " <>
      "(hand-edited runtime_configs row?). Fix or delete the row; maxio refuses to boot a " <>
      "config snapshot it cannot interpret."
  end
end
