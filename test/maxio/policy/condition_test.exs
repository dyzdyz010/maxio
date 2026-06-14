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

  test "policy variables expand inside condition policy values" do
    block = %{"StringEquals" => %{"s3:prefix" => "home/${aws:username}/"}}

    assert Condition.hold?(block, %{"s3:prefix" => "home/alice/", "aws:username" => "alice"})
    refute Condition.hold?(block, %{"s3:prefix" => "home/bob/", "aws:username" => "alice"})
  end

  test "policy variable special literals remain literal in exact and glob conditions" do
    exact = %{"StringEquals" => %{"s3:prefix" => "file${*}${?}.txt"}}
    glob = %{"StringLike" => %{"s3:prefix" => "file${*}${?}.txt"}}

    assert Condition.hold?(exact, %{"s3:prefix" => "file*?.txt"})
    refute Condition.hold?(exact, %{"s3:prefix" => "fileab.txt"})

    assert Condition.hold?(glob, %{"s3:prefix" => "file*?.txt"})
    refute Condition.hold?(glob, %{"s3:prefix" => "fileab.txt"})
  end

  test "unresolved condition variables fail positive operators and satisfy negated operators" do
    positive = %{"StringEquals" => %{"s3:prefix" => "home/${aws:username}/"}}
    negated = %{"StringNotEquals" => %{"s3:prefix" => "home/${aws:username}/"}}

    refute Condition.hold?(positive, %{"s3:prefix" => "home/alice/"})
    assert Condition.hold?(negated, %{"s3:prefix" => "home/alice/"})
  end

  test "condition variables support default values" do
    block = %{"StringEquals" => %{"s3:prefix" => "home/${aws:username, 'public'}/"}}

    assert Condition.hold?(block, %{"s3:prefix" => "home/public/"})
  end

  test "condition variables are not expanded for non-string and non-ARN operators" do
    refute Condition.hold?(%{"NumericEquals" => %{"s3:max-keys" => "${aws:max}"}}, %{
             "s3:max-keys" => "5",
             "aws:max" => "5"
           })
  end

  test "Bool 字符串 vs 布尔" do
    assert Condition.hold?(%{"Bool" => %{"aws:SecureTransport" => "true"}}, %{
             "aws:SecureTransport" => true
           })

    refute Condition.hold?(%{"Bool" => %{"aws:SecureTransport" => "false"}}, %{
             "aws:SecureTransport" => true
           })

    refute Condition.hold?(%{"Bool" => %{"aws:SecureTransport" => "wat"}}, %{
             "aws:SecureTransport" => "wat"
           })
  end

  test "condition key lookup is case-insensitive" do
    assert Condition.hold?(%{"StringEquals" => %{"aws:PrincipalTag/Team" => "platform"}}, %{
             "aws:PrincipalTag/team" => "platform"
           })
  end

  test "正向算子缺键 → false" do
    refute Condition.hold?(%{"StringEquals" => %{"s3:prefix" => "a/"}}, %{})
  end

  test "否定算子缺键按 AWS 语义成立" do
    assert Condition.hold?(%{"StringNotEquals" => %{"s3:x-amz-acl" => "public-read"}}, %{})
    assert Condition.hold?(%{"NotIpAddress" => %{"aws:SourceIp" => "10.0.0.0/8"}}, %{})
  end

  test "否定算子遇到无法解析的值 fail-closed" do
    refute Condition.hold?(%{"NotIpAddress" => %{"aws:SourceIp" => "bad-cidr"}}, %{
             "aws:SourceIp" => "192.0.2.1"
           })

    refute Condition.hold?(%{"NumericNotEquals" => %{"s3:max-keys" => "many"}}, %{
             "s3:max-keys" => "5"
           })

    refute Condition.hold?(%{"NotIpAddress" => %{"aws:SourceIp" => "bad-cidr"}}, %{})
    refute Condition.hold?(%{"NumericNotEquals" => %{"s3:max-keys" => "many"}}, %{})
  end

  test "IfExists keeps missing-key true only for parseable policy values" do
    assert Condition.hold?(%{"StringEqualsIfExists" => %{"s3:prefix" => "home/"}}, %{})
    assert Condition.hold?(%{"NumericNotEqualsIfExists" => %{"s3:max-keys" => "10"}}, %{})

    refute Condition.hold?(%{"NotIpAddressIfExists" => %{"aws:SourceIp" => "bad-cidr"}}, %{})
    refute Condition.hold?(%{"NumericNotEqualsIfExists" => %{"s3:max-keys" => "many"}}, %{})
  end

  test "IpAddress 单 IP（/32）" do
    assert Condition.hold?(%{"IpAddress" => %{"aws:SourceIp" => "10.0.0.1"}}, %{
             "aws:SourceIp" => "10.0.0.1"
           })

    refute Condition.hold?(%{"IpAddress" => %{"aws:SourceIp" => "10.0.0.1"}}, %{
             "aws:SourceIp" => "10.0.0.2"
           })
  end

  test "IpAddress 支持 IPv6 CIDR" do
    assert Condition.hold?(%{"IpAddress" => %{"aws:SourceIp" => "2001:db8:1234::/48"}}, %{
             "aws:SourceIp" => "2001:db8:1234:5678::1"
           })

    refute Condition.hold?(%{"IpAddress" => %{"aws:SourceIp" => "2001:db8:1234::/48"}}, %{
             "aws:SourceIp" => "2001:db8:9999::1"
           })

    assert Condition.hold?(%{"NotIpAddress" => %{"aws:SourceIp" => "203.0.113.0/24"}}, %{
             "aws:SourceIp" => "2001:db8::1"
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

  test "NumericLessThan 真正求值" do
    block = %{"NumericLessThan" => %{"s3:max-keys" => "10"}}

    assert Condition.hold?(block, %{"s3:max-keys" => "5"})
    refute Condition.hold?(block, %{"s3:max-keys" => "10"})
    refute Condition.hold?(block, %{})
  end

  test "StringNotLike / IfExists / Null / ArnLike / DateLessThan 求值" do
    assert Condition.hold?(%{"StringNotLike" => %{"s3:prefix" => "private/*"}}, %{
             "s3:prefix" => "public/a"
           })

    refute Condition.hold?(%{"StringNotLike" => %{"s3:prefix" => []}}, %{
             "s3:prefix" => "public/a"
           })

    refute Condition.hold?(%{"StringNotLike" => %{"s3:prefix" => "private/*"}}, %{
             "s3:prefix" => "private/a"
           })

    assert Condition.hold?(%{"StringEqualsIfExists" => %{"s3:prefix" => "home/"}}, %{})

    assert Condition.hold?(%{"Null" => %{"s3:x-amz-server-side-encryption" => "true"}}, %{})

    refute Condition.hold?(%{"Null" => %{"s3:x-amz-server-side-encryption" => "true"}}, %{
             "s3:x-amz-server-side-encryption" => "AES256"
           })

    assert Condition.hold?(%{"Null" => %{"s3:prefix" => "true"}}, %{"s3:prefix" => ""})
    refute Condition.hold?(%{"Null" => %{"s3:prefix" => "false"}}, %{"s3:prefix" => ""})

    assert Condition.hold?(%{"ArnLike" => %{"aws:PrincipalArn" => "arn:aws:iam:::user/*"}}, %{
             "aws:PrincipalArn" => "arn:aws:iam:::user/alice"
           })

    assert Condition.hold?(%{"DateLessThan" => %{"aws:CurrentTime" => "2030-01-01T00:00:00Z"}}, %{
             "aws:CurrentTime" => ~U[2026-06-08 00:00:00Z]
           })

    assert Condition.hold?(%{"DateGreaterThan" => %{"aws:EpochTime" => "1704067200"}}, %{
             "aws:EpochTime" => 1_704_067_201
           })
  end

  test "ForAnyValue 正向集合算子：至少一个请求值命中" do
    block = %{"ForAnyValue:StringLike" => %{"s3:prefix" => ["home/*", "public/*"]}}

    assert Condition.hold?(block, %{"s3:prefix" => ["tmp/a", "home/alice"]})
    refute Condition.hold?(block, %{"s3:prefix" => ["tmp/a", "secret/a"]})
    refute Condition.hold?(block, %{})
    refute Condition.hold?(block, %{"s3:prefix" => []})

    refute Condition.hold?(%{"ForAnyValue:StringLike" => %{"s3:prefix" => "*"}}, %{
             "s3:prefix" => ""
           })
  end

  test "ForAllValues 正向集合算子：全部请求值命中，缺键/空请求值按 AWS 语义成立" do
    block = %{"ForAllValues:StringLike" => %{"s3:prefix" => ["home/*", "public/*"]}}

    assert Condition.hold?(block, %{"s3:prefix" => ["home/alice", "public/readme"]})
    refute Condition.hold?(block, %{"s3:prefix" => ["home/alice", "secret/a"]})
    assert Condition.hold?(block, %{})
    assert Condition.hold?(block, %{"s3:prefix" => []})
    assert Condition.hold?(block, %{"s3:prefix" => ""})

    refute Condition.hold?(
             Map.merge(block, %{"Null" => %{"s3:prefix" => "false"}}),
             %{"s3:prefix" => ""}
           )
  end

  test "ForAnyValue / ForAllValues 支持否定集合算子" do
    any_block = %{"ForAnyValue:StringNotLike" => %{"s3:prefix" => "private/*"}}
    all_block = %{"ForAllValues:StringNotLike" => %{"s3:prefix" => "private/*"}}

    assert Condition.hold?(any_block, %{"s3:prefix" => ["private/a", "public/a"]})
    refute Condition.hold?(any_block, %{"s3:prefix" => ["private/a", "private/b"]})
    refute Condition.hold?(any_block, %{})

    assert Condition.hold?(all_block, %{"s3:prefix" => ["public/a", "tmp/a"]})
    refute Condition.hold?(all_block, %{"s3:prefix" => ["public/a", "private/a"]})
    assert Condition.hold?(all_block, %{})
  end

  test "集合算子支持 IfExists 后缀且解析错误 fail-closed" do
    assert Condition.hold?(
             %{"ForAnyValue:StringEqualsIfExists" => %{"s3:prefix" => "home/"}},
             %{}
           )

    assert Condition.hold?(
             %{"ForAllValues:StringEqualsIfExists" => %{"s3:prefix" => "home/"}},
             %{}
           )

    refute Condition.hold?(%{"ForAnyValue:NumericNotEquals" => %{"s3:max-keys" => "many"}}, %{
             "s3:max-keys" => ["1", "2"]
           })

    refute Condition.hold?(
             %{"ForAllValues:DateNotEquals" => %{"aws:CurrentTime" => "not-a-date"}},
             %{
               "aws:CurrentTime" => ["2026-06-12T00:00:00Z"]
             }
           )
  end

  test "ArnEquals / ArnNotEquals 与 ArnLike / ArnNotLike 一样支持 ARN 通配" do
    assert Condition.hold?(%{"ArnEquals" => %{"aws:PrincipalArn" => "arn:aws:iam:::user/*"}}, %{
             "aws:PrincipalArn" => "arn:aws:iam:::user/alice"
           })

    refute Condition.hold?(
             %{"ArnNotEquals" => %{"aws:PrincipalArn" => "arn:aws:iam:::user/*"}},
             %{
               "aws:PrincipalArn" => "arn:aws:iam:::user/alice"
             }
           )

    assert Condition.hold?(
             %{"ForAllValues:ArnEquals" => %{"aws:PrincipalArn" => "arn:aws:iam:::user/*"}},
             %{
               "aws:PrincipalArn" => [
                 "arn:aws:iam:::user/alice",
                 "arn:aws:iam:::user/bob"
               ]
             }
           )
  end

  test "known_operators 含 AWS/MinIO 条件算子；implemented_operators 已覆盖当前白名单" do
    known = MapSet.new(Condition.known_operators())
    impl = MapSet.new(Condition.implemented_operators())

    for op <-
          ~w(StringNotEquals NumericLessThan DateLessThan NotIpAddress Null StringEqualsIfExists ForAnyValue:StringLike ForAllValues:StringEquals ForAnyValue:StringLikeIfExists) do
      assert MapSet.member?(known, op), "known_operators 应含 #{op}"
    end

    refute MapSet.member?(known, "NullIfExists")
    refute MapSet.member?(known, "ForAnyValue:Null")
    refute MapSet.member?(known, "ForAllValues:NullIfExists")
    assert MapSet.subset?(impl, known)
    assert MapSet.equal?(impl, known)
  end
end
