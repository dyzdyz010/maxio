defmodule Maxio.Auth.SigV4.CanonicalRawQueryTest do
  use ExUnit.Case, async: true
  alias Maxio.Auth.SigV4.Canonical

  test "raw query 中字面 '+'（wire %2B）canonicalize 成 %2B，不退化为空格/%20" do
    # 客户端签的值含字面 '+'，wire 上是 a%2Bb
    assert Canonical.canonical_query("token=a%2Bb") == "token=a%2Bb"
  end

  test "raw query 中真实空格（wire %20）canonicalize 成 %20" do
    assert Canonical.canonical_query("token=a%20b") == "token=a%20b"
  end

  test "'+' 与空格不再被混为一谈（两者 canonical 串不同）" do
    refute Canonical.canonical_query("k=%2B") == Canonical.canonical_query("k=%20")
  end

  test "多参数按编码后 name 排序，值原样单次编码" do
    assert Canonical.canonical_query("b=2&a=1") == "a=1&b=2"
  end

  test "空 raw query → 空串" do
    assert Canonical.canonical_query("") == ""
  end

  test "空值参数保留 key=（lifecycle 形态）" do
    assert Canonical.canonical_query("lifecycle=") == "lifecycle="
    assert Canonical.canonical_query("lifecycle") == "lifecycle="
  end

  test "map 入参向后兼容：普通参数结果与 raw 串一致" do
    assert Canonical.canonical_query(%{"a" => "1", "b" => "2"}) == "a=1&b=2"
  end
end
