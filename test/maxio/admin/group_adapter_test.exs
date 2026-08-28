defmodule Maxio.Admin.GroupAdapterTest do
  use Maxio.DataCase, async: false

  alias Maxio.Admin.GroupAdapter
  alias Maxio.IAM

  @document %{
    "Version" => "2012-10-17",
    "Statement" => [%{"Effect" => "Allow", "Action" => "s3:GetObject", "Resource" => "*"}]
  }

  test "list and info project the exact stable MinIO group view and safe omission evidence" do
    suffix = System.unique_integer([:positive])
    group_name = "adapter-group-#{suffix}"
    alpha = "adapter-alpha-#{suffix}"
    zeta = "adapter-zeta-#{suffix}"
    a_policy = "adapter-a-#{suffix}"
    z_policy = "adapter-z-#{suffix}"

    assert {:ok, _} = IAM.create_user(name: zeta)
    assert {:ok, _} = IAM.create_user(name: alpha)

    assert {:ok, created} =
             IAM.update_minio_group_members_strict(group_name, [zeta, alpha, zeta], false, "")

    for policy_name <- [z_policy, a_policy] do
      assert {:ok, policy} =
               IAM.create_managed_policy(name: policy_name, path: "/", document: @document)

      assert :ok = IAM.attach_group_policy(group_name, policy.policy_arn)
    end

    assert :ok = IAM.put_group_policy(group_name, "hidden-inline", Jason.encode!(@document))

    assert {:ok, %{wire: names, evidence: list_evidence}} = GroupAdapter.list()
    assert group_name in names
    assert names == Enum.sort(names)
    assert list_evidence.group_count == length(names)

    assert {:ok, %{wire: wire, evidence: evidence}} = GroupAdapter.info(String.upcase(group_name))

    assert wire == %{
             "name" => group_name,
             "status" => "enabled",
             "members" => Enum.sort([alpha, zeta]),
             "policy" => Enum.join(Enum.sort([a_policy, z_policy]), ","),
             "updatedAt" => DateTime.to_iso8601(created.updated_at)
           }

    assert evidence.snapshot == "single statement"
    assert evidence.member_order == "maxio-sorted-unique-members"
    assert evidence.inline_policy_names == ["hidden-inline"]
    assert evidence.non_root_managed_policy_names == []
    refute Jason.encode!(wire) =~ "hidden-inline"
    refute inspect(evidence) =~ Jason.encode!(@document)
  end

  test "empty visible policy stays an empty string and internal statuses map exactly" do
    suffix = System.unique_integer([:positive])
    group_name = "adapter-disabled-#{suffix}"
    assert {:ok, group} = IAM.create_group(name: group_name, status: "inactive")

    assert {:ok, %{wire: wire}} = GroupAdapter.info(group_name)

    assert wire == %{
             "name" => group_name,
             "status" => "disabled",
             "members" => [],
             "policy" => "",
             "updatedAt" => DateTime.to_iso8601(group.updated_at)
           }
  end

  test "membership update preserves raw groupStatus only as evidence and status maps wire values" do
    suffix = System.unique_integer([:positive])
    user_name = "adapter-member-#{suffix}"
    group_name = "adapter-members-#{suffix}"
    assert {:ok, _} = IAM.create_user(name: user_name)

    request = %{
      group: group_name,
      members: [user_name, user_name],
      group_status: "ignored-replication-payload",
      remove?: false
    }

    assert {:ok, result} = GroupAdapter.update_members(request)
    assert result.evidence.group_status == "ignored-replication-payload"
    assert result.evidence.group_status_ignored
    assert result.requested_member_count == 2

    assert {:ok, %{group: %{status: "inactive"}}} = GroupAdapter.status(group_name, "disabled")
    assert {:ok, %{group: %{status: "active"}}} = GroupAdapter.status(group_name, "enabled")
    assert {:error, :invalid_status_argument} = GroupAdapter.status(group_name, "paused")
    assert {:error, :invalid_argument} = GroupAdapter.status(group_name, nil)
  end

  test "name compatibility and typed failures remain in the IAM domain" do
    assert {:error, :invalid_argument} = GroupAdapter.info(nil)
    assert {:error, :invalid_argument} = GroupAdapter.info("")
    assert {:error, :group_not_found} = GroupAdapter.info("missing/group,utf8-é")

    assert {:error, :invalid_resource_name} =
             GroupAdapter.update_members(%{
               group: " surrounding-space ",
               members: [],
               group_status: "",
               remove?: false
             })

    assert {:error, :invalid_group_name} =
             GroupAdapter.update_members(%{
               group: "new,group",
               members: [],
               group_status: "",
               remove?: false
             })

    assert {:error, :invalid_argument} = GroupAdapter.update_members(%{})
  end

  test "adapter boundary references only the public IAM facade" do
    source = File.read!("lib/maxio/admin/group_adapter.ex")
    assert source =~ "alias Maxio.IAM"

    for forbidden <- ["Maxio.Repo", "Ecto.", "Policy.Store", "AdminGroupLifecycle"] do
      refute source =~ forbidden
    end
  end
end
