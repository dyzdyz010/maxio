defmodule Maxio.Policy.Evaluator do
  @moduledoc """
  授权评估器（纯函数，无副作用，可 IEx 复算，铁律 3/4）。
  evaluate(ctx, statements) :: :allow | {:deny, :explicit_deny | :implicit_deny}

  算法（官方核验，§RESEARCH bake-in）：
    Rule 0: ctx.owner? → :allow（root/资源所有者短路）
    Step 1: 任一 applicable Deny → {:deny, :explicit_deny}
    Step 2: 任一 applicable Allow → :allow
    Step 3: 否则 → {:deny, :implicit_deny}
  applicable ⇔ principal ∧ action ∧ resource ∧ conditions 全部命中（effect 不参与 applicable）。
  """
  alias Maxio.Policy.{Arn, Condition, RequestContext, Statement}

  @spec evaluate(RequestContext.t(), [Statement.t()]) ::
          :allow | {:deny, :explicit_deny | :implicit_deny}
  def evaluate(%RequestContext{owner?: true}, _statements), do: :allow

  def evaluate(%RequestContext{} = ctx, statements) when is_list(statements) do
    applicable = Enum.filter(statements, &statement_applies?(&1, ctx))

    cond do
      Enum.any?(applicable, &(&1.effect == :deny)) -> {:deny, :explicit_deny}
      Enum.any?(applicable, &(&1.effect == :allow)) -> :allow
      true -> {:deny, :implicit_deny}
    end
  end

  defp statement_applies?(%Statement{} = s, %RequestContext{} = ctx) do
    principal_match?(s.principals, ctx) and
      action_match?(s.actions, ctx.action) and
      resource_match?(s.resources, ctx.resource) and
      Condition.hold?(s.conditions, ctx.conditions)
  end

  # :any 匹配匿名与任意认证；{:aws,list} 只匹配认证 principal 且 arn 命中（匿名永不命中）。
  defp principal_match?(:any, _ctx), do: true

  defp principal_match?({:aws, _list}, %RequestContext{principal: :anonymous}), do: false

  defp principal_match?({:aws, list}, %RequestContext{principal: %{arn: arn}}) do
    Enum.any?(list, fn pat -> Arn.glob_match?(pat, arn) end)
  end

  defp principal_match?(_principals, _ctx), do: false

  defp action_match?(actions, action) do
    Enum.any?(actions, &Arn.glob_match?(&1, action, case_insensitive: true))
  end

  defp resource_match?(resources, resource) do
    Enum.any?(resources, &Arn.glob_match?(&1, resource))
  end
end
