defmodule Maxio.Compat.AdminUserFixtureTest do
  use Maxio.DataCase, async: false

  alias Maxio.Compat.AdminUserFixture
  alias Maxio.IAM

  test "preserves a successful callback result and records cleanup" do
    owner = self()

    assert {:ok, {:primary, "fixture-user"}, cleanup} =
             AdminUserFixture.with_user(
               [
                 start_repo: fn -> :ok end,
                 name: "fixture-user",
                 create_user: fn name ->
                   send(owner, {:created, name})
                   {:ok, %{user_name: name, status: "active"}}
                 end,
                 cleanup_user: fn name ->
                   send(owner, {:cleaned, name})
                   :ok
                 end
               ],
               fn user -> {:primary, user.user_name} end
             )

    assert_received {:created, "fixture-user"}
    assert_received {:cleaned, "fixture-user"}
    assert cleanup.blockers == []
    assert [%{"id" => "admin_user_fixture_cleanup", "status" => "ok"}] = cleanup.steps
  end

  test "cleanup runs when the callback returns an mc failure unchanged" do
    owner = self()
    primary = {:blocked, [%{"id" => "admin_user_info"}], %{"reason" => "mc_failed"}}

    assert {:ok, ^primary, %{blockers: []}} =
             AdminUserFixture.with_user(
               fixture_opts(owner),
               fn _user -> primary end
             )

    assert_received {:cleaned, _name}
  end

  test "callback raises become explicit fixture failure and still clean up" do
    owner = self()

    assert {:error, blocker, %{blockers: []}} =
             AdminUserFixture.with_user(fixture_opts(owner), fn _user ->
               raise "callback exploded"
             end)

    assert blocker["reason"] == "external_smoke_fixture_callback_failed"
    assert blocker["message"] =~ "callback exploded"
    assert_received {:cleaned, _name}
  end

  test "cleanup failures are returned as step and blocker data" do
    assert {:ok, :primary, cleanup} =
             AdminUserFixture.with_user(
               [
                 start_repo: fn -> :ok end,
                 name: "cleanup-failure-user",
                 create_user: fn name -> {:ok, %{user_name: name, status: "active"}} end,
                 cleanup_user: fn _name -> {:error, :cleanup_exploded} end
               ],
               fn _user -> :primary end
             )

    assert [%{"id" => "admin_user_fixture_cleanup", "status" => "blocked"}] = cleanup.steps

    assert [%{"reason" => "external_smoke_cleanup_failed", "step" => step}] =
             cleanup.blockers

    assert step == "admin_user_fixture_cleanup"
  end

  test "default fixture creates only an active user and removes it through IAM" do
    assert {:ok, user_name, %{blockers: []}} =
             AdminUserFixture.with_user([], fn user ->
               assert user.status == "active"
               assert {:ok, []} = IAM.list_access_keys_strict(user.user_name)
               user.user_name
             end)

    assert String.starts_with?(user_name, "maxio-compat-user-")
    assert :error = IAM.get_user(user_name)
  end

  defp fixture_opts(owner) do
    [
      start_repo: fn -> :ok end,
      name: "fixture-user-#{System.unique_integer([:positive])}",
      create_user: fn name -> {:ok, %{user_name: name, status: "active"}} end,
      cleanup_user: fn name ->
        send(owner, {:cleaned, name})
        :ok
      end
    ]
  end
end
