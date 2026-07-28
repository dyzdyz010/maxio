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
    json =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Deny","Principal":"*","Action":["s3:*"],"Resource":["arn:aws:s3:::b","arn:aws:s3:::b/*"]}})

    assert {:ok, [s]} = Statement.parse_policy(json)
    assert s.effect == :deny
    assert s.actions == ["s3:*"]
  end

  test "Action/Resource 数组" do
    json =
      ~s({"Statement":[{"Effect":"Allow","Principal":{"AWS":"arn:aws:iam::111:user/x"},"Action":["s3:GetObject","s3:PutObject"],"Resource":["arn:aws:s3:::b/*"]}]})

    assert {:ok, [s]} = Statement.parse_policy(json)
    assert s.principals == {:aws, ["arn:aws:iam::111:user/x"]}
  end

  test "NotAction / NotResource / NotPrincipal 归一化并按反向 selector 匹配" do
    json =
      ~s({"Statement":{"Effect":"Deny","NotPrincipal":{"AWS":"arn:aws:iam:::user/alice"},"NotAction":"s3:GetObject","NotResource":"arn:aws:s3:::b/public/*"}})

    assert {:ok, [s]} = Statement.parse_policy(json)
    assert s.not_principal?
    assert s.not_action?
    assert s.not_resource?

    refute Statement.action_match?(s, "s3:GetObject")
    assert Statement.action_match?(s, "s3:PutObject")
    refute Statement.resource_match?(s, "arn:aws:s3:::b/public/a.txt")
    assert Statement.resource_match?(s, "arn:aws:s3:::b/private/a.txt")
  end

  test "AWS:* 归一化为 :any" do
    json =
      ~s({"Statement":{"Effect":"Allow","Principal":{"AWS":"*"},"Action":"s3:GetObject","Resource":"arn:aws:s3:::b/*"}})

    assert {:ok, [s]} = Statement.parse_policy(json)
    assert s.principals == :any
  end

  test "畸形：非 JSON" do
    assert {:error, :malformed} = Statement.parse_policy("not json")
  end

  test "畸形：Effect 非法" do
    json =
      ~s({"Statement":{"Effect":"Permit","Principal":"*","Action":"s3:*","Resource":"arn:aws:s3:::b"}})

    assert {:error, :malformed} = Statement.parse_policy(json)
  end

  test "畸形：bucket policy 缺 Principal" do
    json =
      ~s({"Statement":{"Effect":"Allow","Action":"s3:GetObject","Resource":"arn:aws:s3:::b/*"}})

    assert {:error, :malformed} = Statement.parse_policy(json)
  end

  test "identity policy 缺 Principal 合法并隐式绑定当前 principal" do
    json =
      ~s({"Statement":{"Effect":"Allow","Action":"s3:GetObject","Resource":"arn:aws:s3:::b/*"}})

    assert {:ok, [s]} = Statement.parse_identity_policy(json)
    assert s.principals == :any
    assert s.actions == ["s3:GetObject"]
  end

  test "identity policy accepts MinIO admin action without Resource as global wildcard" do
    json =
      ~s({"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"admin:Prometheus"}]})

    assert {:ok, [s]} = Statement.parse_identity_policy(json)
    assert s.principals == :any
    assert s.actions == ["admin:Prometheus"]
    assert s.resources == ["*"]
    assert Statement.resource_match?(s, "arn:aws:s3:::*")
  end

  test "role trust policy accepts WebIdentity federated principal" do
    json =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Principal":{"Federated":"arn:aws:iam:::oidc-provider/issuer.example.test"},"Action":"sts:AssumeRoleWithWebIdentity","Condition":{"StringEquals":{"issuer.example.test:aud":"sts.amazonaws.com"}}}})

    assert {:ok, [statement]} =
             Statement.parse_trust_policy(json, "arn:aws:iam:::role/webid")

    assert statement.principals ==
             {:federated, ["arn:aws:iam:::oidc-provider/issuer.example.test"]}

    assert statement.actions == ["sts:AssumeRoleWithWebIdentity"]
  end

  test "role trust policy preserves mixed AWS and Federated principals" do
    json =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Principal":{"AWS":"arn:aws:iam:::root","Federated":"arn:aws:iam:::oidc-provider/issuer.example.test"},"Action":["sts:AssumeRole","sts:AssumeRoleWithWebIdentity"]}})

    assert {:ok, [statement]} =
             Statement.parse_trust_policy(json, "arn:aws:iam:::role/mixed")

    assert statement.principals ==
             {:mixed,
              %{
                aws: ["arn:aws:iam:::root"],
                federated: ["arn:aws:iam:::oidc-provider/issuer.example.test"]
              }}

    bad_json =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Principal":{"Federated":"arn:aws:iam:::oidc-provider/issuer.example.test","AWS":[123]},"Action":"sts:AssumeRoleWithWebIdentity"}})

    assert {:error, :malformed} =
             Statement.parse_trust_policy(bad_json, "arn:aws:iam:::role/mixed")
  end

  test "identity policy still rejects S3 action without Resource" do
    json =
      ~s({"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"s3:GetObject"}]})

    assert {:error, :malformed} = Statement.parse_identity_policy(json)
  end

  test "identity policy 显式 Principal → malformed" do
    json =
      ~s({"Statement":{"Effect":"Allow","Principal":"*","Action":"s3:GetObject","Resource":"arn:aws:s3:::b/*"}})

    assert {:error, :malformed} = Statement.parse_identity_policy(json)
  end

  test "identity policy 显式 NotPrincipal → malformed" do
    json =
      ~s({"Statement":{"Effect":"Deny","NotPrincipal":"*","Action":"s3:GetObject","Resource":"arn:aws:s3:::b/*"}})

    assert {:error, :malformed} = Statement.parse_identity_policy(json)
  end

  test "畸形：缺 Action" do
    json = ~s({"Statement":{"Effect":"Allow","Principal":"*","Resource":"arn:aws:s3:::b"}})
    assert {:error, :malformed} = Statement.parse_policy(json)
  end

  test "畸形：Action/NotAction、Resource/NotResource、Principal/NotPrincipal 互斥" do
    both_action =
      ~s({"Statement":{"Effect":"Allow","Principal":"*","Action":"s3:GetObject","NotAction":"s3:PutObject","Resource":"arn:aws:s3:::b/*"}})

    both_resource =
      ~s({"Statement":{"Effect":"Allow","Principal":"*","Action":"s3:GetObject","Resource":"arn:aws:s3:::b/*","NotResource":"arn:aws:s3:::b/private/*"}})

    both_principal =
      ~s({"Statement":{"Effect":"Deny","Principal":"*","NotPrincipal":{"AWS":"arn:aws:iam:::user/alice"},"Action":"s3:GetObject","Resource":"arn:aws:s3:::b/*"}})

    assert {:error, :malformed} = Statement.parse_policy(both_action)
    assert {:error, :malformed} = Statement.parse_policy(both_resource)
    assert {:error, :malformed} = Statement.parse_policy(both_principal)
  end

  test "畸形：selector 与 principal 列表中混入非法值时整体拒绝" do
    bad_action =
      ~s({"Statement":{"Effect":"Allow","Principal":"*","Action":["s3:GetObject",123],"Resource":"arn:aws:s3:::b/*"}})

    bad_not_resource =
      ~s({"Statement":{"Effect":"Deny","Principal":"*","Action":"s3:GetObject","NotResource":["arn:aws:s3:::b/public/*",""]}})

    bad_principal =
      ~s({"Statement":{"Effect":"Allow","Principal":{"AWS":["arn:aws:iam:::user/alice",123]},"Action":"s3:GetObject","Resource":"arn:aws:s3:::b/*"}})

    bad_empty_principal =
      ~s({"Statement":{"Effect":"Allow","Principal":{"AWS":""},"Action":"s3:GetObject","Resource":"arn:aws:s3:::b/*"}})

    bad_deferred_principal =
      ~s({"Statement":{"Effect":"Allow","Principal":{"Service":["logging.s3.amazonaws.com",123]},"Action":"s3:GetObject","Resource":"arn:aws:s3:::b/*"}})

    assert {:error, :malformed} = Statement.parse_policy(bad_action)
    assert {:error, :malformed} = Statement.parse_policy(bad_not_resource)
    assert {:error, :malformed} = Statement.parse_policy(bad_principal)
    assert {:error, :malformed} = Statement.parse_policy(bad_empty_principal)
    assert {:error, :malformed} = Statement.parse_policy(bad_deferred_principal)
  end

  test "畸形：NotPrincipal 只支持 Deny" do
    json =
      ~s({"Statement":{"Effect":"Allow","NotPrincipal":{"AWS":"arn:aws:iam:::user/alice"},"Action":"s3:GetObject","Resource":"arn:aws:s3:::b/*"}})

    assert {:error, :malformed} = Statement.parse_policy(json)
  end

  test "畸形：Version 未知" do
    json =
      ~s({"Version":"1999-01-01","Statement":{"Effect":"Allow","Principal":"*","Action":"s3:*","Resource":"arn:aws:s3:::b"}})

    assert {:error, :malformed} = Statement.parse_policy(json)
  end

  test "Condition 透传为 map" do
    json =
      ~s({"Statement":{"Effect":"Deny","Principal":"*","Action":"s3:*","Resource":["arn:aws:s3:::b","arn:aws:s3:::b/*"],"Condition":{"Bool":{"aws:SecureTransport":"false"}}}})

    assert {:ok, [s]} = Statement.parse_policy(json)
    assert s.conditions == %{"Bool" => %{"aws:SecureTransport" => "false"}}
  end

  test "parse_policy/2 拒绝跨桶 Resource" do
    json =
      ~s({"Statement":[{"Effect":"Allow","Principal":"*","Action":"s3:GetObject","Resource":"arn:aws:s3:::other/*"}]})

    assert {:error, :malformed} = Statement.parse_policy(json, "mybucket")
  end

  test "parse_policy/2 接受引用目标桶的 Resource（精确与通配）" do
    json =
      ~s({"Statement":[{"Effect":"Allow","Principal":"*","Action":"s3:GetObject","Resource":["arn:aws:s3:::mybucket/*","arn:aws:s3:::my*"]}]})

    assert {:ok, [_]} = Statement.parse_policy(json, "mybucket")
  end

  test "parse_policy/2 accepts policy variables in the object-key part of Resource" do
    json =
      ~s({"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":"*","Action":"s3:GetObject","Resource":"arn:aws:s3:::mybucket/home/${aws:username}/*"}]})

    assert {:ok, [s]} = Statement.parse_policy(json, "mybucket")
    assert s.variables_enabled?
  end

  test "missing or legacy policy Version keeps variables disabled" do
    missing =
      ~s({"Statement":[{"Effect":"Allow","Principal":"*","Action":"s3:GetObject","Resource":"arn:aws:s3:::mybucket/home/${aws:username}/*"}]})

    legacy =
      ~s({"Version":"2008-10-17","Statement":[{"Effect":"Allow","Principal":"*","Action":"s3:GetObject","Resource":"arn:aws:s3:::mybucket/home/${aws:username}/*"}]})

    assert {:ok, [s1]} = Statement.parse_policy(missing, "mybucket")
    assert {:ok, [s2]} = Statement.parse_policy(legacy, "mybucket")
    refute s1.variables_enabled?
    refute s2.variables_enabled?
  end

  test "parse_policy/2 接受引用目标桶的 NotResource，拒绝跨桶 NotResource" do
    ok_json =
      ~s({"Statement":[{"Effect":"Deny","Principal":"*","Action":"s3:GetObject","NotResource":["arn:aws:s3:::mybucket/public/*"]}]})

    bad_json =
      ~s({"Statement":[{"Effect":"Deny","Principal":"*","Action":"s3:GetObject","NotResource":["arn:aws:s3:::other/public/*"]}]})

    assert {:ok, [_]} = Statement.parse_policy(ok_json, "mybucket")
    assert {:error, :malformed} = Statement.parse_policy(bad_json, "mybucket")
  end

  test "parse_policy/2 精确桶名（无 /*）也接受" do
    json =
      ~s({"Statement":[{"Effect":"Allow","Principal":"*","Action":"s3:ListBucket","Resource":"arn:aws:s3:::mybucket"}]})

    assert {:ok, [_]} = Statement.parse_policy(json, "mybucket")
  end

  test "parse_policy/2 无 arn 前缀的 Resource → 畸形" do
    json =
      ~s({"Statement":[{"Effect":"Allow","Principal":"*","Action":"s3:GetObject","Resource":"mybucket/*"}]})

    assert {:error, :malformed} = Statement.parse_policy(json, "mybucket")
  end

  test "parse_policy/1 不做桶校验（向后兼容回读）" do
    json =
      ~s({"Statement":[{"Effect":"Allow","Principal":"*","Action":"s3:GetObject","Resource":"arn:aws:s3:::other/*"}]})

    assert {:ok, [_]} = Statement.parse_policy(json)
  end

  test "parse_conditions 拒绝真正不存在的算子（NotAnOperator）→ malformed" do
    json =
      ~s({"Statement":[{"Effect":"Deny","Principal":"*","Action":"s3:GetObject","Resource":"arn:aws:s3:::b/*","Condition":{"NotAnOperator":{"s3:prefix":"x"}}}]})

    assert {:error, :malformed} = Statement.parse_policy(json, "b")
  end

  test "parse_conditions 拒绝显式空 Condition 和空 operator map" do
    empty_condition =
      ~s({"Statement":[{"Effect":"Allow","Principal":"*","Action":"s3:GetObject","Resource":"arn:aws:s3:::b/*","Condition":{}}]})

    empty_operator =
      ~s({"Statement":[{"Effect":"Allow","Principal":"*","Action":"s3:GetObject","Resource":"arn:aws:s3:::b/*","Condition":{"StringEquals":{}}}]})

    empty_key =
      ~s({"Statement":[{"Effect":"Allow","Principal":"*","Action":"s3:GetObject","Resource":"arn:aws:s3:::b/*","Condition":{"StringEquals":{"":"x"}}}]})

    assert {:error, :malformed} = Statement.parse_policy(empty_condition, "b")
    assert {:error, :malformed} = Statement.parse_policy(empty_operator, "b")
    assert {:error, :malformed} = Statement.parse_policy(empty_key, "b")
  end

  test "parse_conditions 接受已实现求值的算子（Bool）" do
    json =
      ~s({"Statement":[{"Effect":"Allow","Principal":"*","Action":"s3:GetObject","Resource":"arn:aws:s3:::b/*","Condition":{"Bool":{"aws:SecureTransport":"true"}}}]})

    assert {:ok, [_]} = Statement.parse_policy(json, "b")
  end

  test "parse_conditions 接受 StringEqualsIgnoreCase/NumericLessThan/Null 算子" do
    json =
      ~s({"Statement":[{"Effect":"Deny","Principal":"*","Action":"s3:GetObject","Resource":"arn:aws:s3:::b/*","Condition":{"StringEqualsIgnoreCase":{"s3:prefix":"x"},"NumericLessThan":{"s3:max-keys":"10"},"Null":{"s3:x-amz-server-side-encryption":"true"}}}]})

    assert {:ok, [_]} = Statement.parse_policy(json, "b")
  end

  test "parse_conditions 接受合法的 *IfExists 变体（StringLikeIfExists）" do
    json =
      ~s({"Statement":[{"Effect":"Allow","Principal":"*","Action":"s3:GetObject","Resource":"arn:aws:s3:::b/*","Condition":{"StringLikeIfExists":{"s3:prefix":"home/*"}}}]})

    assert {:ok, [_]} = Statement.parse_policy(json, "b")
  end

  test "parse_conditions 接受 ForAnyValue / ForAllValues 集合算子与 IfExists 组合" do
    json =
      ~s({"Statement":[{"Effect":"Allow","Principal":"*","Action":"s3:ListBucket","Resource":"arn:aws:s3:::b","Condition":{"ForAnyValue:StringLike":{"s3:prefix":["home/*","public/*"]},"ForAllValues:StringEqualsIfExists":{"s3:delimiter":"/"}}}]})

    assert {:ok, [s]} = Statement.parse_policy(json, "b")
    assert Map.has_key?(s.conditions, "ForAnyValue:StringLike")
    assert Map.has_key?(s.conditions, "ForAllValues:StringEqualsIfExists")
  end

  test "parse_conditions 拒绝 Null 的 IfExists 或集合算子变体" do
    for op <- [
          "NullIfExists",
          "ForAnyValue:Null",
          "ForAllValues:Null",
          "ForAnyValue:NullIfExists"
        ] do
      json =
        ~s({"Statement":[{"Effect":"Deny","Principal":"*","Action":"s3:GetObject","Resource":"arn:aws:s3:::b/*","Condition":{"#{op}":{"s3:x-amz-server-side-encryption":"true"}}}]})

      assert {:error, :malformed} = Statement.parse_policy(json, "b")
    end
  end

  test "rejects duplicate JSON object keys at every nesting level" do
    bucket_duplicate =
      ~s({"Statement":{"Effect":"Allow","Principal":"*","Action":"s3:GetObject","Action":"s3:PutObject","Resource":"arn:aws:s3:::b/*"}})

    identity_duplicate =
      ~s({"Statement":{"Effect":"Allow","Action":"s3:GetObject","Resource":"arn:aws:s3:::b/*","Condition":{"StringEquals":{"s3:prefix":"a","s3:prefix":"b"}}}})

    assert {:error, :malformed} = Statement.parse_policy(bucket_duplicate)
    assert {:error, :malformed} = Statement.parse_identity_policy(identity_duplicate)
  end
end
