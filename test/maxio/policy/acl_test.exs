defmodule Maxio.Policy.ACLTest do
  use ExUnit.Case, async: true
  alias Maxio.Policy.{ACL, Evaluator, RequestContext}

  defp anon(action, resource, conds \\ %{}) do
    %RequestContext{
      principal: :anonymous,
      authenticated?: false,
      owner?: false,
      action: action,
      resource: resource,
      conditions: conds
    }
  end

  defp user(arn, action, resource, conds \\ %{}) do
    %RequestContext{
      principal: %{type: :iam_user, access_key: "ak", arn: arn},
      authenticated?: true,
      owner?: false,
      action: action,
      resource: resource,
      conditions: Map.put_new(conds, "maxio:Authenticated", "true")
    }
  end

  test "private 对象 ACL → 无公共 statement（匿名隐拒）" do
    stmts = ACL.canned_to_statements("private", :object, "b", "k")
    assert stmts == []

    assert Evaluator.evaluate(anon("s3:GetObject", "arn:aws:s3:::b/k"), stmts) ==
             {:deny, :implicit_deny}
  end

  test "public-read 对象 → 匿名 GetObject allow" do
    stmts = ACL.canned_to_statements("public-read", :object, "b", "k")
    assert Evaluator.evaluate(anon("s3:GetObject", "arn:aws:s3:::b/k"), stmts) == :allow

    assert Evaluator.evaluate(anon("s3:PutObject", "arn:aws:s3:::b/k"), stmts) ==
             {:deny, :implicit_deny}
  end

  test "public-read-write 对象 → 匿名 Put 也 allow" do
    stmts = ACL.canned_to_statements("public-read-write", :object, "b", "k")
    assert Evaluator.evaluate(anon("s3:PutObject", "arn:aws:s3:::b/k"), stmts) == :allow
  end

  test "public-read 桶 → 匿名 ListBucket allow（桶 ARN）" do
    stmts = ACL.canned_to_statements("public-read", :bucket, "b", nil)
    assert Evaluator.evaluate(anon("s3:ListBucket", "arn:aws:s3:::b"), stmts) == :allow
  end

  test "authenticated-read 对象 → 匿名隐拒，认证放行" do
    stmts = ACL.canned_to_statements("authenticated-read", :object, "b", "k")

    # 匿名：maxio:Authenticated 缺键/false → 条件不成立 → 隐拒
    assert Evaluator.evaluate(
             anon("s3:GetObject", "arn:aws:s3:::b/k", %{"maxio:Authenticated" => "false"}),
             stmts
           ) == {:deny, :implicit_deny}

    # 认证：maxio:Authenticated=="true" → allow
    assert Evaluator.evaluate(
             anon("s3:GetObject", "arn:aws:s3:::b/k", %{"maxio:Authenticated" => "true"}),
             stmts
           ) == :allow
  end

  test "bucket-owner-* / 未知 canned → 无公共 statement（按 private）" do
    assert ACL.canned_to_statements("bucket-owner-full-control", :object, "b", "k") == []
    assert ACL.canned_to_statements("aws-exec-read", :object, "b", "k") == []
  end

  test "XML round-trip：parser 分类回 canned" do
    {:ok, canned} =
      Maxio.S3.RequestParsers.AccessControlPolicy.parse(~s(
        <AccessControlPolicy><AccessControlList>
          <Grant><Grantee xsi:type="Group"><URI>http://acs.amazonaws.com/groups/global/AllUsers</URI></Grantee><Permission>READ</Permission></Grant>
        </AccessControlList></AccessControlPolicy>))

    assert canned == "public-read"
  end

  test "x-amz-grant-* headers parse group grants and reject email grantees" do
    {:ok, grants} =
      ACL.parse_grant_headers([
        {"x-amz-grant-read", ~s(uri="http://acs.amazonaws.com/groups/global/AllUsers")},
        {"x-amz-grant-write-acp", "uri=http://acs.amazonaws.com/groups/global/AuthenticatedUsers"}
      ])

    assert ACL.classify_grants(grants) == "custom"
    assert length(grants) == 2

    assert {:error, :unsupported_email} =
             ACL.parse_grant_headers([{"x-amz-grant-read", ~s(emailAddress="a@example.com")}])

    assert {:error, :invalid_grant} = ACL.parse_grant_headers([{"x-amz-grant-read", ""}])
  end

  test "explicit AllUsers READ object grant allows anonymous GetObject only" do
    {:ok, grants} =
      ACL.normalize_grants([
        %{
          "grantee" => %{
            "type" => "Group",
            "uri" => "http://acs.amazonaws.com/groups/global/AllUsers"
          },
          "permission" => "READ"
        }
      ])

    stmts = ACL.grants_to_statements(grants, :object, "b", "k")
    assert Evaluator.evaluate(anon("s3:GetObject", "arn:aws:s3:::b/k"), stmts) == :allow

    assert Evaluator.evaluate(anon("s3:PutObject", "arn:aws:s3:::b/k"), stmts) ==
             {:deny, :implicit_deny}
  end

  test "explicit canonical user grant matches principal ARN exactly" do
    alice = "arn:aws:iam:::user/alice"
    bob = "arn:aws:iam:::user/bob"

    {:ok, grants} =
      ACL.normalize_grants([
        %{
          "grantee" => %{"type" => "CanonicalUser", "id" => alice},
          "permission" => "READ_ACP"
        }
      ])

    stmts = ACL.grants_to_statements(grants, :object, "b", "k")
    assert Evaluator.evaluate(user(alice, "s3:GetObjectAcl", "arn:aws:s3:::b/k"), stmts) == :allow

    assert Evaluator.evaluate(user(bob, "s3:GetObjectAcl", "arn:aws:s3:::b/k"), stmts) ==
             {:deny, :implicit_deny}
  end
end
