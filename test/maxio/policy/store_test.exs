defmodule Maxio.Policy.StoreTest do
  use Maxio.DataCase, async: false
  alias Maxio.Cluster.Notify
  alias Maxio.Policy.Store

  @policy ~s({"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":"*","Action":"s3:GetObject","Resource":"arn:aws:s3:::b/*"}]})

  test "put → get round-trip（语义等价）" do
    assert :ok = Store.put_bucket_policy("b", @policy)
    assert {:ok, json} = Store.get_bucket_policy("b")
    assert {:ok, decoded} = Jason.decode(json)
    assert decoded["Statement"] |> hd() |> Map.get("Effect") == "Allow"
  end

  test "无 policy → :none / []" do
    assert :none = Store.get_bucket_policy("nope")
    assert [] = Store.statements_for_bucket("nope")
  end

  test "statements_for_bucket 解析为 Statement 列表" do
    Store.put_bucket_policy("b2", @policy)
    assert [%Maxio.Policy.Statement{effect: :allow}] = Store.statements_for_bucket("b2")
  end

  test "put 覆盖（upsert）" do
    Store.put_bucket_policy("b3", @policy)

    deny =
      ~s({"Statement":{"Effect":"Deny","Principal":"*","Action":"s3:*","Resource":["arn:aws:s3:::b3","arn:aws:s3:::b3/*"]}})

    assert :ok = Store.put_bucket_policy("b3", deny)
    assert [%{effect: :deny}] = Store.statements_for_bucket("b3")
  end

  test "delete 幂等" do
    Store.put_bucket_policy("b4", @policy)
    assert :ok = Store.delete_bucket_policy("b4")
    assert :none = Store.get_bucket_policy("b4")
    assert :ok = Store.delete_bucket_policy("b4")
  end

  test "principal_policies 匿名恒空" do
    assert [] = Store.principal_policies(:anonymous)
  end

  test "principal identity policy put/list/delete and parse" do
    principal_arn = "arn:aws:iam:::user/AKIAIDENTITY1"

    policy =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:GetObject","Resource":"arn:aws:s3:::identity/*"}})

    assert :ok = Store.put_principal_policy(principal_arn, "read-identity", policy)

    assert [%{principal_arn: ^principal_arn, policy_name: "read-identity"}] =
             Store.list_principal_policies(principal_arn)

    assert [%Maxio.Policy.Statement{effect: :allow, actions: ["s3:GetObject"]}] =
             Store.principal_policies(%{type: :iam_user, arn: principal_arn})

    assert :ok = Store.delete_principal_policy(principal_arn, "read-identity")
    assert [] = Store.list_principal_policies(principal_arn)
    assert [] = Store.principal_policies(%{type: :iam_user, arn: principal_arn})
  end

  test "managed session policy registry create, put, list, get, and delete" do
    policy_arn = "arn:aws:iam:::policy/session-read"

    policy =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:GetObject","Resource":"arn:aws:s3:::identity/*"}})

    put_policy =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:PutObject","Resource":"arn:aws:s3:::identity/*"}})

    assert :ok = Store.create_managed_session_policy(policy_arn, policy)
    assert {:error, :already_exists} = Store.create_managed_session_policy(policy_arn, put_policy)

    assert {:error, :already_exists} =
             Store.create_managed_session_policy(String.upcase(policy_arn), put_policy)

    assert Enum.any?(Store.list_managed_session_policies(), &(&1.policy_arn == policy_arn))

    assert {:ok, json} = Store.managed_session_policy(policy_arn)
    assert {:ok, decoded} = Jason.decode(json)
    assert get_in(decoded, ["Statement", "Action"]) == "s3:GetObject"

    assert :ok = Store.put_managed_session_policy(policy_arn, put_policy)
    assert {:ok, put_json} = Store.managed_session_policy(policy_arn)
    assert {:ok, put_decoded} = Jason.decode(put_json)
    assert get_in(put_decoded, ["Statement", "Action"]) == "s3:PutObject"

    assert :ok = Store.delete_managed_session_policy(policy_arn)
    assert {:error, :not_found} = Store.managed_session_policy(policy_arn)
    assert {:error, :not_found} = Store.managed_session_policy("arn:aws:iam:::policy/missing")
  end

  test "role attached managed policies participate in role principal policies" do
    role_arn = "arn:aws:iam:::role/store-attached-role"
    policy_arn = "arn:aws:iam:::policy/store-attached-read"
    unattached_policy_arn = "arn:aws:iam:::policy/store-unattached-write"

    trust_policy = %{
      "Version" => "2012-10-17",
      "Statement" => %{
        "Effect" => "Allow",
        "Principal" => %{"AWS" => "arn:aws:iam:::root"},
        "Action" => "sts:AssumeRole"
      }
    }

    {:ok, _role} =
      Maxio.IAM.create_role(
        role_name: "store-attached-role",
        trust_policy: trust_policy
      )

    read_policy =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:GetObject","Resource":"arn:aws:s3:::attached/*"}})

    write_policy =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:PutObject","Resource":"arn:aws:s3:::attached/*"}})

    assert :ok = Store.create_managed_session_policy(policy_arn, read_policy)
    assert :ok = Store.create_managed_session_policy(unattached_policy_arn, write_policy)

    assert :ok = Store.attach_role_managed_policy(role_arn, policy_arn)

    assert [%Maxio.Policy.Statement{actions: ["s3:GetObject"]}] =
             Store.principal_policies(%{arn: role_arn})

    assert [
             %{
               role_arn: ^role_arn,
               policy_arn: ^policy_arn,
               document: %{"Statement" => %{"Action" => "s3:GetObject"}}
             }
           ] = Store.list_attached_role_managed_policies(role_arn)

    assert Store.managed_session_policy_attached?(policy_arn)
    refute Store.managed_session_policy_attached?(unattached_policy_arn)
    assert {:error, :policy_attached} = Store.delete_managed_session_policy(policy_arn)

    assert :ok = Store.detach_role_managed_policy(role_arn, policy_arn)
    assert [] = Store.principal_policies(%{arn: role_arn})
  end

  test "principal identity policy rejects explicit Principal" do
    bad =
      ~s({"Statement":{"Effect":"Allow","Principal":"*","Action":"s3:GetObject","Resource":"arn:aws:s3:::identity/*"}})

    assert {:error, :malformed} = Store.put_principal_policy("arn:aws:iam:::user/bad", "bad", bad)
  end

  test "policy mutations broadcast metadata invalidation" do
    :ok = Phoenix.PubSub.subscribe(Maxio.PubSub, Notify.topic())

    assert :ok = Store.put_bucket_policy("notify-policy-bucket", @policy)
    assert_receive {:bucket_policy_changed, "notify-policy-bucket"}

    assert :ok = Store.delete_bucket_policy("notify-policy-bucket")
    assert_receive {:bucket_policy_changed, "notify-policy-bucket"}

    principal_arn = "arn:aws:iam:::user/AKIANOTIFYPOLICY"

    identity_policy =
      ~s({"Statement":{"Effect":"Allow","Action":"s3:ListBucket","Resource":"arn:aws:s3:::notify-policy-bucket"}})

    assert :ok = Store.put_principal_policy(principal_arn, "list", identity_policy)
    assert_receive {:principal_policy_changed, ^principal_arn}

    assert :ok = Store.delete_principal_policy(principal_arn, "list")
    assert_receive {:principal_policy_changed, ^principal_arn}

    managed_policy_arn = "arn:aws:iam:::policy/notify-session-boundary"
    assert :ok = Store.put_managed_session_policy(managed_policy_arn, identity_policy)
    assert_receive {:managed_session_policy_changed, ^managed_policy_arn}
  end
end
