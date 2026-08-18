defmodule Maxio.Test.RejectingObjectMutationRepo do
  @moduledoc """
  Tests-only no-SQL repo seam（adjudication「Keep this RED clean by injecting a tests-only
  `Maxio.Test.RejectingObjectMutationRepo`」）。

  `update_all/2` 与 `get/2` 先向**当前测试进程**发送固定 call message，再抛出固定 sentinel，
  全程不触碰 PostgreSQL。`Maxio.ObjectMutation` 的所有写入口都接受 `opts[:repo]`，因此把它
  注入到一次公共调用里，就能在不污染 SQL Sandbox 连接的前提下判定「SQL 边界是否被越过」：

  - 旧行为（validation 被 equality/CAS 旁路）→ 收到 call message，sentinel 被 rescue 成
    错误结果，RED 确定性成立；
  - 冻结契约的正确行为 → 在 SQL 之前就返回精确的公共错误，信箱里不会出现任何 call message。

  它**不是** `Ecto.Repo`，也绝不参与生产代码路径。
  """

  @message_tag :rejecting_object_mutation_repo
  @sentinel "rejecting_object_mutation_repo:sql_boundary_crossed"

  @doc "固定 call message 的 tag；测试用 `refute_received {tag(), _}` 断言未越过 SQL 边界。"
  @spec message_tag() :: atom()
  def message_tag, do: @message_tag

  @doc "固定 sentinel 文本；出现在被 rescue 的错误结果里即证明旧行为走到了 SQL。"
  @spec sentinel() :: String.t()
  def sentinel, do: @sentinel

  def update_all(_queryable, _updates, _opts \\ []) do
    send(self(), {@message_tag, :update_all})
    raise @sentinel
  end

  def get(_schema, _id, _opts \\ []) do
    send(self(), {@message_tag, :get})
    raise @sentinel
  end
end
