defmodule Maxio.IAM.MinioAdminUserTest do
  use Maxio.DataCase, async: false

  alias Maxio.Auth.CredentialStore.EctoStore
  alias Maxio.Cluster.Notify
  alias Maxio.IAM
  alias Maxio.IAM.{AccessKey, AccessKeySecret, User}

  setup do
    :ok = Phoenix.PubSub.subscribe(Maxio.PubSub, Notify.topic())
    flush_iam_events()
    :ok
  end

  test "atomically creates one explicit user and encrypted same-name credential" do
    access_key = unique_access_key("CREATE")
    secret = "new-user-secret-#{System.unique_integer([:positive, :monotonic])}"

    assert {:ok, %{user: user, access_key: key} = result} =
             IAM.create_minio_user_strict(access_key, secret, "active")

    assert user.user_name == access_key
    assert user.user_arn == IAM.user_arn(access_key)
    assert user.status == "active"
    assert key.access_key_id == access_key
    assert key.principal_arn == user.user_arn
    assert key.status == "active"
    refute Map.has_key?(key, :secret_key)
    refute inspect(result) =~ secret

    assert %AccessKey{secret_key: stored_secret} =
             Repo.get_by(AccessKey, access_key_id: access_key)

    assert AccessKeySecret.encrypted?(stored_secret)
    refute stored_secret == secret
    assert {:ok, %{secret_key: ^secret}} = EctoStore.get_secret(access_key)

    assert_receive {:iam_changed, ^access_key}
    refute_receive {:iam_changed, _other}
  end

  test "an exact access-key collision rolls back the attempted user and preserves the old key" do
    owner = unique_access_key("OWNER")
    colliding_key = unique_access_key("COLLIDE")
    old_secret = "old-credential-secret"
    new_secret = "new-credential-secret-do-not-leak"

    assert {:ok, _owner} = IAM.create_user(name: owner)

    assert {:ok, _key} =
             IAM.create_access_key(
               access_key_id: colliding_key,
               secret_key: old_secret,
               user_name: owner
             )

    old_row = Repo.get_by!(AccessKey, access_key_id: colliding_key)
    flush_iam_events()

    result = IAM.create_minio_user_strict(colliding_key, new_secret, "active")

    assert {:error, :user_already_exists} = result
    assert :error = IAM.get_user(colliding_key)
    assert Repo.get_by!(AccessKey, access_key_id: colliding_key).id == old_row.id
    assert {:ok, %{secret_key: ^old_secret}} = EctoStore.get_secret(colliding_key)
    refute inspect(result) =~ new_secret
    refute_receive {:iam_changed, _target}
  end

  test "two concurrent same-name creates commit exactly one pair and one notification" do
    access_key = unique_access_key("RACE")
    parent = self()

    tasks =
      for suffix <- ["one", "two"] do
        Task.async(fn ->
          send(parent, {:ready, self()})
          receive do: (:go -> :ok)
          IAM.create_minio_user_strict(access_key, "race-secret-#{suffix}", "active")
        end)
      end

    ready_pids =
      for _task <- tasks do
        assert_receive {:ready, pid}
        pid
      end

    Enum.each(ready_pids, &send(&1, :go))

    results = Enum.map(tasks, &Task.await(&1, 30_000))

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :user_already_exists})) == 1
    assert Repo.aggregate(from(u in User, where: u.user_name == ^access_key), :count) == 1

    assert Repo.aggregate(
             from(a in AccessKey, where: a.access_key_id == ^access_key),
             :count
           ) == 1

    assert_receive {:iam_changed, ^access_key}
    refute_receive {:iam_changed, _other}
  end

  test "case-only duplicate users change no rows and emit no invalidation" do
    access_key = unique_access_key("CASE")
    assert {:ok, _created} = IAM.create_minio_user_strict(access_key, "case-secret-one", "active")
    flush_iam_events()

    before_users = Repo.aggregate(User, :count)
    before_keys = Repo.aggregate(AccessKey, :count)

    assert {:error, :user_already_exists} =
             IAM.create_minio_user_strict(
               String.downcase(access_key),
               "case-secret-two",
               "active"
             )

    assert Repo.aggregate(User, :count) == before_users
    assert Repo.aggregate(AccessKey, :count) == before_keys
    refute_receive {:iam_changed, _target}
  end

  defp flush_iam_events do
    receive do
      {:iam_changed, _target} -> flush_iam_events()
    after
      0 -> :ok
    end
  end

  defp unique_access_key(prefix) do
    suffix = System.unique_integer([:positive, :monotonic])
    String.pad_trailing("AKIA#{prefix}#{suffix}", 20, "X")
  end
end
