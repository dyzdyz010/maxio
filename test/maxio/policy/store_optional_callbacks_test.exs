defmodule Maxio.Policy.StoreOptionalCallbacksTest do
  use ExUnit.Case, async: false

  alias Maxio.Policy.Store

  defmodule LegacyStore do
    @behaviour Maxio.Policy.Store

    @impl true
    def get_bucket_policy(_bucket), do: :none

    @impl true
    def put_bucket_policy(_bucket, _json), do: :ok

    @impl true
    def delete_bucket_policy(_bucket), do: :ok

    @impl true
    def principal_policies(_principal), do: []
  end

  test "principal policy facade handles stores without optional callbacks" do
    previous_store = Application.fetch_env!(:maxio, :policy_store)

    try do
      Application.put_env(:maxio, :policy_store, LegacyStore)

      assert {:error, :not_supported} =
               Store.put_principal_policy("arn:aws:iam:::user/legacy", "policy", "{}")

      assert {:error, :not_supported} =
               Store.get_principal_policy("arn:aws:iam:::user/legacy", "policy")

      assert :ok = Store.delete_principal_policy("arn:aws:iam:::user/legacy", "policy")
      assert [] = Store.list_principal_policies("arn:aws:iam:::user/legacy")

      assert {:error, :not_supported} =
               Store.put_managed_session_policy("arn:aws:iam:::policy/legacy", "{}")

      assert {:error, :not_supported} =
               Store.create_managed_session_policy("arn:aws:iam:::policy/legacy", "{}")

      assert {:error, :not_supported} =
               Store.managed_session_policy("arn:aws:iam:::policy/legacy")

      assert {:error, :not_supported} =
               Store.create_managed_session_policy_version(
                 "arn:aws:iam:::policy/legacy",
                 "{}",
                 false
               )

      assert {:error, :not_supported} =
               Store.get_managed_session_policy_version("arn:aws:iam:::policy/legacy", "v1")

      assert {:error, :not_found} =
               Store.get_managed_session_policy_version("arn:aws:iam:::policy/legacy", "v2")

      assert {:error, :not_supported} =
               Store.list_managed_session_policy_versions("arn:aws:iam:::policy/legacy")

      assert {:error, :not_supported} =
               Store.set_default_managed_session_policy_version(
                 "arn:aws:iam:::policy/legacy",
                 "v1"
               )

      assert {:error, :not_supported} =
               Store.delete_managed_session_policy_version(
                 "arn:aws:iam:::policy/legacy",
                 "v1"
               )

      assert :ok = Store.delete_managed_session_policy("arn:aws:iam:::policy/legacy")
      assert [] = Store.list_managed_session_policies()

      assert {:error, :not_supported} =
               Store.tag_managed_session_policy("arn:aws:iam:::policy/legacy", %{"team" => "core"})

      assert {:error, :not_supported} =
               Store.untag_managed_session_policy("arn:aws:iam:::policy/legacy", ["team"])

      assert %{users: [], groups: [], roles: []} =
               Store.list_managed_session_policy_entities("arn:aws:iam:::policy/legacy")

      assert {:error, :not_supported} =
               Store.attach_role_managed_policy(
                 "arn:aws:iam:::role/legacy",
                 "arn:aws:iam:::policy/legacy"
               )

      assert :ok =
               Store.detach_role_managed_policy(
                 "arn:aws:iam:::role/legacy",
                 "arn:aws:iam:::policy/legacy"
               )

      assert [] = Store.list_attached_role_managed_policies("arn:aws:iam:::role/legacy")

      assert {:error, :not_supported} =
               Store.attach_user_managed_policy(
                 "arn:aws:iam:::user/legacy",
                 "arn:aws:iam:::policy/legacy"
               )

      assert :ok =
               Store.detach_user_managed_policy(
                 "arn:aws:iam:::user/legacy",
                 "arn:aws:iam:::policy/legacy"
               )

      assert [] = Store.list_attached_user_managed_policies("arn:aws:iam:::user/legacy")

      assert {:error, :not_supported} =
               Store.attach_group_managed_policy(
                 "arn:aws:iam:::group/legacy",
                 "arn:aws:iam:::policy/legacy"
               )

      assert :ok =
               Store.detach_group_managed_policy(
                 "arn:aws:iam:::group/legacy",
                 "arn:aws:iam:::policy/legacy"
               )

      assert [] = Store.list_attached_group_managed_policies("arn:aws:iam:::group/legacy")

      assert {:error, :not_supported} =
               Store.update_builtin_managed_policy_associations_without_notify(
                 :user,
                 "arn:aws:iam:::user/legacy",
                 :attach,
                 ["arn:aws:iam:::policy/readwrite"]
               )

      assert {:error, :not_supported} =
               Store.query_builtin_managed_policy_entities(%{
                 users: [],
                 groups: [],
                 policy_arns: [],
                 requested: MapSet.new()
               })

      refute Store.managed_session_policy_attached?("arn:aws:iam:::policy/legacy")
    after
      Application.put_env(:maxio, :policy_store, previous_store)
    end
  end
end
