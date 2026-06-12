defmodule Maxio.Policy.EvaluatorTest do
  use ExUnit.Case, async: true
  alias Maxio.Policy.{Evaluator, RequestContext, Statement}

  defp parse!(json), do: (fn {:ok, s} -> s end).(Statement.parse_policy(json))

  defp anon_ctx(action, resource, conds \\ %{}) do
    %RequestContext{
      principal: :anonymous,
      authenticated?: false,
      owner?: false,
      action: action,
      resource: resource,
      conditions: conds
    }
  end

  defp auth_ctx(arn, action, resource, conds \\ %{}) do
    %RequestContext{
      principal: %{type: :iam_user, access_key: "ak", arn: arn},
      authenticated?: true,
      owner?: false,
      action: action,
      resource: resource,
      conditions: conds
    }
  end

  test "owner 短路放行（无视 statements）" do
    ctx = %RequestContext{owner?: true, action: "s3:DeleteObject", resource: "arn:aws:s3:::b/k"}
    assert Evaluator.evaluate(ctx, []) == :allow
  end

  test "默认拒绝（无 statement）" do
    assert Evaluator.evaluate(anon_ctx("s3:GetObject", "arn:aws:s3:::b/k"), []) ==
             {:deny, :implicit_deny}
  end

  test "public-read 放行匿名 GetObject" do
    stmts =
      parse!(
        ~s({"Statement":{"Effect":"Allow","Principal":"*","Action":"s3:GetObject","Resource":"arn:aws:s3:::b/*"}})
      )

    assert Evaluator.evaluate(anon_ctx("s3:GetObject", "arn:aws:s3:::b/k.txt"), stmts) == :allow
  end

  test "public-read 不放行 PutObject（action 不匹配 → 隐式拒绝）" do
    stmts =
      parse!(
        ~s({"Statement":{"Effect":"Allow","Principal":"*","Action":"s3:GetObject","Resource":"arn:aws:s3:::b/*"}})
      )

    assert Evaluator.evaluate(anon_ctx("s3:PutObject", "arn:aws:s3:::b/k.txt"), stmts) ==
             {:deny, :implicit_deny}
  end

  test "对象 action 不命中桶 ARN 资源（resource 层级错配 → 隐式拒绝）" do
    # Resource 写成桶 ARN（无 /*），GetObject 是对象动作 → 资源不匹配。
    stmts =
      parse!(
        ~s({"Statement":{"Effect":"Allow","Principal":"*","Action":"s3:GetObject","Resource":"arn:aws:s3:::b"}})
      )

    assert Evaluator.evaluate(anon_ctx("s3:GetObject", "arn:aws:s3:::b/k"), stmts) ==
             {:deny, :implicit_deny}
  end

  test "显式 Deny 压倒 Allow（同 principal 同动作）" do
    stmts = parse!(~s({"Statement":[
      {"Effect":"Allow","Principal":"*","Action":"s3:*","Resource":["arn:aws:s3:::b","arn:aws:s3:::b/*"]},
      {"Effect":"Deny","Principal":"*","Action":"s3:DeleteObject","Resource":"arn:aws:s3:::b/*"}
    ]}))

    assert Evaluator.evaluate(anon_ctx("s3:DeleteObject", "arn:aws:s3:::b/k"), stmts) ==
             {:deny, :explicit_deny}

    assert Evaluator.evaluate(anon_ctx("s3:GetObject", "arn:aws:s3:::b/k"), stmts) == :allow
  end

  test "s3:* 通配 action 命中具体动作（大小写不敏感）" do
    stmts =
      parse!(
        ~s({"Statement":{"Effect":"Allow","Principal":"*","Action":"s3:*","Resource":"arn:aws:s3:::b/*"}})
      )

    assert Evaluator.evaluate(anon_ctx("s3:GetObject", "arn:aws:s3:::b/k"), stmts) == :allow
  end

  test "NotAction Allow 放行未列动作但不影响列出的动作" do
    stmts =
      parse!(
        ~s({"Statement":{"Effect":"Allow","Principal":"*","NotAction":"s3:DeleteBucket","Resource":"arn:aws:s3:::b"}})
      )

    assert Evaluator.evaluate(anon_ctx("s3:ListBucket", "arn:aws:s3:::b"), stmts) == :allow

    assert Evaluator.evaluate(anon_ctx("s3:DeleteBucket", "arn:aws:s3:::b"), stmts) ==
             {:deny, :implicit_deny}
  end

  test "NotAction Deny 显式拒绝未列动作，列出的动作仍可被 Allow 放行" do
    stmts =
      parse!(~s({"Statement":[
        {"Effect":"Allow","Principal":"*","Action":"s3:*","Resource":"arn:aws:s3:::b/*"},
        {"Effect":"Deny","Principal":"*","NotAction":"s3:GetObject","Resource":"arn:aws:s3:::b/*"}
      ]}))

    assert Evaluator.evaluate(anon_ctx("s3:PutObject", "arn:aws:s3:::b/k"), stmts) ==
             {:deny, :explicit_deny}

    assert Evaluator.evaluate(anon_ctx("s3:GetObject", "arn:aws:s3:::b/k"), stmts) == :allow
  end

  test "NotResource Deny 拒绝未列资源，列出的资源仍可被 Allow 放行" do
    stmts =
      parse!(~s({"Statement":[
        {"Effect":"Allow","Principal":"*","Action":"s3:GetObject","Resource":"arn:aws:s3:::b/*"},
        {"Effect":"Deny","Principal":"*","Action":"s3:GetObject","NotResource":"arn:aws:s3:::b/public/*"}
      ]}))

    assert Evaluator.evaluate(anon_ctx("s3:GetObject", "arn:aws:s3:::b/private/k"), stmts) ==
             {:deny, :explicit_deny}

    assert Evaluator.evaluate(anon_ctx("s3:GetObject", "arn:aws:s3:::b/public/k"), stmts) ==
             :allow
  end

  test "Resource policy variables expand from request context" do
    stmts =
      parse!(
        ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Principal":"*","Action":"s3:GetObject","Resource":"arn:aws:s3:::b/home/${aws:username}/*"}})
      )

    assert Evaluator.evaluate(
             auth_ctx(
               "arn:aws:iam:::user/alice",
               "s3:GetObject",
               "arn:aws:s3:::b/home/alice/doc.txt",
               %{"aws:username" => "alice"}
             ),
             stmts
           ) == :allow

    assert Evaluator.evaluate(
             auth_ctx(
               "arn:aws:iam:::user/alice",
               "s3:GetObject",
               "arn:aws:s3:::b/home/bob/doc.txt",
               %{"aws:username" => "alice"}
             ),
             stmts
           ) == {:deny, :implicit_deny}

    assert Evaluator.evaluate(
             auth_ctx(
               "arn:aws:iam:::user/alice",
               "s3:GetObject",
               "arn:aws:s3:::b/home/alice/doc.txt",
               %{}
             ),
             stmts
           ) == {:deny, :implicit_deny}
  end

  test "policy variables require 2012-10-17 policy version" do
    no_version =
      parse!(
        ~s({"Statement":{"Effect":"Allow","Principal":"*","Action":"s3:GetObject","Resource":"arn:aws:s3:::b/home/${aws:username}/*"}})
      )

    legacy_version =
      parse!(
        ~s({"Version":"2008-10-17","Statement":{"Effect":"Allow","Principal":"*","Action":"s3:GetObject","Resource":"arn:aws:s3:::b/home/${aws:username}/*"}})
      )

    ctx =
      auth_ctx(
        "arn:aws:iam:::user/alice",
        "s3:GetObject",
        "arn:aws:s3:::b/home/alice/doc.txt",
        %{"aws:username" => "alice"}
      )

    assert Evaluator.evaluate(ctx, no_version) == {:deny, :implicit_deny}
    assert Evaluator.evaluate(ctx, legacy_version) == {:deny, :implicit_deny}
  end

  test "disabled policy variables keep special variable syntax literal in resources" do
    stmts =
      parse!(
        ~s({"Statement":{"Effect":"Allow","Principal":"*","Action":"s3:GetObject","Resource":"arn:aws:s3:::b/file${*}.txt"}})
      )

    assert Evaluator.evaluate(
             anon_ctx("s3:GetObject", "arn:aws:s3:::b/file${*}.txt"),
             stmts
           ) == :allow

    assert Evaluator.evaluate(
             anon_ctx("s3:GetObject", "arn:aws:s3:::b/file${abc}.txt"),
             stmts
           ) == {:deny, :implicit_deny}
  end

  test "condition policy variables also require 2012-10-17 policy version" do
    versioned =
      parse!(
        ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Principal":"*","Action":"s3:ListBucket","Resource":"arn:aws:s3:::b","Condition":{"StringEquals":{"s3:prefix":"home/${aws:username}/"}}}})
      )

    unversioned =
      parse!(
        ~s({"Statement":{"Effect":"Allow","Principal":"*","Action":"s3:ListBucket","Resource":"arn:aws:s3:::b","Condition":{"StringEquals":{"s3:prefix":"home/${aws:username}/"}}}})
      )

    ctx =
      anon_ctx("s3:ListBucket", "arn:aws:s3:::b", %{
        "s3:prefix" => "home/alice/",
        "aws:username" => "alice"
      })

    assert Evaluator.evaluate(ctx, versioned) == :allow
    assert Evaluator.evaluate(ctx, unversioned) == {:deny, :implicit_deny}
  end

  test "disabled policy variables keep special variable syntax literal in StringLike conditions" do
    stmts =
      parse!(
        ~s({"Statement":{"Effect":"Allow","Principal":"*","Action":"s3:ListBucket","Resource":"arn:aws:s3:::b","Condition":{"StringLike":{"s3:prefix":"file${*}.txt"}}}})
      )

    assert Evaluator.evaluate(
             anon_ctx("s3:ListBucket", "arn:aws:s3:::b", %{"s3:prefix" => "file${*}.txt"}),
             stmts
           ) == :allow

    assert Evaluator.evaluate(
             anon_ctx("s3:ListBucket", "arn:aws:s3:::b", %{"s3:prefix" => "file${abc}.txt"}),
             stmts
           ) == {:deny, :implicit_deny}
  end

  test "NotResource with only unresolved policy variables does not broaden a Deny" do
    stmts =
      parse!(~s({"Version":"2012-10-17","Statement":[
        {"Effect":"Allow","Principal":"*","Action":"s3:GetObject","Resource":"arn:aws:s3:::b/*"},
        {"Effect":"Deny","Principal":"*","Action":"s3:GetObject","NotResource":"arn:aws:s3:::b/home/${aws:username}/*"}
      ]}))

    assert Evaluator.evaluate(
             anon_ctx("s3:GetObject", "arn:aws:s3:::b/home/alice/doc.txt"),
             stmts
           ) == :allow
  end

  test "NotResource with any unresolved policy variable does not broaden a mixed selector" do
    stmts =
      parse!(~s({"Version":"2012-10-17","Statement":[
        {"Effect":"Allow","Principal":"*","Action":"s3:GetObject","Resource":"arn:aws:s3:::b/*"},
        {"Effect":"Deny","Principal":"*","Action":"s3:GetObject","NotResource":["arn:aws:s3:::b/public/*","arn:aws:s3:::b/home/${aws:username}/*"]}
      ]}))

    assert Evaluator.evaluate(
             anon_ctx("s3:GetObject", "arn:aws:s3:::b/private/doc.txt"),
             stmts
           ) == :allow
  end

  test "NotPrincipal Deny 拒绝除指定 principal 之外的所有请求者" do
    stmts =
      parse!(~s({"Statement":[
        {"Effect":"Allow","Principal":"*","Action":"s3:GetObject","Resource":"arn:aws:s3:::b/*"},
        {"Effect":"Deny","NotPrincipal":{"AWS":"arn:aws:iam:::user/alice"},"Action":"s3:GetObject","Resource":"arn:aws:s3:::b/*"}
      ]}))

    assert Evaluator.evaluate(
             auth_ctx("arn:aws:iam:::user/alice", "s3:GetObject", "arn:aws:s3:::b/k"),
             stmts
           ) == :allow

    assert Evaluator.evaluate(
             auth_ctx("arn:aws:iam:::user/bob", "s3:GetObject", "arn:aws:s3:::b/k"),
             stmts
           ) == {:deny, :explicit_deny}

    assert Evaluator.evaluate(anon_ctx("s3:GetObject", "arn:aws:s3:::b/k"), stmts) ==
             {:deny, :explicit_deny}
  end

  test "认证特定账户 principal：arn 命中放行，不命中隐拒" do
    stmts =
      parse!(
        ~s({"Statement":{"Effect":"Allow","Principal":{"AWS":"arn:aws:iam:::user/alice"},"Action":"s3:GetObject","Resource":"arn:aws:s3:::b/*"}})
      )

    assert Evaluator.evaluate(
             auth_ctx("arn:aws:iam:::user/alice", "s3:GetObject", "arn:aws:s3:::b/k"),
             stmts
           ) == :allow

    assert Evaluator.evaluate(
             auth_ctx("arn:aws:iam:::user/bob", "s3:GetObject", "arn:aws:s3:::b/k"),
             stmts
           ) == {:deny, :implicit_deny}
  end

  test "特定账户 principal 绝不匹配匿名" do
    stmts =
      parse!(
        ~s({"Statement":{"Effect":"Allow","Principal":{"AWS":"arn:aws:iam:::user/alice"},"Action":"s3:GetObject","Resource":"arn:aws:s3:::b/*"}})
      )

    assert Evaluator.evaluate(anon_ctx("s3:GetObject", "arn:aws:s3:::b/k"), stmts) ==
             {:deny, :implicit_deny}
  end

  # ── 条件算子真值表 ──
  test "Deny aws:SecureTransport=false：HTTP 请求命中 Deny，HTTPS 不命中" do
    stmts = parse!(~s({"Statement":[
      {"Effect":"Allow","Principal":"*","Action":"s3:GetObject","Resource":"arn:aws:s3:::b/*"},
      {"Effect":"Deny","Principal":"*","Action":"s3:*","Resource":["arn:aws:s3:::b","arn:aws:s3:::b/*"],"Condition":{"Bool":{"aws:SecureTransport":"false"}}}
    ]}))
    # 明文 HTTP：Deny 命中 → explicit_deny
    assert Evaluator.evaluate(
             anon_ctx("s3:GetObject", "arn:aws:s3:::b/k", %{"aws:SecureTransport" => false}),
             stmts
           ) == {:deny, :explicit_deny}

    # HTTPS：Deny 的 Bool 不命中 → 仅 Allow 命中 → allow
    assert Evaluator.evaluate(
             anon_ctx("s3:GetObject", "arn:aws:s3:::b/k", %{"aws:SecureTransport" => true}),
             stmts
           ) == :allow
  end

  test "StringEquals s3:prefix：命中放行，不命中隐拒（缺键也不命中）" do
    stmts =
      parse!(
        ~s({"Statement":{"Effect":"Allow","Principal":"*","Action":"s3:ListBucket","Resource":"arn:aws:s3:::b","Condition":{"StringEquals":{"s3:prefix":["home/","public/"]}}}})
      )

    assert Evaluator.evaluate(
             anon_ctx("s3:ListBucket", "arn:aws:s3:::b", %{"s3:prefix" => "home/"}),
             stmts
           ) == :allow

    assert Evaluator.evaluate(
             anon_ctx("s3:ListBucket", "arn:aws:s3:::b", %{"s3:prefix" => "secret/"}),
             stmts
           ) == {:deny, :implicit_deny}

    # 缺 s3:prefix 键 → 条件不成立 → 隐拒
    assert Evaluator.evaluate(anon_ctx("s3:ListBucket", "arn:aws:s3:::b", %{}), stmts) ==
             {:deny, :implicit_deny}
  end

  test "StringLike s3:prefix 通配" do
    stmts =
      parse!(
        ~s({"Statement":{"Effect":"Allow","Principal":"*","Action":"s3:ListBucket","Resource":"arn:aws:s3:::b","Condition":{"StringLike":{"s3:prefix":["home/*"]}}}})
      )

    assert Evaluator.evaluate(
             anon_ctx("s3:ListBucket", "arn:aws:s3:::b", %{"s3:prefix" => "home/alice/x"}),
             stmts
           ) == :allow

    assert Evaluator.evaluate(
             anon_ctx("s3:ListBucket", "arn:aws:s3:::b", %{"s3:prefix" => "away/x"}),
             stmts
           ) == {:deny, :implicit_deny}
  end

  test "ForAllValues:StringLike 可约束多值请求上下文" do
    stmts =
      parse!(
        ~s({"Statement":{"Effect":"Allow","Principal":"*","Action":"s3:ListBucket","Resource":"arn:aws:s3:::b","Condition":{"ForAllValues:StringLike":{"s3:prefix":["home/*","public/*"]}}}})
      )

    assert Evaluator.evaluate(
             anon_ctx("s3:ListBucket", "arn:aws:s3:::b", %{
               "s3:prefix" => ["home/alice", "public/readme"]
             }),
             stmts
           ) == :allow

    assert Evaluator.evaluate(
             anon_ctx("s3:ListBucket", "arn:aws:s3:::b", %{
               "s3:prefix" => ["home/alice", "secret/file"]
             }),
             stmts
           ) == {:deny, :implicit_deny}
  end

  test "IpAddress aws:SourceIp CIDR" do
    stmts =
      parse!(
        ~s({"Statement":{"Effect":"Allow","Principal":"*","Action":"s3:GetObject","Resource":"arn:aws:s3:::b/*","Condition":{"IpAddress":{"aws:SourceIp":["203.0.113.0/24"]}}}})
      )

    assert Evaluator.evaluate(
             anon_ctx("s3:GetObject", "arn:aws:s3:::b/k", %{"aws:SourceIp" => "203.0.113.5"}),
             stmts
           ) == :allow

    assert Evaluator.evaluate(
             anon_ctx("s3:GetObject", "arn:aws:s3:::b/k", %{"aws:SourceIp" => "198.51.100.1"}),
             stmts
           ) == {:deny, :implicit_deny}
  end

  test "Numeric 条件算子求值后可命中 statement" do
    stmts =
      parse!(
        ~s({"Statement":{"Effect":"Allow","Principal":"*","Action":"s3:ListBucket","Resource":"arn:aws:s3:::b","Condition":{"NumericLessThanEquals":{"s3:max-keys":"10"}}}})
      )

    assert Evaluator.evaluate(
             anon_ctx("s3:ListBucket", "arn:aws:s3:::b", %{"s3:max-keys" => "10"}),
             stmts
           ) == :allow

    assert Evaluator.evaluate(
             anon_ctx("s3:ListBucket", "arn:aws:s3:::b", %{"s3:max-keys" => "11"}),
             stmts
           ) == {:deny, :implicit_deny}
  end

  test "真正未知条件算子 → 评估期保守不命中（纵深防御）" do
    # FX-M5 后 PutBucketPolicy parse 期已拒绝未支持算子（见 statement_test/bucket_policy_test），
    # 故无法再经 parse_policy 构造含未知算子的策略。此处直接构造 Statement 结构验证
    # Condition.hold?/2 的评估期 fail-closed 守卫（@known 之外算子 → 不命中），确保纵深防御不回归（铁律 3）。
    stmts = [
      %Statement{
        effect: :allow,
        actions: ["s3:GetObject"],
        resources: ["arn:aws:s3:::b/*"],
        principals: :any,
        conditions: %{"NotAnOperator" => %{"s3:max-keys" => "10"}}
      }
    ]

    assert Evaluator.evaluate(
             anon_ctx("s3:GetObject", "arn:aws:s3:::b/k", %{"s3:max-keys" => "5"}),
             stmts
           ) == {:deny, :implicit_deny}
  end
end
