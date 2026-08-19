defmodule Maxio.Config.RuntimeConfigAudit do
  @moduledoc """
  运行时配置变更审计流水（只追加，设计 D4 第 5d 步）。

  `reset` 操作把配置行整行删除，但审计行仍写 `to_version = from_version + 1`：审计的版本序
  必须单调，否则"这个键最后一次动作是什么"在回滚取证时无法排序。审计行不设外键——
  配置行被 reset 删掉之后，它的历史仍必须留存。
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Maxio.Config.RuntimeConfig

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "runtime_config_audits" do
    field :subsystem, :string
    field :key, :string
    field :operation, :string
    field :old_value, :map
    field :new_value, :map
    field :from_version, :integer
    field :to_version, :integer
    field :apply_mode, :string
    field :principal_arn, :string
    field :access_key_id, :string
    field :request_id, :string
    field :source, :string

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @operations ~w(set reset)

  @required [:subsystem, :key, :operation, :to_version, :apply_mode, :source]
  @optional [
    :old_value,
    :new_value,
    :from_version,
    :principal_arn,
    :access_key_id,
    :request_id
  ]

  @doc "白名单：合法的审计操作。"
  @spec operations() :: [String.t()]
  def operations, do: @operations

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(audit, attrs) do
    audit
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:operation, @operations)
    |> validate_inclusion(:apply_mode, RuntimeConfig.apply_modes())
    |> validate_inclusion(:source, RuntimeConfig.sources())
  end
end
