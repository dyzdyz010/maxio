defmodule Maxio.Policy.StatementTest do
  use ExUnit.Case, async: true
  alias Maxio.Policy.Statement

  @public_read ~s({"Version":"2012-10-17","Statement":[{"Sid":"P","Effect":"Allow","Principal":"*","Action":"s3:GetObject","Resource":"arn:aws:s3:::b/*"}]})

  test "解析 public-read（单 statement、Principal *）" do
    assert {:ok, [s]} = Statement.parse_policy(@public_read)
    assert s.effect == :allow
    assert s.principals == :any
    assert s.actions == ["s3:GetObject"]
    assert s.resources == ["arn:aws:s3:::b/*"]
    assert Statement.action_match?(s, "s3:GetObject")
    assert Statement.resource_match?(s, "arn:aws:s3:::b/k.txt")
  end

  test "Statement 单对象（非数组）归一化为列表" do
    json = ~s({"Version":"2012-10-17","Statement":{"Effect":"Deny","Principal":"*","Action":["s3:*"],"Resource":["arn:aws:s3:::b","arn:aws:s3:::b/*"]}})
    assert {:ok, [s]} = Statement.parse_policy(json)
    assert s.effect == :deny
    assert s.actions == ["s3:*"]
  end

  test "Action/Resource 数组" do
    json = ~s({"Statement":[{"Effect":"Allow","Principal":{"AWS":"arn:aws:iam::111:user/x"},"Action":["s3:GetObject","s3:PutObject"],"Resource":["arn:aws:s3:::b/*"]}]})
    assert {:ok, [s]} = Statement.parse_policy(json)
    assert s.principals == {:aws, ["arn:aws:iam::111:user/x"]}
  end

  test "AWS:* 归一化为 :any" do
    json = ~s({"Statement":{"Effect":"Allow","Principal":{"AWS":"*"},"Action":"s3:GetObject","Resource":"arn:aws:s3:::b/*"}})
    assert {:ok, [s]} = Statement.parse_policy(json)
    assert s.principals == :any
  end

  test "畸形：非 JSON" do
    assert {:error, :malformed} = Statement.parse_policy("not json")
  end

  test "畸形：Effect 非法" do
    json = ~s({"Statement":{"Effect":"Permit","Principal":"*","Action":"s3:*","Resource":"arn:aws:s3:::b"}})
    assert {:error, :malformed} = Statement.parse_policy(json)
  end

  test "畸形：bucket policy 缺 Principal" do
    json = ~s({"Statement":{"Effect":"Allow","Action":"s3:GetObject","Resource":"arn:aws:s3:::b/*"}})
    assert {:error, :malformed} = Statement.parse_policy(json)
  end

  test "畸形：缺 Action" do
    json = ~s({"Statement":{"Effect":"Allow","Principal":"*","Resource":"arn:aws:s3:::b"}})
    assert {:error, :malformed} = Statement.parse_policy(json)
  end

  test "畸形：Version 未知" do
    json = ~s({"Version":"1999-01-01","Statement":{"Effect":"Allow","Principal":"*","Action":"s3:*","Resource":"arn:aws:s3:::b"}})
    assert {:error, :malformed} = Statement.parse_policy(json)
  end

  test "Condition 透传为 map" do
    json = ~s({"Statement":{"Effect":"Deny","Principal":"*","Action":"s3:*","Resource":["arn:aws:s3:::b","arn:aws:s3:::b/*"],"Condition":{"Bool":{"aws:SecureTransport":"false"}}}})
    assert {:ok, [s]} = Statement.parse_policy(json)
    assert s.conditions == %{"Bool" => %{"aws:SecureTransport" => "false"}}
  end
end
