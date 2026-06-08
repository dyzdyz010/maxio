defmodule Maxio.Policy.RequestContextTest do
  use ExUnit.Case, async: true
  alias Maxio.Policy.RequestContext

  test "默认值（匿名、未认证、非 owner）" do
    ctx = %RequestContext{}
    assert ctx.principal == :anonymous
    assert ctx.authenticated? == false
    assert ctx.owner? == false
    assert ctx.conditions == %{}
  end

  test "可构造认证 owner 上下文" do
    ctx = %RequestContext{
      principal: %{type: :root, access_key: "ak", arn: "arn:aws:iam:::root"},
      authenticated?: true,
      owner?: true,
      action: "s3:GetObject",
      resource: "arn:aws:s3:::b/k",
      conditions: %{"aws:SecureTransport" => true}
    }

    assert ctx.owner?
    assert ctx.action == "s3:GetObject"
  end
end
