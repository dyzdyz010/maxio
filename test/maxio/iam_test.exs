defmodule Maxio.IAMTest do
  use Maxio.DataCase, async: false
  alias Maxio.IAM
  alias Maxio.Auth.CredentialStore.EctoStore
  alias Maxio.Cluster.Notify

  alias Maxio.IAM.{
    AccessKey,
    AccessKeySecret,
    AccountAlias,
    AccountPasswordPolicy,
    Group,
    Role,
    User
  }

  alias Maxio.Policy.Store
  alias Maxio.STS

  test "bootstrap_root 幂等：重复调用不报错且 root 存在" do
    assert :ok = IAM.bootstrap_root()
    assert :ok = IAM.bootstrap_root()
    s3 = Application.fetch_env!(:maxio, :s3)
    ak = Keyword.fetch!(s3, :root_user)

    stored = Repo.get_by!(AccessKey, access_key_id: ak)
    refute stored.secret_key == Keyword.fetch!(s3, :root_password)
    assert AccessKeySecret.encrypted?(stored.secret_key)

    assert {:ok, %{secret_key: _, principal: %{type: :root, arn: "arn:aws:iam:::root"}}} =
             EctoStore.get_secret(ak)
  end

  test "account alias lifecycle enforces AWS single-alias semantics" do
    assert [] = IAM.list_account_aliases()

    assert {:error, :malformed} = IAM.create_account_alias("ExampleCorp")
    assert {:error, :malformed} = IAM.create_account_alias("bad--alias")
    assert {:error, :malformed} = IAM.create_account_alias("-bad")

    assert {:ok, "example-corporation"} = IAM.create_account_alias("example-corporation")
    assert ["example-corporation"] = IAM.list_account_aliases()

    assert {:error, :already_exists} = IAM.create_account_alias("example-corporation")
    assert {:error, :limit_exceeded} = IAM.create_account_alias("other-corporation")

    assert {:error, changeset} =
             %AccountAlias{}
             |> AccountAlias.changeset(%{account_alias: "third-corporation"})
             |> Repo.insert()

    assert %{singleton_key: [_error]} = errors_on(changeset)

    assert :ok = IAM.delete_account_alias("example-corporation")
    assert [] = IAM.list_account_aliases()
    assert {:error, :not_found} = IAM.delete_account_alias("example-corporation")

    assert {:error, %Postgrex.Error{} = error} =
             Ecto.Adapters.SQL.query(
               Repo,
               """
               INSERT INTO iam_account_aliases
                 (id, account_alias, singleton_key, inserted_at, updated_at)
               VALUES ($1::uuid, $2, 2, now(), now())
               """,
               [Ecto.UUID.dump!(Ecto.UUID.generate()), "bypass-alias"]
             )

    assert error.postgres.constraint == "iam_account_aliases_singleton_key_is_one"
  end

  test "account password policy lifecycle uses AWS defaults and DB singleton boundary" do
    assert {:error, :not_found} = IAM.get_account_password_policy()
    assert {:error, :not_found} = IAM.delete_account_password_policy()

    assert {:ok, default_policy} = IAM.update_account_password_policy(%{})

    assert default_policy.minimum_password_length == 6
    refute default_policy.require_symbols
    refute default_policy.require_numbers
    refute default_policy.require_uppercase_characters
    refute default_policy.require_lowercase_characters
    refute default_policy.allow_users_to_change_password
    refute default_policy.hard_expiry
    refute default_policy.expire_passwords
    assert default_policy.max_password_age == nil
    assert default_policy.password_reuse_prevention == nil

    assert {:ok, policy} =
             IAM.update_account_password_policy(%{
               minimum_password_length: 12,
               require_symbols: true,
               require_numbers: true,
               require_uppercase_characters: true,
               require_lowercase_characters: true,
               allow_users_to_change_password: true,
               hard_expiry: true,
               max_password_age: 90,
               password_reuse_prevention: 12
             })

    assert policy.minimum_password_length == 12
    assert policy.require_symbols
    assert policy.require_numbers
    assert policy.require_uppercase_characters
    assert policy.require_lowercase_characters
    assert policy.allow_users_to_change_password
    assert policy.hard_expiry
    assert policy.expire_passwords
    assert policy.max_password_age == 90
    assert policy.password_reuse_prevention == 12

    assert {:error, changeset} =
             %AccountPasswordPolicy{}
             |> AccountPasswordPolicy.changeset(%{minimum_password_length: 5})
             |> Repo.insert()

    assert %{minimum_password_length: [_error]} = errors_on(changeset)

    assert {:error, %Postgrex.Error{} = error} =
             Ecto.Adapters.SQL.query(
               Repo,
               """
               INSERT INTO iam_account_password_policies
                 (id, singleton_key, minimum_password_length,
                  require_symbols, require_numbers, require_uppercase_characters,
                  require_lowercase_characters, allow_users_to_change_password,
                  hard_expiry, inserted_at, updated_at)
               VALUES ($1::uuid, 2, 8, false, false, false, false, false, false, now(), now())
               """,
               [Ecto.UUID.dump!(Ecto.UUID.generate())]
             )

    assert error.postgres.constraint == "iam_account_password_policies_singleton_key_is_one"

    assert :ok = IAM.delete_account_password_policy()
    assert {:error, :not_found} = IAM.get_account_password_policy()
  end

  test "create/list/get/delete access key" do
    {:ok, key} =
      IAM.create_access_key(
        access_key_id: "AKIATESTKEY1",
        secret_key: "topsecret",
        type: "iam_user",
        tags: %{"team" => "platform"}
      )

    assert key.access_key_id == "AKIATESTKEY1"
    assert key.principal_arn == "arn:aws:iam:::user/AKIATESTKEY1"
    assert key.tags == %{"team" => "platform"}

    stored = Repo.get_by!(AccessKey, access_key_id: "AKIATESTKEY1")
    refute stored.secret_key == "topsecret"
    assert AccessKeySecret.encrypted?(stored.secret_key)

    assert {:error, :access_key_secret_decrypt_failed} =
             AccessKeySecret.unwrap(stored.secret_key, "AKIAOTHERKEY")

    assert {:ok,
            %{
              secret_key: "topsecret",
              principal: %{type: :iam_user, tags: %{"team" => "platform"}}
            }} =
             EctoStore.get_secret("AKIATESTKEY1")

    assert Enum.any?(
             IAM.list_access_keys(),
             &(&1.access_key_id == "AKIATESTKEY1" and &1.tags == %{"team" => "platform"})
           )

    assert :ok = IAM.delete_access_key("AKIATESTKEY1")
    assert :error = EctoStore.get_secret("AKIATESTKEY1")
  end

  test "explicit IAM user access keys fail closed when the user row is missing" do
    user_name = "stale-user-auth"

    assert {:ok, user} = IAM.create_user(user_name: user_name)

    assert {:ok, key} =
             IAM.create_access_key(
               access_key_id: "AKIASTALEUSERAUTH",
               secret_key: "stale-secret",
               user_name: user.user_name
             )

    assert {:ok, %{principal: %{arn: arn}}} = EctoStore.get_secret(key.access_key_id)
    assert arn == user.user_arn

    Repo.delete_all(from(u in User, where: u.user_arn == ^user.user_arn))

    assert :error = EctoStore.get_secret(key.access_key_id)

    assert {:error, :issuer_access_key_not_found} =
             STS.issue_session(issuer_access_key_id: key.access_key_id)
  end

  test "IAM user names are case-insensitive unique at the database boundary" do
    assert {:ok, _user} =
             %User{}
             |> User.changeset(%{
               user_name: "CaseBoundaryUser",
               user_arn: IAM.user_arn("CaseBoundaryUser")
             })
             |> Repo.insert()

    assert {:error, changeset} =
             %User{}
             |> User.changeset(%{
               user_name: "caseboundaryuser",
               user_arn: IAM.user_arn("caseboundaryuser")
             })
             |> Repo.insert()

    assert %{user_name: [_error]} = errors_on(changeset)
  end

  test "IAM group names are case-insensitive unique at the database boundary" do
    assert {:ok, _group} =
             %Group{}
             |> Group.changeset(%{
               group_name: "CaseBoundaryGroup",
               group_arn: IAM.group_arn("CaseBoundaryGroup")
             })
             |> Repo.insert()

    assert {:error, changeset} =
             %Group{}
             |> Group.changeset(%{
               group_name: "caseboundarygroup",
               group_arn: IAM.group_arn("caseboundarygroup")
             })
             |> Repo.insert()

    assert %{group_name: [_error]} = errors_on(changeset)
  end

  test "IAM role names are case-insensitive unique at the database boundary" do
    trust_policy = root_trust_policy()

    assert {:ok, _role} =
             %Role{}
             |> Role.changeset(%{
               role_name: "CaseBoundaryRole",
               role_arn: IAM.role_arn("CaseBoundaryRole"),
               trust_policy: trust_policy
             })
             |> Repo.insert()

    assert {:error, changeset} =
             %Role{}
             |> Role.changeset(%{
               role_name: "caseboundaryrole",
               role_arn: IAM.role_arn("caseboundaryrole"),
               trust_policy: trust_policy
             })
             |> Repo.insert()

    assert %{role_name: [_error]} = errors_on(changeset)
  end

  test "credential store reads legacy plaintext access-key secret rows" do
    %AccessKey{}
    |> AccessKey.changeset(%{
      access_key_id: "AKIALEGACYPLAINTEXT",
      secret_key: "legacy-secret",
      principal_arn: "arn:aws:iam:::user/AKIALEGACYPLAINTEXT",
      type: "iam_user",
      status: "active",
      tags: %{}
    })
    |> Repo.insert!()

    assert {:ok,
            %{
              secret_key: "legacy-secret",
              principal: %{access_key: "AKIALEGACYPLAINTEXT"}
            }} = EctoStore.get_secret("AKIALEGACYPLAINTEXT")
  end

  test "access-key secret envelopes honor configured key ring for rotation" do
    old_key = b64_secret("iam-old-key")
    new_key = b64_secret("iam-new-key")

    with_access_key_secret_config([current_key_id: "iam-old", secret_key: old_key], fn ->
      {:ok, old_envelope} = AccessKeySecret.wrap("old-secret", "AKIARINGOLD")
      assert access_key_envelope_key_id(old_envelope) == "iam-old"

      with_access_key_secret_config(
        [current_key_id: "iam-new", secret_key: new_key, keys: %{"iam-old" => old_key}],
        fn ->
          assert {:ok, "old-secret"} = AccessKeySecret.unwrap(old_envelope, "AKIARINGOLD")

          {:ok, new_envelope} = AccessKeySecret.wrap("new-secret", "AKIARINGNEW")
          assert access_key_envelope_key_id(new_envelope) == "iam-new"
          assert {:ok, "new-secret"} = AccessKeySecret.unwrap(new_envelope, "AKIARINGNEW")
        end
      )

      with_access_key_secret_config([current_key_id: "iam-new", secret_key: new_key], fn ->
        assert {:error, :access_key_secret_key_not_configured} =
                 AccessKeySecret.unwrap(old_envelope, "AKIARINGOLD")
      end)
    end)
  end

  test "access-key secret envelopes reject unsupported or missing algorithm metadata" do
    {:ok, envelope} = AccessKeySecret.wrap("alg-secret", "AKIAALGSECRET")

    missing_alg = rewrite_access_key_envelope(envelope, &Map.delete(&1, "alg"))
    wrong_alg = rewrite_access_key_envelope(envelope, &Map.put(&1, "alg", "AES-128-GCM"))

    assert {:error, :invalid_access_key_secret_envelope} =
             AccessKeySecret.unwrap(missing_alg, "AKIAALGSECRET")

    assert {:error, :invalid_access_key_secret_envelope} =
             AccessKeySecret.unwrap(wrong_alg, "AKIAALGSECRET")
  end

  test "access-key secret envelopes reject undecodable base64 payloads" do
    # `Base.url_decode64/2` 用**裸 `:error`**（不是 `{:error, _}`）表示解码失败，
    # 这是 `envelope_metadata/1` else 兜底子句唯一可达的入口。
    corrupt = "maxio-ak-secret-v1:" <> "not*valid*base64url"

    assert AccessKeySecret.encrypted?(corrupt)

    assert {:error, :invalid_access_key_secret_envelope} =
             AccessKeySecret.envelope_metadata(corrupt)

    assert {:error, :invalid_access_key_secret_envelope} =
             AccessKeySecret.unwrap(corrupt, "AKIAB64SECRET")
  end

  test "access-key secret key ring rejects conflicting duplicate key ids" do
    old_key = b64_secret("iam-dup-old-key")
    new_key = b64_secret("iam-dup-new-key")

    with_access_key_secret_config(
      [
        current_key_id: "iam-current",
        secret_key: new_key,
        keys: [{"iam-duplicate", old_key}, {"iam-duplicate", new_key}]
      ],
      fn ->
        assert {:error, :access_key_secret_key_conflict} =
                 AccessKeySecret.wrap("dup-secret", "AKIADUPKEY")
      end
    )
  end

  test "rejects empty long-term access-key secrets before envelope storage" do
    assert {:error, :invalid_access_key_secret} = AccessKeySecret.wrap("", "AKIAEMPTY")

    assert {:error, :invalid_access_key_secret} =
             IAM.create_access_key(access_key_id: "AKIAEMPTYSECRET", secret_key: "")

    assert {:error, :read_only_store} =
             EctoStore.put_access_key(%{access_key: "AKIAPUTEMPTY", secret_key: ""})
  end

  test "credential store fails closed for legacy or encrypted empty access-key secrets" do
    Repo.insert!(%AccessKey{
      access_key_id: "AKIALEGACYEMPTY",
      secret_key: "",
      principal_arn: "arn:aws:iam:::user/AKIALEGACYEMPTY",
      type: "iam_user",
      status: "active",
      tags: %{}
    })

    assert :error = EctoStore.get_secret("AKIALEGACYEMPTY")

    Repo.insert!(%AccessKey{
      access_key_id: "AKIAENCRYPTEDEMPTY",
      secret_key: encrypted_secret_for_test("", "AKIAENCRYPTEDEMPTY"),
      principal_arn: "arn:aws:iam:::user/AKIAENCRYPTEDEMPTY",
      type: "iam_user",
      status: "active",
      tags: %{}
    })

    assert :error = EctoStore.get_secret("AKIAENCRYPTEDEMPTY")
  end

  test "bootstrap_root rejects empty root password before storing a credential" do
    original_s3 = Application.fetch_env!(:maxio, :s3)

    try do
      Application.put_env(:maxio, :s3, Keyword.put(original_s3, :root_password, ""))

      assert_raise ArgumentError, ~r/invalid root access-key secret configuration/, fn ->
        IAM.bootstrap_root()
      end
    after
      Application.put_env(:maxio, :s3, original_s3)
    end
  end

  test "encrypted access-key secret is redacted from inspect and tamper fails closed" do
    {:ok, _key} =
      IAM.create_access_key(
        access_key_id: "AKIATAMPERSECRET",
        secret_key: "tamper-secret"
      )

    stored = Repo.get_by!(AccessKey, access_key_id: "AKIATAMPERSECRET")
    refute inspect(stored) =~ stored.secret_key
    refute inspect(stored) =~ "tamper-secret"

    stored
    |> Ecto.Changeset.change(secret_key: stored.secret_key <> "A")
    |> Repo.update!()

    assert :error = EctoStore.get_secret("AKIATAMPERSECRET")
  end

  test "inactive 密钥视同不存在" do
    {:ok, _} = IAM.create_access_key(access_key_id: "AKIAINACTIVE", secret_key: "s")

    Repo.update_all(from(a in Maxio.IAM.AccessKey, where: a.access_key_id == "AKIAINACTIVE"),
      set: [status: "inactive"]
    )

    assert :error = EctoStore.get_secret("AKIAINACTIVE")
  end

  test "public IAM creation preserves credential tags for Ecto reads" do
    assert {:ok, _key} =
             IAM.create_access_key(
               access_key_id: "AKIAPRINCIPALTAGS",
               secret_key: "tagsecret",
               tags: %{"team" => "platform"}
             )

    stored = Repo.get_by!(AccessKey, access_key_id: "AKIAPRINCIPALTAGS")
    refute stored.secret_key == "tagsecret"
    assert AccessKeySecret.encrypted?(stored.secret_key)

    assert {:ok,
            %{
              secret_key: "tagsecret",
              principal: %{
                access_key: "AKIAPRINCIPALTAGS",
                arn: "arn:aws:iam:::user/AKIAPRINCIPALTAGS",
                tags: %{"team" => "platform"}
              }
            }} = EctoStore.get_secret("AKIAPRINCIPALTAGS")
  end

  test "拒绝删除最后一个 root" do
    IAM.bootstrap_root()
    s3 = Application.fetch_env!(:maxio, :s3)
    root_ak = Keyword.fetch!(s3, :root_user)
    assert {:error, :cannot_delete_last_root} = IAM.delete_access_key(root_ak)
  end

  test "strict access key facade enforces user scope quota status and root safety" do
    IAM.bootstrap_root()
    user_name = unique_name("strict-key-user")
    other_user_name = unique_name("strict-key-other")
    assert {:ok, user} = IAM.create_user(user_name: user_name)
    assert {:ok, _other_user} = IAM.create_user(user_name: other_user_name)

    assert {:ok, first} = IAM.create_access_key_strict(user_name)
    assert first.user_name == user_name
    assert first.principal_arn == user.user_arn
    assert is_binary(first.secret_key)

    assert {:ok, second} = IAM.create_access_key_strict(user_name)
    assert second.access_key_id != first.access_key_id
    assert {:error, :access_key_limit_exceeded} = IAM.create_access_key_strict(user_name)

    assert {:ok, keys} = IAM.list_access_keys_strict(user_name)

    assert MapSet.new(Enum.map(keys, & &1.access_key_id)) ==
             MapSet.new([first.access_key_id, second.access_key_id])

    refute Enum.any?(keys, &Map.has_key?(&1, :secret_key))

    assert {:error, :not_found} =
             IAM.update_access_key_strict(first.access_key_id, "inactive", other_user_name)

    assert {:ok, inactive} =
             IAM.update_access_key_strict(first.access_key_id, "inactive", user_name)

    assert inactive.status == "inactive"
    assert :error = EctoStore.get_secret(first.access_key_id)

    assert {:ok, active} = IAM.update_access_key_strict(first.access_key_id, "active", user_name)
    assert active.status == "active"

    assert {:error, :not_found} =
             IAM.delete_access_key_strict(first.access_key_id, other_user_name)

    assert {:ok, deleted} = IAM.delete_access_key_strict(first.access_key_id, user_name)
    assert deleted.access_key_id == first.access_key_id
    assert {:ok, [remaining]} = IAM.list_access_keys_strict(user_name)
    assert remaining.access_key_id == second.access_key_id

    s3 = Application.fetch_env!(:maxio, :s3)
    root_ak = Keyword.fetch!(s3, :root_user)

    assert {:error, :cannot_deactivate_last_root} =
             IAM.update_access_key_strict(root_ak, "inactive")

    assert {:ok, second_root} = IAM.create_access_key_strict()

    assert {:ok, %{status: "inactive"}} =
             IAM.update_access_key_strict(second_root.access_key_id, "inactive")

    assert {:error, :cannot_delete_last_root} = IAM.delete_access_key_strict(root_ak)

    assert {:ok, %{access_key_id: access_key_id}} =
             IAM.delete_access_key_strict(second_root.access_key_id)

    assert access_key_id == second_root.access_key_id
  end

  test "access key last-used facade reports unused keys and recorded SigV4 scope" do
    user_name = unique_name("last-used-user")
    assert {:ok, _user} = IAM.create_user(user_name: user_name)
    assert {:ok, key} = IAM.create_access_key_strict(user_name)

    assert {:ok, unused} = IAM.get_access_key_last_used_strict(key.access_key_id)
    assert unused.user_name == user_name
    assert unused.service_name == "N/A"
    assert unused.region == "N/A"
    assert unused.last_used_at == nil

    used_at = ~U[2026-07-02 06:00:00.123456Z]
    assert :ok = IAM.record_access_key_last_used(key.access_key_id, "s3", "us-east-1", used_at)

    assert {:ok, used} = IAM.get_access_key_last_used_strict(key.access_key_id)
    assert used.user_name == user_name
    assert used.service_name == "s3"
    assert used.region == "us-east-1"
    assert used.last_used_at == used_at

    missing_access_key_id = "AKIAMISSINGLASTUSED#{System.unique_integer([:positive])}"
    assert {:error, :not_found} = IAM.get_access_key_last_used_strict(missing_access_key_id)
    assert {:error, :malformed} = IAM.record_access_key_last_used("", "s3", "us-east-1", used_at)
  end

  test "principal identity policy lifecycle" do
    user_name = unique_name("policy-user")
    assert {:ok, user} = IAM.create_user(name: user_name)
    principal_arn = user.user_arn

    policy =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:ListBucket","Resource":"arn:aws:s3:::bucket"}})

    assert :ok = IAM.put_principal_policy(principal_arn, "list-bucket", policy)

    assert [%{principal_arn: ^principal_arn, policy_name: "list-bucket"}] =
             IAM.list_principal_policies(principal_arn)

    assert :ok = IAM.delete_principal_policy(principal_arn, "list-bucket")
    assert [] = IAM.list_principal_policies(principal_arn)
  end

  test "IAM user/group lifecycle and access key binding" do
    user_name = unique_name("alice")
    group_name = unique_name("readers")

    assert {:ok,
            %{
              user_name: ^user_name,
              user_arn: user_arn,
              status: "active",
              tags: %{"team" => "platform"}
            }} = IAM.create_user(name: user_name, tags: %{"team" => "platform"})

    assert user_arn == IAM.user_arn(user_name)
    assert {:ok, %{user_arn: ^user_arn}} = IAM.get_user(user_name)

    assert {:ok,
            %{
              group_name: ^group_name,
              group_arn: group_arn,
              status: "active"
            }} = IAM.create_group(name: group_name)

    assert group_arn == IAM.group_arn(group_name)
    assert {:ok, %{group_arn: ^group_arn}} = IAM.get_group(group_name)

    access_key_id = "AKIAUSERGROUP#{System.unique_integer([:positive])}"

    assert {:ok, %{access_key_id: ^access_key_id, principal_arn: ^user_arn, status: "active"}} =
             IAM.create_access_key(
               access_key_id: access_key_id,
               secret_key: "user-group-secret",
               user_name: user_name
             )

    assert {:ok, %{principal: %{arn: ^user_arn, type: :iam_user}}} =
             EctoStore.get_secret(access_key_id)

    assert :ok = IAM.add_user_to_group(user_name, group_name)
    assert :ok = IAM.add_user_to_group(user_arn, group_arn)

    assert [%{user_arn: ^user_arn}] = IAM.list_users_in_group(group_name)
    assert [%{group_arn: ^group_arn}] = IAM.list_groups_for_user(user_name)

    assert :ok = IAM.remove_user_from_group(user_name, group_name)
    assert [] = IAM.list_users_in_group(group_name)
    assert [] = IAM.list_groups_for_user(user_name)

    # `get_user/1` 与 `get_group/1` 用裸 `:error` 表示"不存在"，`add_user_to_group/2`
    # 必须把它归一成结构化的 `{:error, :not_found}`，而不是静默成功建出悬空成员关系。
    assert {:error, :not_found} = IAM.add_user_to_group(unique_name("ghost-user"), group_name)
    assert {:error, :not_found} = IAM.add_user_to_group(user_name, unique_name("ghost-group"))
    assert [] = IAM.list_users_in_group(group_name)
    assert [] = IAM.list_groups_for_user(user_name)
  end

  test "IAM user and group rename preserves ARN-keyed references" do
    old_user = unique_name("rename-user")
    new_user = unique_name("renamed-user")
    duplicate_user = unique_name("rename-user-dupe")
    old_group = unique_name("rename-group")
    new_group = unique_name("renamed-group")
    duplicate_group = unique_name("rename-group-dupe")
    policy_name = unique_name("rename-policy")
    policy_arn = IAM.managed_policy_arn(policy_name, "/managed/session/")

    document =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:GetObject","Resource":"arn:aws:s3:::bucket/*"}})

    assert {:ok, %{user_arn: old_user_arn}} = IAM.create_user(name: old_user)
    assert {:ok, _duplicate_user} = IAM.create_user(name: duplicate_user)
    assert {:ok, %{group_arn: old_group_arn}} = IAM.create_group(name: old_group)
    assert {:ok, _duplicate_group} = IAM.create_group(name: duplicate_group)

    assert {:ok, _policy} =
             IAM.create_managed_policy(
               name: policy_name,
               path: "/managed/session/",
               document: document
             )

    assert :ok = IAM.add_user_to_group(old_user, old_group)
    assert :ok = IAM.put_principal_policy(old_user_arn, "user-inline", document)
    assert :ok = IAM.put_group_policy(old_group, "group-inline", document)
    assert :ok = IAM.attach_user_policy(old_user, policy_arn)
    assert :ok = IAM.attach_group_policy(old_group, policy_arn)

    access_key_id = "AKIARENAME#{System.unique_integer([:positive])}"

    assert {:ok, %{access_key_id: ^access_key_id}} =
             IAM.create_access_key(
               access_key_id: access_key_id,
               secret_key: "rename-secret",
               user_name: old_user
             )

    assert {:error, :user_already_exists} =
             IAM.update_user_name_strict(old_user, String.upcase(duplicate_user))

    assert {:error, :group_already_exists} =
             IAM.update_group_name_strict(old_group, String.upcase(duplicate_group))

    assert {:ok, %{user_name: ^new_user, user_arn: new_user_arn}} =
             IAM.update_user_name_strict(old_user, new_user)

    assert {:ok, %{group_name: ^new_group, group_arn: new_group_arn}} =
             IAM.update_group_name_strict(old_group, new_group)

    assert :error = IAM.get_user(old_user)
    assert :error = IAM.get_group(old_group)
    assert {:ok, %{user_arn: ^new_user_arn}} = IAM.get_user(new_user)
    assert {:ok, %{group_arn: ^new_group_arn}} = IAM.get_group(new_group)

    assert {:ok, %{principal: %{arn: ^new_user_arn, type: :iam_user}}} =
             EctoStore.get_secret(access_key_id)

    assert [] = IAM.list_principal_policies(old_user_arn)
    assert [] = IAM.list_principal_policies(old_group_arn)

    assert [%{principal_arn: ^new_user_arn, policy_name: "user-inline"}] =
             IAM.list_principal_policies(new_user_arn)

    assert [%{principal_arn: ^new_group_arn, policy_name: "group-inline"}] =
             IAM.list_principal_policies(new_group_arn)

    assert [%{user_arn: ^new_user_arn}] = IAM.list_users_in_group(new_group)
    assert [%{group_arn: ^new_group_arn}] = IAM.list_groups_for_user(new_user)
    assert [] = IAM.list_users_in_group(old_group)
    assert [] = IAM.list_groups_for_user(old_user)

    assert {:ok, [%{policy_arn: ^policy_arn, user_arn: ^new_user_arn}]} =
             IAM.list_attached_user_policies_strict(new_user)

    assert {:ok, [%{policy_arn: ^policy_arn, group_arn: ^new_group_arn}]} =
             IAM.list_attached_group_policies_strict(new_group)
  end

  test "IAM user and group delete clean policies, memberships, and bound access keys" do
    user_name = unique_name("delete-user")
    group_name = unique_name("delete-group")

    policy =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:GetObject","Resource":"arn:aws:s3:::bucket/*"}})

    {:ok, user} = IAM.create_user(name: user_name)
    {:ok, group} = IAM.create_group(name: group_name)
    :ok = IAM.add_user_to_group(user_name, group_name)
    :ok = IAM.put_principal_policy(user.user_arn, "direct", policy)
    :ok = IAM.put_group_policy(group_name, "group-read", policy)

    access_key_id = "AKIADELETEUSER#{System.unique_integer([:positive])}"

    assert {:ok, %{access_key_id: ^access_key_id}} =
             IAM.create_access_key(
               access_key_id: access_key_id,
               secret_key: "delete-user-secret",
               user_name: user_name
             )

    assert :ok = IAM.delete_user(user_name)
    assert :error = IAM.get_user(user_name)
    assert :error = EctoStore.get_secret(access_key_id)
    assert [] = IAM.list_principal_policies(user.user_arn)
    assert [] = IAM.list_users_in_group(group_name)

    assert :ok = IAM.delete_group(group_name)
    assert :error = IAM.get_group(group_name)
    assert [] = IAM.list_principal_policies(group.group_arn)
  end

  test "delete_user cleanup helper removes IAM SSH public keys" do
    user_name = unique_name("delete-user-ssh")

    assert {:ok, _user} = IAM.create_user(name: user_name)

    assert {:ok, %{ssh_public_key_id: ssh_public_key_id}} =
             IAM.upload_ssh_public_key(
               user_name: user_name,
               ssh_public_key_body: ssh_public_key_body(1, "cleanup")
             )

    assert {:ok, [_key]} = IAM.list_ssh_public_keys_strict(user_name)
    assert :ok = IAM.delete_user(user_name)
    assert {:error, :not_found} = IAM.get_ssh_public_key_strict(user_name, ssh_public_key_id)
  end

  test "inactive explicit user fails closed for access key lookup" do
    user_name = unique_name("inactive")
    {:ok, user} = IAM.create_user(name: user_name, status: "inactive")

    assert {:error, :user_inactive} =
             IAM.create_access_key(
               access_key_id: "AKIAINACTIVEUSERA",
               secret_key: "inactive-user-secret",
               user_name: user_name
             )

    assert {:error, :user_inactive} =
             IAM.create_access_key(
               access_key_id: "AKIAINACTIVEUSERB",
               secret_key: "inactive-user-secret",
               principal_arn: user.user_arn
             )
  end

  test "IAM group ARN cannot be used as an access key login principal" do
    group_name = unique_name("login-group")
    {:ok, group} = IAM.create_group(name: group_name)

    policy =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:GetObject","Resource":"arn:aws:s3:::bucket/*"}})

    assert :ok = IAM.put_group_policy(group_name, "read", policy)

    assert {:error, :invalid_principal_arn} =
             IAM.create_access_key(
               access_key_id: "AKIAGROUPLOGINA",
               secret_key: "group-login-secret",
               principal_arn: group.group_arn
             )

    assert {:error, :read_only_store} =
             EctoStore.put_access_key(%{
               access_key: "AKIAGROUPLOGINB",
               secret_key: "group-login-secret",
               principal: %{type: :iam_user, access_key: "AKIAGROUPLOGINB", arn: group.group_arn}
             })

    assert [] = Store.principal_policies(%{type: :iam_user, arn: group.group_arn})
  end

  test "IAM user and group ARNs must match their principal type and name" do
    user_name = unique_name("arn-user")
    group_name = unique_name("arn-group")
    victim_name = unique_name("victim")
    {:ok, victim} = IAM.create_user(name: victim_name)

    assert {:error, user_changeset} =
             IAM.create_user(name: user_name, user_arn: IAM.group_arn(group_name))

    refute user_changeset.valid?

    assert {:error, group_changeset} =
             IAM.create_group(name: group_name, group_arn: victim.user_arn)

    refute group_changeset.valid?

    assert {:error, mismatched_group_changeset} =
             IAM.create_group(name: group_name, group_arn: IAM.group_arn("#{group_name}-other"))

    refute mismatched_group_changeset.valid?
    assert :error = IAM.get_group(group_name)
    assert [] = IAM.list_principal_policies(victim.user_arn)
  end

  test "managed policy management lifecycle validates identity policy documents" do
    policy_name = "session-read-#{System.unique_integer([:positive])}"
    policy_arn = IAM.managed_policy_arn(policy_name, "/managed/session/")

    read_policy =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:GetObject","Resource":"arn:aws:s3:::bucket/*"}})

    write_policy =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:PutObject","Resource":"arn:aws:s3:::bucket/*"}})

    assert {:ok,
            %{
              policy_arn: ^policy_arn,
              policy_name: ^policy_name,
              path: "/managed/session/",
              document: read_doc
            }} =
             IAM.create_managed_policy(
               name: policy_name,
               path: "/managed/session/",
               policy: read_policy
             )

    assert get_in(read_doc, ["Statement", "Action"]) == "s3:GetObject"

    assert {:ok, %{policy_name: ^policy_name, path: "/managed/session/", document: fetched_doc}} =
             IAM.get_managed_policy(policy_arn)

    assert fetched_doc == read_doc

    assert Enum.any?(
             IAM.list_managed_policies(path_prefix: "/managed/"),
             &(&1.policy_arn == policy_arn and &1.path == "/managed/session/")
           )

    assert [] = IAM.list_managed_policies(path_prefix: "/other/")

    assert {:error, :already_exists} =
             IAM.create_managed_policy(
               name: policy_name,
               path: "/managed/session/",
               policy: write_policy
             )

    assert {:ok, %{document: still_read_doc}} = IAM.get_managed_policy(policy_arn)
    assert get_in(still_read_doc, ["Statement", "Action"]) == "s3:GetObject"

    assert {:error, :already_exists} =
             IAM.create_managed_policy(
               name: String.upcase(policy_name),
               path: "/",
               policy: write_policy
             )

    malformed =
      ~s({"Statement":{"Effect":"Allow","Principal":"*","Action":"s3:GetObject","Resource":"*"}})

    assert {:error, :malformed} =
             IAM.create_managed_policy(name: "bad", policy: malformed)

    assert {:error, :malformed} =
             IAM.create_managed_policy(name: "bad/path", policy: read_policy)

    assert {:error, :malformed} =
             IAM.create_managed_policy(
               name: "bad-path",
               path: "missing-slashes",
               policy: read_policy
             )

    assert {:error, :malformed} =
             IAM.create_managed_policy(
               name: "bad-path",
               path: "/double//slash/",
               policy: read_policy
             )

    assert :ok = IAM.delete_managed_policy(policy_arn)
    assert :error = IAM.get_managed_policy(policy_arn)
    assert :ok = IAM.delete_managed_policy(policy_arn)
  end

  test "managed policy version strict lifecycle updates default document" do
    policy_name = "versioned-policy-#{System.unique_integer([:positive])}"
    policy_arn = IAM.managed_policy_arn(policy_name, "/managed/versions/")

    read_policy =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:GetObject","Resource":"arn:aws:s3:::versioned/*"}})

    write_policy =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:PutObject","Resource":"arn:aws:s3:::versioned/*"}})

    assert {:ok, %{policy_arn: ^policy_arn, default_version_id: "v1"}} =
             IAM.create_managed_policy_strict(
               name: policy_name,
               path: "/managed/versions/",
               policy: read_policy
             )

    assert {:ok, %{version_id: "v2", is_default_version: false, document: v2_doc}} =
             IAM.create_managed_policy_version_strict(policy_arn, write_policy, false)

    assert get_in(v2_doc, ["Statement", "Action"]) == "s3:PutObject"

    assert {:ok, versions} = IAM.list_managed_policy_versions_strict(policy_arn)

    assert Enum.map(versions, &{&1.version_id, &1.is_default_version}) == [
             {"v1", true},
             {"v2", false}
           ]

    assert {:ok, %{version_id: "v2", is_default_version: false}} =
             IAM.get_managed_policy_version_strict(policy_arn, "v2")

    assert {:error, :default_policy_version} =
             IAM.delete_managed_policy_version_strict(policy_arn, "v1")

    assert {:error, :policy_has_non_default_versions} = IAM.delete_managed_policy(policy_arn)

    assert :ok = IAM.set_default_managed_policy_version_strict(policy_arn, "v2")

    assert {:ok, %{default_version_id: "v2", document: default_doc}} =
             IAM.get_managed_policy(policy_arn)

    assert get_in(default_doc, ["Statement", "Action"]) == "s3:PutObject"

    assert :ok = IAM.delete_managed_policy_version_strict(policy_arn, "v1")

    assert {:ok, [%{version_id: "v2", is_default_version: true}]} =
             IAM.list_managed_policy_versions_strict(policy_arn)

    assert :ok = IAM.delete_managed_policy(policy_arn)
    assert :error = IAM.get_managed_policy(policy_arn)

    assert {:error, :malformed_policy_document} =
             IAM.create_managed_policy_version_strict(
               policy_arn,
               ~s({"Statement":{"Effect":"Allow","Principal":"*","Action":"s3:GetObject","Resource":"*"}}),
               false
             )

    assert {:error, :malformed} =
             IAM.create_managed_policy_version_strict("not-an-arn", read_policy, false)

    assert {:error, :malformed} =
             IAM.create_managed_policy_version_strict(policy_arn, read_policy, "false")
  end

  test "managed policy upsert helper honors explicit path and validates shorthand names" do
    policy_name = "upsert-read-#{System.unique_integer([:positive])}"
    policy_arn = IAM.managed_policy_arn(policy_name, "/fixtures/")

    policy =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:GetObject","Resource":"arn:aws:s3:::bucket/*"}})

    assert :ok = IAM.put_managed_policy(name: policy_name, path: "/fixtures/", policy: policy)

    assert {:ok, %{policy_arn: ^policy_arn, policy_name: ^policy_name, path: "/fixtures/"}} =
             IAM.get_managed_policy(policy_arn)

    assert {:error, :malformed} = IAM.put_managed_policy(name: "bad/path", policy: policy)
  end

  test "managed policy rejects non-local policy ARN" do
    policy =
      ~s({"Statement":{"Effect":"Allow","Action":"s3:GetObject","Resource":"*"}})

    assert {:error, :malformed} =
             IAM.put_managed_policy(
               policy_arn: "arn:aws:iam::123456789012:policy/cross-account",
               policy: policy
             )
  end

  test "role managed policy attachment lifecycle protects attached policy deletion" do
    role_name = "attach-role-#{System.unique_integer([:positive])}"
    role_arn = IAM.role_arn(role_name)
    policy_name = "attach-read-#{System.unique_integer([:positive])}"
    policy_arn = IAM.managed_policy_arn(policy_name, "/attached/")

    trust_policy = %{
      "Version" => "2012-10-17",
      "Statement" => %{
        "Effect" => "Allow",
        "Principal" => %{"AWS" => IAM.root_principal_arn()},
        "Action" => "sts:AssumeRole"
      }
    }

    managed_policy =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:GetObject","Resource":"arn:aws:s3:::bucket/*"}})

    assert {:ok, %{role_arn: ^role_arn}} =
             IAM.create_role(role_name: role_name, trust_policy: trust_policy)

    assert {:ok, %{policy_arn: ^policy_arn}} =
             IAM.create_managed_policy(
               name: policy_name,
               path: "/attached/",
               policy: managed_policy
             )

    assert :ok = IAM.attach_role_policy(role_arn, policy_arn)
    assert :ok = IAM.attach_role_policy(role_arn, policy_arn)

    assert [
             %{
               role_arn: ^role_arn,
               policy_arn: ^policy_arn,
               policy_name: ^policy_name,
               path: "/attached/"
             }
           ] = IAM.list_attached_role_policies(role_arn, path_prefix: "/attached/")

    assert {:ok,
            [
              %{
                role_arn: ^role_arn,
                policy_arn: ^policy_arn,
                policy_name: ^policy_name,
                path: "/attached/"
              }
            ]} = IAM.list_attached_role_policies_strict(role_name, path_prefix: "/attached/")

    assert {:ok, %{roles: [%{role_arn: ^role_arn}], users: [], groups: []}} =
             IAM.list_managed_policy_entities_strict(policy_arn)

    assert {:error, :policy_attached} = IAM.delete_managed_policy(policy_arn)

    assert :ok = IAM.detach_role_policy_strict(role_name, policy_arn)
    assert [] = IAM.list_attached_role_policies(role_arn)
    assert :ok = IAM.attach_role_policy_strict(role_name, policy_arn)
    assert [_policy] = IAM.list_attached_role_policies(role_arn)
    assert :ok = IAM.detach_role_policy(role_arn, policy_arn)
    assert [] = IAM.list_attached_role_policies(role_arn)

    assert :ok = IAM.delete_managed_policy(policy_arn)
  end

  test "role managed policy attachment enforces AWS managed policy attachment quota" do
    role_name = "quota-role-#{System.unique_integer([:positive])}"
    role_arn = IAM.role_arn(role_name)

    trust_policy = %{
      "Version" => "2012-10-17",
      "Statement" => %{
        "Effect" => "Allow",
        "Principal" => %{"AWS" => IAM.root_principal_arn()},
        "Action" => "sts:AssumeRole"
      }
    }

    managed_policy =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:GetObject","Resource":"arn:aws:s3:::quota/*"}})

    assert {:ok, %{role_arn: ^role_arn}} =
             IAM.create_role(role_name: role_name, trust_policy: trust_policy)

    policies =
      for index <- 1..11 do
        policy_name = "quota-role-policy-#{index}-#{System.unique_integer([:positive])}"

        assert {:ok, policy} =
                 IAM.create_managed_policy(
                   name: policy_name,
                   path: "/quota/role/",
                   policy: managed_policy
                 )

        policy
      end

    policies
    |> Enum.take(10)
    |> Enum.each(fn policy ->
      assert :ok = IAM.attach_role_policy(role_arn, policy.policy_arn)
    end)

    assert :ok = IAM.attach_role_policy(role_arn, hd(policies).policy_arn)

    assert {:error, :managed_policy_attachment_limit_exceeded} =
             IAM.attach_role_policy(role_arn, List.last(policies).policy_arn)
  end

  test "user and group managed policy attachment lifecycle protects attached policy deletion" do
    user_name = unique_name("attach-user")
    group_name = unique_name("attach-group")
    user_policy_name = unique_name("attach-user-read")
    group_policy_name = unique_name("attach-group-write")
    user_policy_arn = IAM.managed_policy_arn(user_policy_name, "/attached/users/")
    group_policy_arn = IAM.managed_policy_arn(group_policy_name, "/attached/groups/")

    managed_policy =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:GetObject","Resource":"arn:aws:s3:::bucket/*"}})

    assert {:ok, user} = IAM.create_user(name: user_name)
    assert {:ok, group} = IAM.create_group(name: group_name)

    assert {:ok, %{policy_arn: ^user_policy_arn}} =
             IAM.create_managed_policy(
               name: user_policy_name,
               path: "/attached/users/",
               policy: managed_policy
             )

    assert {:ok, %{policy_arn: ^group_policy_arn}} =
             IAM.create_managed_policy(
               name: group_policy_name,
               path: "/attached/groups/",
               policy: managed_policy
             )

    assert :ok = IAM.attach_user_policy(user_name, user_policy_arn)
    assert :ok = IAM.attach_user_policy(user.user_arn, user_policy_arn)
    assert :ok = IAM.attach_group_policy(group_name, group_policy_arn)
    assert :ok = IAM.attach_group_policy(group.group_arn, group_policy_arn)

    assert [
             %{
               user_arn: user_arn,
               policy_arn: ^user_policy_arn,
               policy_name: ^user_policy_name,
               path: "/attached/users/"
             }
           ] = IAM.list_attached_user_policies(user_name, path_prefix: "/attached/users/")

    assert user_arn == user.user_arn

    assert [
             %{
               group_arn: group_arn,
               policy_arn: ^group_policy_arn,
               policy_name: ^group_policy_name,
               path: "/attached/groups/"
             }
           ] = IAM.list_attached_group_policies(group_name, path_prefix: "/attached/groups/")

    assert group_arn == group.group_arn

    assert {:ok, %{tags: %{"CostCenter" => "42", "costcenter" => "43"}}} =
             IAM.tag_managed_policy_strict(user_policy_arn, %{
               "CostCenter" => "42",
               "costcenter" => "43"
             })

    assert {:ok, %{tags: %{"costcenter" => "43"}}} =
             IAM.untag_managed_policy_strict(user_policy_arn, ["CostCenter"])

    assert {:ok, %{tags: %{"costcenter" => "43"}}} =
             IAM.list_managed_policy_tags_strict(user_policy_arn)

    assert {:ok, %{users: [%{user_arn: ^user_arn}], groups: [], roles: []}} =
             IAM.list_managed_policy_entities_strict(user_policy_arn)

    assert {:ok, %{users: [], groups: [], roles: []}} =
             IAM.list_managed_policy_entities_strict(user_policy_arn,
               path_prefix: "/other/",
               entity_filter: "User"
             )

    assert {:ok, %{groups: [%{group_arn: ^group_arn}], users: [], roles: []}} =
             IAM.list_managed_policy_entities_strict(group_policy_arn,
               entity_filter: "Group"
             )

    assert {:error, :policy_attached} = IAM.delete_managed_policy(user_policy_arn)
    assert {:error, :policy_attached} = IAM.delete_managed_policy(group_policy_arn)

    assert {:error, :not_found} = IAM.attach_user_policy("missing-user", user_policy_arn)
    assert {:error, :not_found} = IAM.attach_group_policy("missing-group", group_policy_arn)
    assert {:error, :malformed} = IAM.attach_user_policy(user_name, "not-an-arn")
    assert {:error, :malformed} = IAM.attach_group_policy(group_name, "not-an-arn")

    assert :ok = IAM.detach_user_policy(user_name, user_policy_arn)
    assert :ok = IAM.detach_group_policy(group_name, group_policy_arn)
    assert [] = IAM.list_attached_user_policies(user_name)
    assert [] = IAM.list_attached_group_policies(group_name)

    assert :ok = IAM.delete_managed_policy(user_policy_arn)
    assert :ok = IAM.delete_managed_policy(group_policy_arn)
  end

  test "IAM role lifecycle validates trust policy" do
    role_name = "test-role-#{System.unique_integer([:positive])}"
    role_arn = IAM.role_arn(role_name)

    trust_policy = %{
      "Version" => "2012-10-17",
      "Statement" => %{
        "Effect" => "Allow",
        "Principal" => %{"AWS" => IAM.root_principal_arn()},
        "Action" => "sts:AssumeRole"
      }
    }

    assert {:ok, role} =
             IAM.create_role(
               role_name: role_name,
               trust_policy: trust_policy,
               description: "storage role",
               max_session_duration_seconds: 7200,
               tags: %{"team" => "storage"}
             )

    assert role.role_arn == role_arn
    assert role.description == "storage role"
    assert role.max_session_duration_seconds == 7200
    assert role.tags == %{"team" => "storage"}
    assert {:ok, %{role_name: ^role_name}} = IAM.get_role_by_arn(role_arn)
    assert Enum.any?(IAM.list_roles(), &(&1.role_arn == role_arn))

    assert :ok = IAM.delete_role(role_arn)
    assert :error = IAM.get_role_by_arn(role_arn)
  end

  test "strict role update lifecycle validates duration and trust policy" do
    role_name = unique_name("update-role")
    alternate_trust_policy = trust_policy_for_principal(IAM.user_arn("trusted-role-updater"))

    assert {:ok, %{max_session_duration_seconds: 7200}} =
             IAM.create_role(
               role_name: role_name,
               trust_policy: root_trust_policy(),
               max_session_duration_seconds: 7200
             )

    assert {:ok, %{max_session_duration_seconds: 7200}} = IAM.update_role_strict(role_name, nil)

    assert {:ok, %{max_session_duration_seconds: 3600}} =
             IAM.update_role_strict(role_name, 3600)

    assert {:ok, %{description: "updated role"}} =
             IAM.update_role_strict(role_name, description: "updated role")

    boundary_description = String.duplicate("d", 1000)

    assert {:ok, %{description: ^boundary_description}} =
             IAM.update_role_strict(role_name, description: boundary_description)

    assert {:ok, %{trust_policy: ^alternate_trust_policy}} =
             IAM.update_assume_role_policy_strict(
               role_name,
               Jason.encode!(alternate_trust_policy)
             )

    assert {:ok, %{trust_policy: ^alternate_trust_policy}} = IAM.get_role(role_name)

    assert {:error, :not_found} = IAM.update_role_strict("missing-update-role", 3600)

    assert {:error, :malformed_trust_policy} =
             IAM.update_assume_role_policy_strict(role_name, ~s({"Statement":))

    assert {:error, :malformed_trust_policy} =
             IAM.update_assume_role_policy_strict(
               role_name,
               ~s({"Statement":{"Effect":"Allow","Principal":"*","Action":"sts:AssumeRole","Action":"sts:TagSession"}})
             )

    assert {:error, duration_changeset} = IAM.update_role_strict(role_name, 899)
    assert %{max_session_duration_seconds: [_error]} = errors_on(duration_changeset)

    assert {:error, description_changeset} =
             IAM.update_role_strict(role_name, description: String.duplicate("d", 1001))

    assert %{description: [_error]} = errors_on(description_changeset)

    invalid_trust_policy = %{
      "Version" => "2012-10-17",
      "Statement" => %{
        "Effect" => "Allow",
        "Principal" => "*",
        "Action" => "s3:GetObject"
      }
    }

    assert {:error, trust_changeset} =
             IAM.update_assume_role_policy_strict(role_name, invalid_trust_policy)

    assert %{trust_policy: ["must be a valid role trust policy"]} = errors_on(trust_changeset)

    assert {:ok, %{description: ^boundary_description, trust_policy: ^alternate_trust_policy}} =
             IAM.get_role(role_name)
  end

  test "role inline policy strict lifecycle uses role principal ARN and quota" do
    role_name = "inline-role-#{System.unique_integer([:positive])}"
    role_arn = IAM.role_arn(role_name)

    trust_policy = %{
      "Version" => "2012-10-17",
      "Statement" => %{
        "Effect" => "Allow",
        "Principal" => %{"AWS" => IAM.root_principal_arn()},
        "Action" => "sts:AssumeRole"
      }
    }

    read_policy =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:GetObject","Resource":"arn:aws:s3:::role-inline/*"}})

    write_policy =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:PutObject","Resource":"arn:aws:s3:::role-inline/*"}})

    assert {:ok, %{role_arn: ^role_arn}} =
             IAM.create_role(role_name: role_name, trust_policy: trust_policy)

    assert :ok = IAM.put_role_policy_strict(role_name, "role-inline", read_policy)

    assert {:ok, %{role_name: ^role_name, role_arn: ^role_arn, policy_name: "role-inline"}} =
             IAM.get_role_policy_strict(role_name, "role-inline")

    assert :ok = IAM.put_role_policy_strict(role_name, "role-inline", write_policy)

    assert {:ok, [%{policy_name: "role-inline"}]} = IAM.list_role_policies_strict(role_name)

    assert [%{policy_name: "role-inline", principal_arn: ^role_arn}] =
             IAM.list_principal_policies(role_arn)

    assert {:error, :policy_limit_exceeded} =
             IAM.put_role_policy_strict(
               role_name,
               "too-large",
               ~s({"Statement":{"Effect":"Allow","Action":"s3:GetObject","Resource":"arn:aws:s3:::#{String.duplicate("r", 10_500)}/*"}})
             )

    assert :ok = IAM.delete_role_policy_strict(role_name, "role-inline")
    assert {:error, :not_found} = IAM.get_role_policy_strict(role_name, "role-inline")
    assert [] = IAM.list_principal_policies(role_arn)
  end

  test "role tag facade and strict delete protect subordinate resources" do
    inline_role_name = unique_name("strict-inline-role")
    managed_role_name = unique_name("strict-managed-role")
    session_role_name = unique_name("strict-session-role")
    managed_policy_name = unique_name("strict-role-policy")
    managed_policy_arn = IAM.managed_policy_arn(managed_policy_name, "/strict/roles/")

    policy =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:GetObject","Resource":"arn:aws:s3:::strict/*"}})

    assert {:ok, inline_role} =
             IAM.create_role(role_name: inline_role_name, trust_policy: root_trust_policy())

    assert {:ok, %{tags: %{"team" => "core"}}} =
             IAM.tag_role(inline_role_name, %{"team" => "core"})

    assert {:ok, %{tags: %{"ENV" => "prod", "team" => "core"}}} =
             IAM.tag_role(inline_role_name, %{"ENV" => "prod"})

    assert {:ok, %{tags: %{"team" => "core"}}} =
             IAM.untag_role(inline_role_name, ["env"])

    assert {:ok, %{tags: %{"team" => "core"}}} = IAM.list_role_tags_strict(inline_role_name)

    assert :ok = IAM.put_role_policy_strict(inline_role_name, "inline", policy)

    assert {:error, {:role_delete_conflict, blockers}} =
             IAM.delete_role_strict(inline_role_name)

    assert :inline_policies in blockers

    assert :ok = IAM.delete_role_policy_strict(inline_role_name, "inline")
    assert {:ok, %{role_arn: role_arn}} = IAM.delete_role_strict(inline_role_name)
    assert role_arn == inline_role.role_arn

    assert {:ok, _managed_role} =
             IAM.create_role(role_name: managed_role_name, trust_policy: root_trust_policy())

    assert {:ok, _managed_policy} =
             IAM.create_managed_policy(
               name: managed_policy_name,
               path: "/strict/roles/",
               policy: policy
             )

    assert :ok = IAM.attach_role_policy_strict(managed_role_name, managed_policy_arn)

    assert {:error, {:role_delete_conflict, blockers}} =
             IAM.delete_role_strict(managed_role_name)

    assert :managed_policy_attachments in blockers

    assert :ok = IAM.detach_role_policy_strict(managed_role_name, managed_policy_arn)
    assert {:ok, _deleted} = IAM.delete_role_strict(managed_role_name)

    assert :ok = IAM.bootstrap_root()
    root_access_key = Application.fetch_env!(:maxio, :s3) |> Keyword.fetch!(:root_user)

    assert {:ok, session_role} =
             IAM.create_role(role_name: session_role_name, trust_policy: root_trust_policy())

    caller_principal = %{
      type: :root,
      access_key: root_access_key,
      arn: IAM.root_principal_arn(),
      tags: %{}
    }

    assert {:ok, _session} =
             STS.assume_role(caller_principal, session_role,
               session_name: "strict-delete-session",
               duration_seconds: 900
             )

    assert {:error, {:role_delete_conflict, blockers}} =
             IAM.delete_role_strict(session_role_name)

    assert :active_sts_sessions in blockers
  end

  test "IAM role rejects malformed trust policy" do
    bad_policy = %{
      "Version" => "2012-10-17",
      "Statement" => %{
        "Effect" => "Allow",
        "Action" => "s3:GetObject"
      }
    }

    assert {:error, changeset} =
             IAM.create_role(role_name: "bad-trust", trust_policy: bad_policy)

    assert %{trust_policy: ["must be a valid role trust policy"]} = errors_on(changeset)
  end

  test "IAM role core lifecycle validates ARN and tag invariants" do
    assert {:error, changeset} =
             IAM.create_role(
               role_name: "bad-role-arn",
               role_arn: IAM.user_arn("bad-role-arn"),
               trust_policy: root_trust_policy()
             )

    assert %{role_arn: arn_errors} = errors_on(changeset)
    assert "has invalid format" in arn_errors
    assert "must match role name" in arn_errors

    assert {:error, changeset} =
             IAM.create_role(
               role_name: "mismatched-role-arn",
               role_arn: IAM.role_arn("other-role"),
               trust_policy: root_trust_policy()
             )

    assert %{role_arn: ["must match role name"]} = errors_on(changeset)

    assert {:error, changeset} =
             IAM.create_role(
               role_name: "reserved-role-tag",
               trust_policy: root_trust_policy(),
               tags: %{"aws:team" => "core"}
             )

    assert %{tags: ["must contain valid IAM tag keys and values"]} = errors_on(changeset)

    assert {:error, changeset} =
             IAM.create_role(
               role_name: "duplicate-role-tag",
               trust_policy: root_trust_policy(),
               tags: %{"team" => "core", "TEAM" => "ops"}
             )

    assert %{tags: ["must not contain duplicate IAM tag keys"]} = errors_on(changeset)

    guarded_role_name = unique_name("guarded-role")

    assert {:ok, role} =
             IAM.create_role(role_name: guarded_role_name, trust_policy: root_trust_policy())

    assert {:error, changeset} = IAM.tag_role(role.role_name, %{"aws:team" => "core"})
    assert %{tags: ["must contain valid IAM tag keys and values"]} = errors_on(changeset)

    assert {:error, changeset} =
             IAM.tag_role(role.role_name, %{"team" => "core", "TEAM" => "ops"})

    assert %{tags: ["must not contain duplicate IAM tag keys"]} = errors_on(changeset)

    assert {:ok, %{tags: %{}}} = IAM.list_role_tags_strict(role.role_name)
  end

  test "access key lifecycle broadcasts invalidation" do
    :ok = Phoenix.PubSub.subscribe(Maxio.PubSub, Notify.topic())

    assert {:ok, %{access_key_id: "AKIANOTIFYKEY"}} =
             IAM.create_access_key(access_key_id: "AKIANOTIFYKEY", secret_key: "notify-secret")

    assert_receive {:iam_changed, "AKIANOTIFYKEY"}

    assert :ok = IAM.delete_access_key("AKIANOTIFYKEY")
    assert_receive {:iam_changed, "AKIANOTIFYKEY"}
  end

  defp root_trust_policy do
    %{
      "Version" => "2012-10-17",
      "Statement" => %{
        "Effect" => "Allow",
        "Principal" => %{"AWS" => IAM.root_principal_arn()},
        "Action" => "sts:AssumeRole"
      }
    }
  end

  defp trust_policy_for_principal(principal_arn) do
    %{
      "Version" => "2012-10-17",
      "Statement" => %{
        "Effect" => "Allow",
        "Principal" => %{"AWS" => principal_arn},
        "Action" => "sts:AssumeRole"
      }
    }
  end

  defp unique_name(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp ssh_public_key_body(seed, comment) do
    n = :binary.decode_unsigned(<<0x80, 0::size(2040)>>) + seed
    e = 65_537
    blob = ssh_string("ssh-rsa") <> ssh_mpint(e) <> ssh_mpint(n)
    "ssh-rsa #{Base.encode64(blob)} #{comment}"
  end

  defp ssh_string(value), do: <<byte_size(value)::32, value::binary>>

  defp ssh_mpint(value) when is_integer(value) and value > 0 do
    encoded = :binary.encode_unsigned(value)

    if :binary.first(encoded) >= 128,
      do: ssh_string(<<0, encoded::binary>>),
      else: ssh_string(encoded)
  end

  defp with_access_key_secret_config(config, fun) do
    original = Application.fetch_env!(:maxio, :access_key_secret)

    try do
      Application.put_env(:maxio, :access_key_secret, config)
      fun.()
    after
      Application.put_env(:maxio, :access_key_secret, original)
    end
  end

  defp b64_secret(label), do: :crypto.hash(:sha256, label) |> Base.encode64()

  defp access_key_envelope_key_id(envelope) do
    envelope
    |> String.replace_prefix("maxio-ak-secret-v1:", "")
    |> Base.url_decode64!(padding: false)
    |> Jason.decode!()
    |> Map.fetch!("key_id")
  end

  defp rewrite_access_key_envelope(envelope, rewrite_fun) do
    rewritten =
      envelope
      |> String.replace_prefix("maxio-ak-secret-v1:", "")
      |> Base.url_decode64!(padding: false)
      |> Jason.decode!()
      |> rewrite_fun.()

    "maxio-ak-secret-v1:" <> Base.url_encode64(Jason.encode!(rewritten), padding: false)
  end

  defp encrypted_secret_for_test(secret_key, access_key_id) do
    key =
      :maxio
      |> Application.fetch_env!(:access_key_secret)
      |> Keyword.fetch!(:secret_key)
      |> Base.decode64!()

    iv = :crypto.strong_rand_bytes(12)
    aad = "maxio:iam:access-key-secret:v1:" <> access_key_id

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, secret_key, aad, true)

    envelope = %{
      "alg" => "AES-256-GCM",
      "key_id" => "local-default",
      "iv_b64" => Base.encode64(iv),
      "ciphertext_b64" => Base.encode64(ciphertext),
      "tag_b64" => Base.encode64(tag)
    }

    "maxio-ak-secret-v1:" <> Base.url_encode64(Jason.encode!(envelope), padding: false)
  end
end
