defmodule Maxio.DataCaseTest do
  use Maxio.DataCase, async: false

  alias Maxio.Auth.CredentialStore
  alias Maxio.Auth.CredentialStore.MemoryStore
  alias Maxio.Cluster.CacheInvalidator
  alias Maxio.IAM.{AccessKey, User}

  test "create_user_with_access_key! persists a concrete user-bound credential" do
    fixture =
      create_user_with_access_key!(
        user_name: "fixture-user",
        access_key_id: "AKIAFIXTUREUSER001",
        secret_key: "fixture-user-secret"
      )

    assert fixture.user.user_name == "fixture-user"
    assert fixture.user_arn == "arn:aws:iam:::user/fixture-user"
    assert fixture.access_key.access_key_id == "AKIAFIXTUREUSER001"
    assert fixture.access_key.principal_arn == fixture.user_arn
    assert fixture.principal_arn == fixture.user_arn
    assert fixture.secret_key == "fixture-user-secret"

    assert %User{id: user_id} = Repo.get_by(User, user_arn: fixture.user_arn)
    assert user_id == fixture.user.id

    assert %AccessKey{principal_arn: principal_arn} =
             Repo.get_by(AccessKey, access_key_id: fixture.access_key_id)

    assert principal_arn == fixture.user_arn
  end

  test "create_user_with_access_key! drains its IAM event before a MemoryStore fixture is cached" do
    suffix = System.unique_integer([:positive, :monotonic])
    access_key_id = "AKIAFIXTUREDRAIN#{suffix}"
    secret_key = "fixture-drain-secret-#{suffix}"

    _ = :sys.get_state(CacheInvalidator)

    fixture =
      create_user_with_access_key!(
        user_name: "fixture-drain-#{suffix}",
        access_key_id: access_key_id,
        secret_key: secret_key
      )

    on_exit(fn ->
      MemoryStore.invalidate({:access_key, access_key_id})
      _ = :sys.get_state(CacheInvalidator)
    end)

    assert :ok =
             MemoryStore.put_access_key(%{
               access_key: access_key_id,
               secret_key: secret_key,
               principal: %{
                 type: :iam_user,
                 access_key: access_key_id,
                 arn: fixture.user_arn
               }
             })

    _ = :sys.get_state(CacheInvalidator)

    assert {:ok, %{secret_key: ^secret_key}} = CredentialStore.get_secret(access_key_id)
  end
end
