defmodule Maxio.Admin.PolicyAdapterTest do
  use Maxio.DataCase, async: false

  alias Maxio.Admin.PolicyAdapter
  alias Maxio.Cluster.Notify
  alias Maxio.IAM
  alias Maxio.IAM.GroupManagedPolicyAttachment
  alias Maxio.IAM.UserManagedPolicyAttachment

  test "rejects empty, Unicode-edge-whitespace, comma, slash, backslash, and dot path segments" do
    assert {:error, :invalid_argument} = PolicyAdapter.validate_name("")
    assert {:error, :invalid_argument} = PolicyAdapter.validate_name(nil)

    for name <- [
          " policy",
          "policy ",
          "\u00A0policy",
          "policy\u3000",
          "a,b",
          ".",
          "..",
          "/ops",
          "team/",
          "team/ops",
          "team/../ops",
          "\\ops",
          "team\\",
          "team\\ops",
          "team\\..\\ops"
        ] do
      assert {:error, :invalid_resource_name} = PolicyAdapter.validate_name(name)
    end

    assert :ok = PolicyAdapter.validate_name("p-ro")
  end

  test "IAM can parse a slash name as a hidden path, but adapter rejects it before lookup" do
    nested_name = unique_name("ops")
    external_name = "team/#{nested_name}"
    nested_arn = IAM.managed_policy_arn(external_name, "/")

    assert :ok = IAM.validate_managed_policy_arn(nested_arn)
    assert {:error, :invalid_resource_name} = PolicyAdapter.validate_name(external_name)
  end

  test "create uses root path and same-name create adds a new default version" do
    name = unique_name("s1-create")
    first = policy_json("s3:GetObject")
    second = policy_json("s3:PutObject")
    arn = IAM.managed_policy_arn(name, "/")

    assert {:ok, %{policy_arn: ^arn, path: "/"}} = PolicyAdapter.create(name, first)
    assert {:ok, _updated} = PolicyAdapter.create(name, second)

    assert {:ok, %{document: document, default_version_id: default_version_id}} =
             IAM.get_managed_policy(arn)

    assert get_in(document, ["Statement", "Action"]) == "s3:PutObject"
    assert default_version_id == "v2"
    assert {:ok, versions} = IAM.list_managed_policy_versions_strict(arn)
    assert Enum.map(versions, & &1.version_id) |> Enum.sort() == ["v1", "v2"]
  end

  test "sixth same-name create reports version quota and never removes history" do
    name = unique_name("s1-quota")
    assert {:ok, _} = PolicyAdapter.create(name, policy_json("s3:GetObject"))

    for _version <- 2..5 do
      assert {:ok, _} = PolicyAdapter.create(name, policy_json("s3:GetObject"))
    end

    assert {:error, :policy_version_limit_exceeded} =
             PolicyAdapter.create(name, policy_json("s3:PutObject"))

    assert {:ok, versions} =
             name
             |> IAM.managed_policy_arn("/")
             |> IAM.list_managed_policy_versions_strict()

    assert length(versions) == 5
  end

  test "list exposes only root policies and info projects exactly the madmin v2 fields" do
    root_name = unique_name("root-visible")
    nested_name = unique_name("team-hidden")

    assert {:ok, _} = PolicyAdapter.create(root_name, policy_json("s3:GetObject"))

    assert {:ok, _} =
             IAM.create_managed_policy_strict(
               name: nested_name,
               path: "/team/",
               document: policy_json("s3:PutObject")
             )

    assert {:ok, %{policies: policies, omitted: omitted}} = PolicyAdapter.list()
    assert get_in(policies, [root_name, "Statement", "Action"]) == "s3:GetObject"
    refute Map.has_key?(policies, nested_name)
    assert [%{policy_name: ^nested_name, path: "/team/"}] = omitted

    assert {:ok, info} = PolicyAdapter.info(root_name)

    assert Map.keys(info) |> Enum.sort() ==
             ["CreateDate", "Policy", "PolicyName", "UpdateDate"]

    assert info["PolicyName"] == root_name
    assert is_map(info["Policy"])
    assert %DateTime{} = info["CreateDate"]
    assert %DateTime{} = info["UpdateDate"]
    assert {:error, :not_found} = PolicyAdapter.info("missing-policy")
  end

  test "create info and remove cannot address a hidden non-root policy through a crafted name" do
    nested_name = unique_name("hidden")
    hidden_arn = IAM.managed_policy_arn(nested_name, "/team/")
    original = policy_json("s3:GetObject")

    assert {:ok, _} =
             IAM.create_managed_policy_strict(
               name: nested_name,
               path: "/team/",
               document: original
             )

    for external_name <- ["team/#{nested_name}", "team\\#{nested_name}"] do
      assert {:error, :invalid_resource_name} =
               PolicyAdapter.create(external_name, policy_json("s3:PutObject"))

      assert {:error, :invalid_resource_name} = PolicyAdapter.info(external_name)
      assert {:error, :invalid_resource_name} = PolicyAdapter.remove(external_name)
    end

    assert {:ok, %{policy_arn: ^hidden_arn, document: document}} =
             IAM.get_managed_policy(hidden_arn)

    assert get_in(document, ["Statement", "Action"]) == "s3:GetObject"
  end

  test "remove deletes an unattached single-version policy and reports a second delete as missing" do
    name = unique_name("remove-clean")
    arn = IAM.managed_policy_arn(name, "/")

    assert {:ok, _} = PolicyAdapter.create(name, policy_json("s3:GetObject"))
    assert :ok = PolicyAdapter.remove(name)
    assert :error = IAM.get_managed_policy(arn)
    assert {:error, :not_found} = PolicyAdapter.remove(name)
  end

  test "remove reports every attached entity and never detaches it" do
    name = unique_name("remove-attached")
    user_name = unique_name("attached-user")
    group_name = unique_name("attached-group")
    role_name = unique_name("attached-role")
    arn = IAM.managed_policy_arn(name, "/")

    trust_policy = %{
      "Version" => "2012-10-17",
      "Statement" => %{
        "Effect" => "Allow",
        "Principal" => %{"AWS" => IAM.root_principal_arn()},
        "Action" => "sts:AssumeRole"
      }
    }

    assert {:ok, _} = PolicyAdapter.create(name, policy_json("s3:GetObject"))
    assert {:ok, _} = IAM.create_user(name: user_name)
    assert {:ok, _} = IAM.create_group(name: group_name)
    assert {:ok, _} = IAM.create_role(role_name: role_name, trust_policy: trust_policy)
    assert :ok = IAM.attach_user_policy_strict(user_name, arn)
    assert :ok = IAM.attach_group_policy_strict(group_name, arn)
    assert :ok = IAM.attach_role_policy_strict(role_name, arn)

    assert {:error, {:policy_attached, entities}} = PolicyAdapter.remove(name)
    assert Enum.map(entities.users, & &1.user_name) == [user_name]
    assert Enum.map(entities.groups, & &1.group_name) == [group_name]
    assert Enum.map(entities.roles, & &1.role_name) == [role_name]

    assert {:ok, still_attached} = IAM.list_managed_policy_entities_strict(arn)
    assert Enum.map(still_attached.users, & &1.user_name) == [user_name]
    assert Enum.map(still_attached.groups, & &1.group_name) == [group_name]
    assert Enum.map(still_attached.roles, & &1.role_name) == [role_name]
    assert {:ok, _policy} = IAM.get_managed_policy(arn)
  end

  test "remove reports non-default version count and never deletes version history" do
    name = unique_name("remove-versioned")
    arn = IAM.managed_policy_arn(name, "/")

    assert {:ok, _} = PolicyAdapter.create(name, policy_json("s3:GetObject"))
    assert {:ok, _} = PolicyAdapter.create(name, policy_json("s3:PutObject"))

    assert {:error, {:policy_has_non_default_versions, 1}} = PolicyAdapter.remove(name)
    assert {:ok, versions} = IAM.list_managed_policy_versions_strict(arn)
    assert length(versions) == 2
    assert Enum.count(versions, &(not &1.is_default_version)) == 1
    assert {:ok, _policy} = IAM.get_managed_policy(arn)
  end

  test "association adapter returns actual sorted policy names and exact timestamp wire key" do
    user_name = unique_name("assoc-user")
    policy_a = unique_name("assoc-a")
    policy_z = unique_name("assoc-z")
    assert {:ok, _} = IAM.create_user(name: user_name)
    assert {:ok, _} = PolicyAdapter.create(policy_z, policy_json("s3:GetObject"))
    assert {:ok, _} = PolicyAdapter.create(policy_a, policy_json("s3:GetObject"))

    assert {:ok,
            %{
              wire: %{"policiesAttached" => [^policy_a, ^policy_z], "updatedAt" => updated_at},
              changed_count: 2
            }} =
             PolicyAdapter.update_associations(:attach, {:user, user_name}, [policy_z, policy_a])

    assert {:ok, _timestamp, 0} = DateTime.from_iso8601(updated_at)

    assert {:error, :policy_change_already_applied} =
             PolicyAdapter.update_associations(:attach, {:user, user_name}, [policy_a])
  end

  test "association target classification precedes policy addressability and uses canonical identity ARN" do
    user_name = unique_name("CaseUser")
    group_name = unique_name("CaseGroup")
    policy_name = unique_name("assoc-case")
    :ok = Phoenix.PubSub.subscribe(Maxio.PubSub, Notify.topic())
    assert {:ok, user} = IAM.create_user(name: user_name)
    assert {:ok, group} = IAM.create_group(name: group_name)
    assert {:ok, _} = PolicyAdapter.create(policy_name, policy_json("s3:GetObject"))

    assert {:error, :user_not_found} =
             PolicyAdapter.update_associations(:attach, {:user, "missing-user"}, ["team/bad"])

    assert {:error, :policy_change_already_applied} =
             PolicyAdapter.update_associations(:detach, {:user, user_name}, ["team/bad"])

    assert {:ok, %{changed_count: 1}} =
             PolicyAdapter.update_associations(
               :attach,
               {:user, String.downcase(user_name)},
               [policy_name]
             )

    assert %UserManagedPolicyAttachment{user_arn: canonical_arn} =
             Repo.get_by(UserManagedPolicyAttachment,
               policy_arn: IAM.managed_policy_arn(policy_name, "/")
             )

    assert canonical_arn == user.user_arn
    assert_receive {:principal_policy_changed, ^canonical_arn}

    assert {:ok, %{changed_count: 1}} =
             PolicyAdapter.update_associations(
               :attach,
               {:group, String.downcase(group_name)},
               [policy_name]
             )

    assert %GroupManagedPolicyAttachment{group_arn: canonical_group_arn} =
             Repo.get_by(GroupManagedPolicyAttachment,
               policy_arn: IAM.managed_policy_arn(policy_name, "/")
             )

    assert canonical_group_arn == group.group_arn
    assert_receive {:principal_policy_changed, ^canonical_group_arn}
  end

  test "entities adapter applies exact madmin omission, null and stable field projection" do
    user_name = unique_name("entities-user")
    policy_name = unique_name("entities-policy")
    assert {:ok, _} = IAM.create_user(name: user_name)
    assert {:ok, _} = PolicyAdapter.create(policy_name, policy_json("s3:GetObject"))

    assert {:ok, _} =
             PolicyAdapter.update_associations(:attach, {:user, user_name}, [policy_name])

    assert {:ok, %{wire: wire}} =
             PolicyAdapter.entities(%{
               users: [user_name],
               groups: [],
               policies: [policy_name],
               requested: MapSet.new([:user, :policy])
             })

    assert [%{"user" => ^user_name, "policies" => [^policy_name]}] = wire["userMappings"]

    assert [%{"policy" => ^policy_name, "users" => [^user_name], "groups" => nil}] =
             wire["policyMappings"]

    refute Map.has_key?(wire, "groupMappings")
    assert is_binary(wire["timestamp"])

    assert {:ok, %{wire: timestamp_only}} =
             PolicyAdapter.entities(%{
               users: ["missing"],
               groups: [],
               policies: [],
               requested: MapSet.new([:user])
             })

    assert Map.keys(timestamp_only) == ["timestamp"]

    for policy_filter <- ["", "team/read", "team\\read", "unknown"] do
      assert {:ok, %{wire: safe_omission}} =
               PolicyAdapter.entities(%{
                 users: [],
                 groups: [],
                 policies: [policy_filter],
                 requested: MapSet.new([:policy])
               })

      assert Map.keys(safe_omission) == ["timestamp"]
    end
  end

  defp unique_name(prefix), do: "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"

  defp policy_json(action) do
    Jason.encode!(%{
      "Version" => "2012-10-17",
      "Statement" => %{
        "Effect" => "Allow",
        "Action" => action,
        "Resource" => "arn:aws:s3:::adapter-test/*"
      }
    })
  end
end
