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
  end
end
