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
    user_name = "AKIAIDENTITY#{System.unique_integer([:positive, :monotonic])}"
    assert {:ok, user} = Maxio.IAM.create_user(name: user_name)
    principal_arn = user.user_arn

    policy =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:GetObject","Resource":"arn:aws:s3:::identity/*"}})

    assert :ok = Store.put_principal_policy(principal_arn, "read-identity", policy)

    assert {:ok,
            %{
              principal_arn: ^principal_arn,
              policy_name: "read-identity",
              document: %{"Statement" => %{"Action" => "s3:GetObject"}}
            }} = Store.get_principal_policy(principal_arn, "read-identity")

    assert [%{principal_arn: ^principal_arn, policy_name: "read-identity"}] =
             Store.list_principal_policies(principal_arn)

    assert [%Maxio.Policy.Statement{effect: :allow, actions: ["s3:GetObject"]}] =
             Store.principal_policies(%{type: :iam_user, arn: principal_arn})

    assert :ok = Store.delete_principal_policy(principal_arn, "read-identity")
    assert {:error, :not_found} = Store.get_principal_policy(principal_arn, "read-identity")
    assert [] = Store.list_principal_policies(principal_arn)
    assert [] = Store.principal_policies(%{type: :iam_user, arn: principal_arn})
  end

  test "group managed policy statements are inherited only while the group is active" do
    suffix = System.unique_integer([:positive, :monotonic])
    user_name = "store-group-user-#{suffix}"
    group_name = "store-group-#{suffix}"
    policy_name = "store-group-policy-#{suffix}"

    assert {:ok, user} = Maxio.IAM.create_user(name: user_name)
    assert {:ok, _} = Maxio.IAM.create_group(name: group_name)
    assert :ok = Maxio.IAM.add_user_to_group(user_name, group_name)

    document = %{
      "Version" => "2012-10-17",
      "Statement" => %{
        "Effect" => "Allow",
        "Action" => "s3:ListAllMyBuckets",
        "Resource" => "*"
      }
    }

    assert {:ok, policy} =
             Maxio.IAM.create_managed_policy(
               name: policy_name,
               path: "/",
               document: document
             )

    assert :ok = Maxio.IAM.attach_group_policy(group_name, policy.policy_arn)

    principal = %{type: :iam_user, arn: user.user_arn}

    assert [%Maxio.Policy.Statement{actions: ["s3:ListAllMyBuckets"]}] =
             Store.principal_policies(principal)

    assert {:ok, _} = Maxio.IAM.update_minio_group_status_strict(group_name, "inactive")
    assert [] = Store.principal_policies(principal)

    assert {:ok, _} = Maxio.IAM.update_minio_group_status_strict(group_name, "active")

    assert [%Maxio.Policy.Statement{actions: ["s3:ListAllMyBuckets"]}] =
             Store.principal_policies(principal)
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

    assert :ok =
             Store.tag_managed_session_policy(policy_arn, %{
               "CostCenter" => "42",
               "costcenter" => "43"
             })

    assert Enum.any?(
             Store.list_managed_session_policies(),
             &(&1.policy_arn == policy_arn and
                 &1.tags == %{"CostCenter" => "42", "costcenter" => "43"})
           )

    assert :ok = Store.untag_managed_session_policy(policy_arn, ["CostCenter"])

    assert Enum.any?(
             Store.list_managed_session_policies(),
             &(&1.policy_arn == policy_arn and &1.tags == %{"costcenter" => "43"})
           )

    assert {:error, :invalid_tag} =
             Store.tag_managed_session_policy(policy_arn, %{"aws:team" => "core"})

    assert {:error, :not_found} =
             Store.tag_managed_session_policy("arn:aws:iam:::policy/missing-tags", %{
               "team" => "core"
             })

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

  test "managed session policy versions keep one default and block unsafe deletes" do
    role_name = "store-version-role-#{System.unique_integer([:positive])}"
    role_arn = Maxio.IAM.role_arn(role_name)
    policy_arn = "arn:aws:iam:::policy/session-versioned"

    read_policy =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:GetObject","Resource":"arn:aws:s3:::versioned/*"}})

    write_policy =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:PutObject","Resource":"arn:aws:s3:::versioned/*"}})

    assert {:ok, _role} =
             Maxio.IAM.create_role(
               role_name: role_name,
               trust_policy: %{
                 "Version" => "2012-10-17",
                 "Statement" => %{
                   "Effect" => "Allow",
                   "Principal" => %{"AWS" => Maxio.IAM.root_principal_arn()},
                   "Action" => "sts:AssumeRole"
                 }
               }
             )

    assert :ok = Store.create_managed_session_policy(policy_arn, read_policy)

    assert {:ok, [%{version_id: "v1", is_default_version: true, document: v1_doc}]} =
             Store.list_managed_session_policy_versions(policy_arn)

    assert get_in(v1_doc, ["Statement", "Action"]) == "s3:GetObject"

    assert {:ok, %{version_id: "v2", is_default_version: false, document: v2_doc}} =
             Store.create_managed_session_policy_version(policy_arn, write_policy, false)

    assert get_in(v2_doc, ["Statement", "Action"]) == "s3:PutObject"

    assert {:ok, json} = Store.managed_session_policy(policy_arn)
    assert Jason.decode!(json) |> get_in(["Statement", "Action"]) == "s3:GetObject"

    assert {:error, :default_policy_version} =
             Store.delete_managed_session_policy_version(policy_arn, "v1")

    assert {:error, :policy_has_non_default_versions} =
             Store.delete_managed_session_policy(policy_arn)

    assert :ok = Store.attach_role_managed_policy(role_arn, policy_arn)
    assert ["s3:GetObject"] = role_policy_actions(role_arn)

    assert :ok = Store.set_default_managed_session_policy_version(policy_arn, "v2")
    assert :ok = Store.set_default_managed_session_policy_version(policy_arn, "v2")

    assert {:ok, json} = Store.managed_session_policy(policy_arn)
    assert Jason.decode!(json) |> get_in(["Statement", "Action"]) == "s3:PutObject"
    assert ["s3:PutObject"] = role_policy_actions(role_arn)

    assert :ok = Store.detach_role_managed_policy(role_arn, policy_arn)

    assert {:ok, %{version_id: "v2", is_default_version: true}} =
             Store.get_managed_session_policy_version(policy_arn, "v2")

    assert {:error, :default_policy_version} =
             Store.delete_managed_session_policy_version(policy_arn, "v2")

    assert :ok = Store.delete_managed_session_policy_version(policy_arn, "v1")

    assert {:ok, [%{version_id: "v2", is_default_version: true}]} =
             Store.list_managed_session_policy_versions(policy_arn)

    assert :ok = Store.delete_managed_session_policy(policy_arn)
    assert {:error, :not_found} = Store.managed_session_policy(policy_arn)
  end

  test "managed session policy version ids are monotonic and capped at five active versions" do
    policy_arn = "arn:aws:iam:::policy/session-version-limit"

    policy_for = fn action ->
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"#{action}","Resource":"arn:aws:s3:::version-limit/*"}})
    end

    assert :ok = Store.create_managed_session_policy(policy_arn, policy_for.("s3:GetObject"))

    for action <- ["s3:PutObject", "s3:DeleteObject", "s3:ListBucket", "s3:GetBucketLocation"] do
      assert {:ok, _version} =
               Store.create_managed_session_policy_version(policy_arn, policy_for.(action), false)
    end

    assert {:ok, versions} = Store.list_managed_session_policy_versions(policy_arn)
    assert Enum.map(versions, & &1.version_id) == ~w(v1 v2 v3 v4 v5)

    assert {:error, :policy_version_limit_exceeded} =
             Store.create_managed_session_policy_version(
               policy_arn,
               policy_for.("s3:GetObjectVersion"),
               false
             )

    assert :ok = Store.delete_managed_session_policy_version(policy_arn, "v3")

    assert {:ok, %{version_id: "v6"}} =
             Store.create_managed_session_policy_version(
               policy_arn,
               policy_for.("s3:GetObjectVersion"),
               false
             )

    assert {:ok, versions} = Store.list_managed_session_policy_versions(policy_arn)
    assert Enum.map(versions, & &1.version_id) == ~w(v1 v2 v4 v5 v6)
  end

  test "managed session policy tag updates validate merged 50-tag limit" do
    policy_arn = "arn:aws:iam:::policy/session-tag-quota"

    policy =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:GetObject","Resource":"arn:aws:s3:::identity/*"}})

    tags_49 = Map.new(1..49, fn index -> {"k#{index}", "v#{index}"} end)

    assert :ok = Store.create_managed_session_policy(policy_arn, policy, %{tags: tags_49})

    assert {:error, :invalid_tag} =
             Store.tag_managed_session_policy(policy_arn, %{"k50" => "v50", "k51" => "v51"})

    stored = Enum.find(Store.list_managed_session_policies(), &(&1.policy_arn == policy_arn))
    assert map_size(stored.tags) == 49
    refute Map.has_key?(stored.tags, "k50")
    refute Map.has_key?(stored.tags, "k51")

    assert :ok =
             Store.tag_managed_session_policy(policy_arn, %{"k1" => "override", "k50" => "v50"})

    stored = Enum.find(Store.list_managed_session_policies(), &(&1.policy_arn == policy_arn))
    assert map_size(stored.tags) == 50
    assert stored.tags["k1"] == "override"
    assert stored.tags["k50"] == "v50"
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

    assert %{roles: [%{role_arn: ^role_arn}], users: [], groups: []} =
             Store.list_managed_session_policy_entities(policy_arn)

    assert Store.managed_session_policy_attached?(policy_arn)
    refute Store.managed_session_policy_attached?(unattached_policy_arn)
    assert {:error, :policy_attached} = Store.delete_managed_session_policy(policy_arn)

    assert :ok = Store.detach_role_managed_policy(role_arn, policy_arn)
    assert [] = Store.principal_policies(%{arn: role_arn})
  end

  test "user and active group attached managed policies participate in user principal policies" do
    user_name = "store-managed-user-#{System.unique_integer([:positive])}"
    group_name = "store-managed-group-#{System.unique_integer([:positive])}"
    inactive_group_name = "store-managed-inactive-#{System.unique_integer([:positive])}"
    user_arn = Maxio.IAM.user_arn(user_name)
    group_arn = Maxio.IAM.group_arn(group_name)
    inactive_group_arn = Maxio.IAM.group_arn(inactive_group_name)
    user_policy_arn = "arn:aws:iam:::policy/store-user-managed-read"
    group_policy_arn = "arn:aws:iam:::policy/store-group-managed-write"
    inactive_policy_arn = "arn:aws:iam:::policy/store-inactive-group-managed-delete"

    assert {:ok, _user} = Maxio.IAM.create_user(name: user_name)
    assert {:ok, _group} = Maxio.IAM.create_group(name: group_name)
    assert {:ok, _group} = Maxio.IAM.create_group(name: inactive_group_name, status: "inactive")
    assert :ok = Maxio.IAM.add_user_to_group(user_name, group_name)
    assert :ok = Maxio.IAM.add_user_to_group(user_name, inactive_group_name)

    read_policy =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:GetObject","Resource":"arn:aws:s3:::managed/*"}})

    write_policy =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:PutObject","Resource":"arn:aws:s3:::managed/*"}})

    delete_policy =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:DeleteObject","Resource":"arn:aws:s3:::managed/*"}})

    assert :ok = Store.create_managed_session_policy(user_policy_arn, read_policy)
    assert :ok = Store.create_managed_session_policy(group_policy_arn, write_policy)
    assert :ok = Store.create_managed_session_policy(inactive_policy_arn, delete_policy)

    assert :ok = Store.attach_user_managed_policy(user_arn, user_policy_arn)
    assert :ok = Store.attach_group_managed_policy(group_arn, group_policy_arn)
    assert :ok = Store.attach_group_managed_policy(inactive_group_arn, inactive_policy_arn)

    actions =
      Store.principal_policies(%{arn: user_arn})
      |> Enum.flat_map(& &1.actions)

    assert "s3:GetObject" in actions
    assert "s3:PutObject" in actions
    refute "s3:DeleteObject" in actions

    assert [%{user_arn: ^user_arn, policy_arn: ^user_policy_arn}] =
             Store.list_attached_user_managed_policies(user_arn)

    assert [%{group_arn: ^group_arn, policy_arn: ^group_policy_arn}] =
             Store.list_attached_group_managed_policies(group_arn)

    assert %{users: [%{user_arn: ^user_arn}], groups: [], roles: []} =
             Store.list_managed_session_policy_entities(user_policy_arn)

    assert %{groups: [%{group_arn: ^group_arn}], users: [], roles: []} =
             Store.list_managed_session_policy_entities(group_policy_arn)

    assert Store.managed_session_policy_attached?(user_policy_arn)
    assert Store.managed_session_policy_attached?(group_policy_arn)
    assert Store.managed_session_policy_attached?(inactive_policy_arn)
    assert {:error, :policy_attached} = Store.delete_managed_session_policy(user_policy_arn)

    assert :ok = Store.detach_user_managed_policy(user_arn, user_policy_arn)
    assert :ok = Store.detach_group_managed_policy(group_arn, group_policy_arn)
    assert [] = Store.list_attached_user_managed_policies(user_arn)
    assert [] = Store.list_attached_group_managed_policies(group_arn)
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

    user_name = "AKIANOTIFY#{System.unique_integer([:positive, :monotonic])}"
    assert {:ok, user} = Maxio.IAM.create_user(name: user_name)
    principal_arn = user.user_arn

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

  defp role_policy_actions(role_arn) do
    %{arn: role_arn}
    |> Store.principal_policies()
    |> Enum.flat_map(& &1.actions)
  end
end
