defmodule Maxio.Policy.Evaluator do
  @moduledoc """
  授权评估器（纯函数，无副作用，可 IEx 复算，铁律 3/4）。
  evaluate(ctx, statements) :: :allow | {:deny, :explicit_deny | :implicit_deny}

  算法（官方核验，§RESEARCH bake-in）：
    Step 1: 任一 applicable Deny → {:deny, :explicit_deny}
    Step 2: ctx.owner? → :allow（资源所有者补隐式允许，但不覆盖显式拒绝）
    Step 3: 任一 applicable Allow → :allow
    Step 4: 否则 → {:deny, :implicit_deny}
  applicable ⇔ principal ∧ action ∧ resource ∧ conditions 全部命中（effect 不参与 applicable）。
  """
  alias Maxio.Policy.{Condition, RequestContext, Statement}

  @spec evaluate(RequestContext.t(), [Statement.t()]) ::
          :allow | {:deny, :explicit_deny | :implicit_deny}
  def evaluate(%RequestContext{} = ctx, statements) when is_list(statements) do
    applicable = Enum.filter(statements, &statement_applies?(&1, ctx))

    cond do
      Enum.any?(applicable, &(&1.effect == :deny)) -> {:deny, :explicit_deny}
      ctx.owner? -> :allow
      Enum.any?(applicable, &(&1.effect == :allow)) -> :allow
      true -> {:deny, :implicit_deny}
    end
  end

  defp statement_applies?(%Statement{} = s, %RequestContext{} = ctx) do
    principal_match?(s, ctx) and
      Statement.action_match?(s, ctx.action) and
      Statement.resource_match?(s, ctx) and
      Condition.hold?(s.conditions, ctx.conditions, variables_enabled?: s.variables_enabled?)
  end

  # :any 匹配匿名与任意认证；{:aws,list} 只匹配认证 principal 且 arn 命中（匿名永不命中）。
  defp principal_match?(%Statement{principals: principals, not_principal?: not_principal?}, ctx) do
    matched? = principal_selector_match?(principals, ctx)
    if not_principal?, do: not matched?, else: matched?
  end

  defp principal_selector_match?(:any, _ctx), do: true

  defp principal_selector_match?({:aws, _list}, %RequestContext{principal: :anonymous}), do: false

  defp principal_selector_match?({:aws, list}, %RequestContext{principal: %{arn: arn}}) do
    # AWS Principal 精确匹配（区分大小写）；不做 glob（policy variable 未实现）。Statement 已把纯 "*" 归一化为 :any。
    Enum.any?(list, fn pat -> pat == arn end)
  end

  defp principal_selector_match?({:federated, list}, %RequestContext{
         principal: %{type: :federated, arn: arn}
       }) do
    Enum.any?(list, fn pat -> pat == arn end)
  end

  defp principal_selector_match?({:federated, _list}, _ctx), do: false

  defp principal_selector_match?({:mixed, categories}, %RequestContext{} = ctx) do
    categories
    |> Enum.any?(fn
      {:aws, list} -> principal_selector_match?({:aws, list}, ctx)
      {:federated, list} -> principal_selector_match?({:federated, list}, ctx)
      {_other, _list} -> false
    end)
  end

  defp principal_selector_match?(_principals, _ctx), do: false
end
