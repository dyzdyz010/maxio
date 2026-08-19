defmodule Maxio.Test.ConfigConflictRepo do
  @moduledoc """
  测试替身：模拟"另一个进程刚刚赢了同一个键的首写"这一**真实并发结果**。

  为什么需要替身：`Maxio.Config` 的写事务先 `SELECT ... FOR UPDATE`，而 `FOR UPDATE`
  锁不住一行还不存在的记录——两个进程同时首写同一个键时双双走 INSERT，由
  `(subsystem, key)` 唯一索引裁决。这个竞态在 ExUnit 的 sandbox 里**无法复现**：
  sandbox 把整个测试关在一个事务里，直接插进去的行对同一事务里的 `FOR UPDATE` 是可见的，
  于是走的是 UPDATE 分支，根本碰不到唯一索引。

  所以这里只替换 Repo 的四个调用点，让 `insert_or_update/1` 返回一个带唯一约束错误的
  changeset（PG 真的这么报），从而确定性地覆盖"唯一索引裁决 → 结构化冲突"这条映射。
  绝不在生产代码里为了可测性加分支——替身只活在测试里。
  """

  alias Maxio.Config.RuntimeConfig

  @doc false
  def transaction(fun) when is_function(fun, 0) do
    {:ok, fun.()}
  catch
    {__MODULE__, :rollback, reason} -> {:error, reason}
  end

  @doc false
  def rollback(reason), do: throw({__MODULE__, :rollback, reason})

  @doc "写事务的 SELECT ... FOR UPDATE：模拟该键还没有行。"
  def one(_query), do: nil

  @doc "模拟 PG 唯一索引裁决：赢方已经插进去了，本次 INSERT 撞约束。"
  def insert_or_update(%Ecto.Changeset{} = changeset) do
    {:error,
     Ecto.Changeset.add_error(changeset, :subsystem, "has already been taken",
       constraint: :unique,
       constraint_name: "runtime_configs_subsystem_key_index"
     )}
  end

  @doc "冲突时绝不该写审计行；被调到就说明写路径把一次失败的写记成了历史。"
  def insert!(%Ecto.Changeset{}) do
    raise "audit row must not be written when the config write lost the unique-index race"
  end

  @doc false
  def all(_query), do: []

  @doc false
  def delete!(%RuntimeConfig{} = row), do: row
end
