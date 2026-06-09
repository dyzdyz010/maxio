defmodule Maxio.Policy.ConditionTest do
  use ExUnit.Case, async: true
  alias Maxio.Policy.Condition

  test "nil / 空块 → true" do
    assert Condition.hold?(nil, %{})
    assert Condition.hold?(%{}, %{})
  end

  test "StringEquals 数组 OR" do
    block = %{"StringEquals" => %{"s3:prefix" => ["a/", "b/"]}}
    assert Condition.hold?(block, %{"s3:prefix" => "b/"})
    refute Condition.hold?(block, %{"s3:prefix" => "c/"})
  end

  test "Bool 字符串 vs 布尔" do
    assert Condition.hold?(%{"Bool" => %{"aws:SecureTransport" => "true"}}, %{
             "aws:SecureTransport" => true
           })

    refute Condition.hold?(%{"Bool" => %{"aws:SecureTransport" => "false"}}, %{
             "aws:SecureTransport" => true
           })
  end

  test "缺键 → false" do
    refute Condition.hold?(%{"StringEquals" => %{"s3:prefix" => "a/"}}, %{})
  end

  test "IpAddress 单 IP（/32）" do
    assert Condition.hold?(%{"IpAddress" => %{"aws:SourceIp" => "10.0.0.1"}}, %{
             "aws:SourceIp" => "10.0.0.1"
           })

    refute Condition.hold?(%{"IpAddress" => %{"aws:SourceIp" => "10.0.0.1"}}, %{
             "aws:SourceIp" => "10.0.0.2"
           })
  end

  test "DateGreaterThan" do
    block = %{"DateGreaterThan" => %{"aws:CurrentTime" => "2020-01-01T00:00:00Z"}}
    assert Condition.hold?(block, %{"aws:CurrentTime" => ~U[2026-06-08 00:00:00Z]})
    refute Condition.hold?(block, %{"aws:CurrentTime" => ~U[2019-01-01 00:00:00Z]})
  end

  test "多算子 AND" do
    block = %{
      "Bool" => %{"aws:SecureTransport" => "true"},
      "StringEquals" => %{"s3:prefix" => "home/"}
    }

    assert Condition.hold?(block, %{"aws:SecureTransport" => true, "s3:prefix" => "home/"})
    refute Condition.hold?(block, %{"aws:SecureTransport" => true, "s3:prefix" => "away/"})
  end

  test "合法但未实现求值的算子（NumericLessThan）→ 保守判 false（statement 不命中，绝不静默放行）" do
    block = %{"NumericLessThan" => %{"s3:max-keys" => "10"}}

    # 即便请求上下文「逻辑上满足」该数值条件，未实现求值的算子也保守不命中。
    refute Condition.hold?(block, %{"s3:max-keys" => "5"})
    refute Condition.hold?(block, %{})
  end

  test "known_operators 含全量 AWS/MinIO 算子；implemented_operators 是其真子集" do
    known = MapSet.new(Condition.known_operators())
    impl = MapSet.new(Condition.implemented_operators())
    # 全量白名单含合法但未实现求值的算子与 *IfExists 变体。
    for op <-
          ~w(StringNotEquals NumericLessThan DateLessThan NotIpAddress Null StringEqualsIfExists) do
      assert MapSet.member?(known, op), "known_operators 应含 #{op}"
    end

    # 实现集是接受集的真子集。
    assert MapSet.subset?(impl, known)
    refute MapSet.equal?(impl, known)
  end
end
