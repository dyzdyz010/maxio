defmodule Maxio.Policy.ArnTest do
  use ExUnit.Case, async: true
  alias Maxio.Policy.Arn

  test "ARN 构造" do
    assert Arn.bucket_arn("mybucket") == "arn:aws:s3:::mybucket"
    assert Arn.object_arn("mybucket", "a/b.txt") == "arn:aws:s3:::mybucket/a/b.txt"
    assert Arn.account_arn() == "arn:aws:s3:::*"
  end

  test "Resource glob：bucket/* 命中对象 ARN，不命中桶 ARN" do
    assert Arn.glob_match?("arn:aws:s3:::b/*", "arn:aws:s3:::b/k.txt")
    assert Arn.glob_match?("arn:aws:s3:::b/*", "arn:aws:s3:::b/a/deep/k.txt")
    refute Arn.glob_match?("arn:aws:s3:::b/*", "arn:aws:s3:::b")
  end

  test "Resource glob：桶 ARN 精确，不命中对象 ARN" do
    assert Arn.glob_match?("arn:aws:s3:::b", "arn:aws:s3:::b")
    refute Arn.glob_match?("arn:aws:s3:::b", "arn:aws:s3:::b/k")
  end

  test "前缀通配 + ? 单字符" do
    assert Arn.glob_match?("arn:aws:s3:::b/home/*", "arn:aws:s3:::b/home/x")
    refute Arn.glob_match?("arn:aws:s3:::b/home/*", "arn:aws:s3:::b/other/x")
    assert Arn.glob_match?("a?c", "abc")
    refute Arn.glob_match?("a?c", "ac")
  end

  test "Action 大小写不敏感；Resource 大小写敏感" do
    assert Arn.glob_match?("s3:get*", "s3:GetObject", case_insensitive: true)
    assert Arn.glob_match?("s3:*", "s3:DeleteObject", case_insensitive: true)
    refute Arn.glob_match?("arn:aws:s3:::B/*", "arn:aws:s3:::b/k")
  end

  test "正则元字符被转义（点不当通配）" do
    assert Arn.glob_match?("arn:aws:s3:::b/a.txt", "arn:aws:s3:::b/a.txt")
    refute Arn.glob_match?("arn:aws:s3:::b/a.txt", "arn:aws:s3:::b/aXtxt")
  end
end
