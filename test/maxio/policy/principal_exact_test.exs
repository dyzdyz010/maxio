defmodule Maxio.Policy.PrincipalExactTest do
  @moduledoc "回归：AWS Principal {:aws,list} 精确匹配，不被通配过度命中（note 4）。"
  use ExUnit.Case, async: true
  alias Maxio.Policy.{Evaluator, RequestContext, Statement}

  defp ctx(arn) do
    %RequestContext{
      principal: %{type: :iam_user, access_key: "ak", arn: arn},
      authenticated?: true,
      owner?: false,
      action: "s3:GetObject",
      resource: "arn:aws:s3:::b/k",
      conditions: %{}
    }
  end

  defp allow_stmt(principal_arn) do
    %Statement{
      effect: :allow,
      actions: ["s3:GetObject"],
      resources: ["arn:aws:s3:::b/*"],
      principals: {:aws, [principal_arn]},
      conditions: %{}
    }
  end

  test "精确 ARN 命中" do
    arn = "arn:aws:iam:::user/AKIAALICE"
    assert Evaluator.evaluate(ctx(arn), [allow_stmt(arn)]) == :allow
  end

  test "通配 ARN 不再过度命中（精确匹配）" do
    assert Evaluator.evaluate(ctx("arn:aws:iam:::user/AKIAALICE"), [
             allow_stmt("arn:aws:iam:::user/*")
           ]) ==
             {:deny, :implicit_deny}
  end

  test "不同 ARN 不命中" do
    assert Evaluator.evaluate(ctx("arn:aws:iam:::user/AKIABOB"), [
             allow_stmt("arn:aws:iam:::user/AKIAALICE")
           ]) ==
             {:deny, :implicit_deny}
  end
end
