defmodule Maxio.Test.ConfigConflictRepo do
  @moduledoc """
  测试替身：在合法 subsystem advisory-lock 事务里注入 defensive unique-row conflict。

  subsystem advisory lock 已使正式 writer 之间的首次 insert race 不可达，但 coordinator 仍保留
  unique constraint 到 `:config_version_conflict` 的防御性归一。该替身必须先在真实 Repo transaction
  connection 上执行逐字 advisory SQL、真实读取当前行，再只替换 `insert_or_update/2` 的 PG 冲突结果；
  绝不允许为了注入冲突而绕过锁边界。
  """

  alias Maxio.Config.RuntimeConfig
  alias Maxio.Repo

  @advisory_lock_sql "SELECT pg_advisory_xact_lock(1297638214, hashtext($1))"

  @doc false
  def transaction(fun) when is_function(fun, 0), do: Repo.transaction(fun)

  @doc false
  def transaction(fun, opts) when is_function(fun, 0), do: Repo.transaction(fun, opts)

  @doc false
  def rollback(reason), do: Repo.rollback(reason)

  @doc false
  def query!(sql, params, opts \\ [])

  def query!(@advisory_lock_sql, [subsystem], opts) when is_binary(subsystem) do
    Ecto.Adapters.SQL.query!(Repo, @advisory_lock_sql, [subsystem], opts)
  end

  def query!(sql, params, _opts) do
    raise ArgumentError,
          "unexpected config conflict SQL: #{inspect(sql)} params=#{inspect(params)}"
  end

  @doc false
  def all(queryable, opts \\ []), do: Repo.all(queryable, opts)

  @doc "模拟 PG 唯一索引裁决：赢方已经插进去了，本次 INSERT 撞约束。"
  def insert_or_update(%Ecto.Changeset{} = changeset, _opts \\ []) do
    {:error,
     Ecto.Changeset.add_error(changeset, :subsystem, "has already been taken",
       constraint: :unique,
       constraint_name: "runtime_configs_subsystem_key_index"
     )}
  end

  @doc "冲突时绝不该写审计行；被调到就说明写路径把一次失败的写记成了历史。"
  def insert!(%Ecto.Changeset{}, _opts \\ []) do
    raise "audit row must not be written when the config write lost the unique-index race"
  end

  @doc false
  def delete!(%RuntimeConfig{} = row, opts \\ []), do: Repo.delete!(row, opts)
end
