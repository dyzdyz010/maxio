defmodule Maxio.Config.RuntimeConfig do
  @moduledoc """
  运行时配置覆盖值的当前状态行（每个白名单键一行，设计 D1）。

  值统一包成 `%{"v" => 值}` 而不是裸写进 jsonb：jsonb 顶层必须是 object 才能稳定承载
  标量 / 列表 / map 三种形态，包一层让"存的是什么类型"由 `Maxio.Config.Schema` 单独说了算，
  而不是靠 jsonb 的动态类型去猜（铁律 1：统一数据契约）。
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "runtime_configs" do
    field :subsystem, :string
    field :key, :string
    field :value, :map
    field :previous_value, :map
    field :version, :integer, default: 1
    field :apply_mode, :string
    field :updated_by, :string
    field :source, :string

    timestamps(type: :utc_datetime_usec)
  end

  # 与迁移里的 CHECK 约束同集合；DB 是最后一道边界，这里是第一道。
  @apply_modes ~w(hot next_cycle restart)
  @sources ~w(admin_api cli console system)

  @required [:subsystem, :key, :value, :version, :apply_mode, :source]
  @optional [:previous_value, :updated_by]

  @doc "白名单：合法的 apply 模式。"
  @spec apply_modes() :: [String.t()]
  def apply_modes, do: @apply_modes

  @doc "白名单：合法的变更来源通道。"
  @spec sources() :: [String.t()]
  def sources, do: @sources

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(config, attrs) do
    config
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:apply_mode, @apply_modes)
    |> validate_inclusion(:source, @sources)
    |> validate_number(:version, greater_than_or_equal_to: 1)
    |> unique_constraint([:subsystem, :key], name: :runtime_configs_subsystem_key_index)
  end
end
