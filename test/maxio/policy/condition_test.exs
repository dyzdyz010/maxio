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
end
