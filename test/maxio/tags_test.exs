defmodule Maxio.TagsTest do
  use ExUnit.Case, async: true
  alias Maxio.Tags

  test "合法对象 tag 集" do
    assert :ok = Tags.validate([{"env", "prod"}, {"team", "core"}], :object)
  end

  test "对象 > 10 个 → invalid_tag" do
    tags = for i <- 1..11, do: {"k#{i}", "v"}
    assert {:error, :invalid_tag} = Tags.validate(tags, :object)
  end

  test "桶可 50 个；51 个 → invalid_tag" do
    ok = for i <- 1..50, do: {"k#{i}", "v"}
    assert :ok = Tags.validate(ok, :bucket)
    bad = for i <- 1..51, do: {"k#{i}", "v"}
    assert {:error, :invalid_tag} = Tags.validate(bad, :bucket)
  end

  test "重复 key → invalid_tag" do
    assert {:error, :invalid_tag} = Tags.validate([{"k", "1"}, {"k", "2"}], :object)
  end

  test "key 超 128 / value 超 256 → invalid_tag" do
    assert {:error, :invalid_tag} = Tags.validate([{String.duplicate("a", 129), "v"}], :object)
    assert {:error, :invalid_tag} = Tags.validate([{"k", String.duplicate("a", 257)}], :object)
  end

  test "aws: 前缀保留 → invalid_tag" do
    assert {:error, :invalid_tag} = Tags.validate([{"aws:foo", "v"}], :object)
  end

  test "非法字符 → invalid_tag" do
    assert {:error, :invalid_tag} = Tags.validate([{"bad#key", "v"}], :object)
  end

  test "空 value 合法（value 0..256）" do
    assert :ok = Tags.validate([{"k", ""}], :object)
  end

  test "parse_header：key1=val1&key2=val2" do
    assert {:ok, [{"k1", "v1"}, {"k2", "v2"}]} = Tags.parse_header("k1=v1&k2=v2")
  end

  test "parse_header：URL 编码解码" do
    assert {:ok, [{"a b", "c/d"}]} = Tags.parse_header("a%20b=c%2Fd")
  end
end
