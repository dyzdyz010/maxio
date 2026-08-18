defmodule Maxio.Test.RecoveryScriptRepo do
  @moduledoc """
  Tests-only repo seam for the G3 final-review correction batch（handoff §5.2）。

  只服务本批的 **renew 边界**：`Maxio.ObjectMutation` 的所有写入口都接受 `opts[:repo]`，
  `Recovery` 又经 `lease_opts/1` / `journal_opts/1` 把它逐字透传，因此把本 module 注入一次
  `Recovery.recover/2` 就能在**不触碰 SQL Sandbox 语义**的前提下，对 claim / renew /
  release / 其它 journal 写四类操作分别注入故障，并证明故障精确命中 renew 而不是 claim。

  设计约束（全部来自 handoff §5.2）：

    * 默认逐字 delegate `Maxio.Repo`：未配置的 operation 一律透传，因此 Recovery 的其余
      CAS 语义（attempts 精确匹配、租约栅栏）保持真实；
    * operation 依据 `update_all` 的 `set` **精确 key 集合**与 value 形状识别，**绝不**按
      脆弱的调用序号：

          :claim         → key 恰为 lease_owner/lease_expires_at/updated_at，owner 与 expiry 非 nil
          :renew         → key 恰为 lease_expires_at/updated_at
          :release       → key 恰为 lease_owner/lease_expires_at/updated_at，owner 与 expiry 均为 nil
          :journal_write → 其余一切写

    * 每 operation 一条 FIFO action 队列，action 只允许
      `:delegate | {:return, value} | {:run, fun} | {:raise, sentinel} | {:exit, sentinel} |
      {:throw, sentinel}`；配置项**消费一次**后恢复 delegate；
    * `{:run, fun}`（0 元函数，返回值即 repo 结果）是本 seam 唯一的**确定性副作用窗口**：
      它在 caller 进程内、恰好在被替换的那次 repo 调用位置执行，因此可以精确地在
      「`renew_lease` 的 CAS 已判定未命中」与「其后的 `cas_result` fresh 读」之间插入并发
      扰动（例如把租约交给另一个 owner），全程零 sleep、零轮询；
    * action 在 **caller 进程**执行（Agent 只负责原子出队），因此 raise/exit/throw 打在真实
      调用栈上，绝不杀死脚本进程；
    * 原子记录每次调用的 operation、caller 与序号，`counts/0` 给出精确 call counts；
    * 非法 operation / 非法 action fail closed（`ArgumentError`），绝不静默降级。

  不使用 Application env、`persistent_term`、process dictionary、sleep、polling、游离进程或
  runtime module replacement。固定名 + 受监督 Agent，每格用 `start_supervised!/1`；测试
  module 已 `async: false`，退出即自动清理。

  它**不是** `Ecto.Repo`，也绝不参与生产代码路径。
  """

  use Agent

  alias Maxio.Repo

  @operations [:claim, :renew, :release, :journal_write]

  @claim_keys MapSet.new([:lease_owner, :lease_expires_at, :updated_at])
  @renew_keys MapSet.new([:lease_expires_at, :updated_at])

  @doc "已知 operation 闭集（非法 operation fail closed 的唯一权威）。"
  @spec operations() :: [atom()]
  def operations, do: @operations

  @doc false
  def start_link(_opts \\ []) do
    Agent.start_link(fn -> new_state() end, name: __MODULE__)
  end

  defp new_state do
    %{
      actions: Map.new(@operations, &{&1, []}),
      counts: Map.new(@operations, &{&1, 0}),
      get_count: 0,
      calls: []
    }
  end

  # ── 配置 ──

  @doc """
  给 `operation` 追加一条 FIFO action。消费一次后该 operation 自动恢复 delegate。

  非法 operation 或非法 action 立即 `ArgumentError`（fail closed）。
  """
  @spec script(atom(), term()) :: :ok
  def script(operation, action) do
    validate_operation!(operation)
    validate_action!(action)

    Agent.update(__MODULE__, fn state ->
      update_in(state.actions[operation], &(&1 ++ [action]))
    end)
  end

  # ── 取证 ──

  @doc "四个写 operation 的精确调用次数。"
  @spec counts() :: %{atom() => non_neg_integer()}
  def counts, do: Agent.get(__MODULE__, & &1.counts)

  @doc "`get/2,3` 的调用次数（读边界，与写 operation 分开计）。"
  @spec get_count() :: non_neg_integer()
  def get_count, do: Agent.get(__MODULE__, & &1.get_count)

  @doc """
  按时间顺序的调用记录：`%{operation: op, caller: pid, index: n}`。

  tests 用它正向证明故障命中的是 renew 而不是 claim。
  """
  @spec calls() :: [%{operation: atom(), caller: pid(), index: pos_integer()}]
  def calls, do: __MODULE__ |> Agent.get(& &1.calls) |> Enum.reverse()

  @doc "某 operation 尚未被消费的 action 条数（必须为 0 才算脚本被精确消费）。"
  @spec remaining(atom()) :: non_neg_integer()
  def remaining(operation) do
    validate_operation!(operation)
    Agent.get(__MODULE__, &length(&1.actions[operation]))
  end

  @doc "全部 operation 的剩余 action 条数。"
  @spec remaining_all() :: %{atom() => non_neg_integer()}
  def remaining_all do
    Agent.get(__MODULE__, fn state ->
      Map.new(state.actions, fn {op, queue} -> {op, length(queue)} end)
    end)
  end

  # ── repo 表面 ──

  def update_all(queryable, updates, opts \\ []) do
    operation = classify(updates)

    case take_action(operation) do
      :delegate -> Repo.update_all(queryable, updates, opts)
      action -> perform(action)
    end
  end

  def get(schema, id, opts \\ []) do
    :ok = Agent.update(__MODULE__, fn state -> %{state | get_count: state.get_count + 1} end)
    Repo.get(schema, id, opts)
  end

  # ── 内部 ──

  # `set` 的精确 key 集合 + value 形状即 operation 身份（handoff §5.2：禁止按调用序号）。
  defp classify(updates) when is_list(updates) do
    case Keyword.get(updates, :set) do
      nil ->
        :journal_write

      set when is_list(set) ->
        keys = set |> Keyword.keys() |> MapSet.new()

        cond do
          keys == @renew_keys ->
            :renew

          keys == @claim_keys ->
            owner = Keyword.get(set, :lease_owner)
            expiry = Keyword.get(set, :lease_expires_at)

            cond do
              not is_nil(owner) and not is_nil(expiry) -> :claim
              is_nil(owner) and is_nil(expiry) -> :release
              true -> :journal_write
            end

          true ->
            :journal_write
        end

      _other ->
        :journal_write
    end
  end

  defp classify(_updates), do: :journal_write

  # 原子出队 + 原子记账：Agent 只做这一件事，action 本身回到 caller 进程执行。
  defp take_action(operation) do
    caller = self()

    Agent.get_and_update(__MODULE__, fn state ->
      {action, queue} =
        case state.actions[operation] do
          [head | tail] -> {head, tail}
          [] -> {:delegate, []}
        end

      index = length(state.calls) + 1

      state = %{
        state
        | actions: Map.put(state.actions, operation, queue),
          counts: Map.update!(state.counts, operation, &(&1 + 1)),
          calls: [%{operation: operation, caller: caller, index: index} | state.calls]
      }

      {action, state}
    end)
  end

  defp perform({:return, value}), do: value
  defp perform({:run, fun}), do: fun.()
  defp perform({:raise, sentinel}), do: raise(sentinel)
  defp perform({:exit, sentinel}), do: exit(sentinel)
  defp perform({:throw, sentinel}), do: throw(sentinel)

  defp validate_operation!(operation) when operation in @operations, do: :ok

  defp validate_operation!(operation),
    do: raise(ArgumentError, "unknown recovery script operation: #{inspect(operation)}")

  defp validate_action!(:delegate), do: :ok
  defp validate_action!({:return, _value}), do: :ok
  defp validate_action!({:run, fun}) when is_function(fun, 0), do: :ok
  defp validate_action!({:raise, sentinel}) when is_binary(sentinel), do: :ok
  defp validate_action!({:exit, sentinel}) when is_binary(sentinel), do: :ok
  defp validate_action!({:throw, sentinel}) when is_binary(sentinel), do: :ok

  defp validate_action!(action),
    do: raise(ArgumentError, "unsupported recovery script action: #{inspect(action)}")
end
