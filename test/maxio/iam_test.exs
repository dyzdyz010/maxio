defmodule Maxio.IAMTest do
  use Maxio.DataCase, async: false
  alias Maxio.IAM
  alias Maxio.Auth.CredentialStore.EctoStore
  alias Maxio.Cluster.Notify

  test "bootstrap_root 幂等：重复调用不报错且 root 存在" do
    assert :ok = IAM.bootstrap_root()
    assert :ok = IAM.bootstrap_root()
    s3 = Application.fetch_env!(:maxio, :s3)
    ak = Keyword.fetch!(s3, :root_user)

    assert {:ok, %{secret_key: _, principal: %{type: :root, arn: "arn:aws:iam:::root"}}} =
             EctoStore.get_secret(ak)
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

  test "inactive 密钥视同不存在" do
    {:ok, _} = IAM.create_access_key(access_key_id: "AKIAINACTIVE", secret_key: "s")

    Repo.update_all(from(a in Maxio.IAM.AccessKey, where: a.access_key_id == "AKIAINACTIVE"),
      set: [status: "inactive"]
    )

    assert :error = EctoStore.get_secret("AKIAINACTIVE")
  end

  test "Ecto credential store preserves tags from injected principal shape" do
    assert :ok =
             EctoStore.put_access_key(%{
               access_key: "AKIAPRINCIPALTAGS",
               secret_key: "tagsecret",
               principal: %{
                 type: :iam_user,
                 access_key: "AKIAPRINCIPALTAGS",
                 arn: "arn:aws:iam:::user/AKIAPRINCIPALTAGS",
                 tags: %{"team" => "platform"}
               }
             })

    assert {:ok,
            %{
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

  test "principal identity policy lifecycle" do
    principal_arn = "arn:aws:iam:::user/AKIAIAMPOLICY1"

    policy =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:ListBucket","Resource":"arn:aws:s3:::bucket"}})

    assert :ok = IAM.put_principal_policy(principal_arn, "list-bucket", policy)

    assert [%{principal_arn: ^principal_arn, policy_name: "list-bucket"}] =
             IAM.list_principal_policies(principal_arn)

    assert :ok = IAM.delete_principal_policy(principal_arn, "list-bucket")
    assert [] = IAM.list_principal_policies(principal_arn)
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

    assert {:error, :policy_attached} = IAM.delete_managed_policy(policy_arn)

    assert :ok = IAM.detach_role_policy(role_arn, policy_arn)
    assert [] = IAM.list_attached_role_policies(role_arn)

    assert :ok = IAM.delete_managed_policy(policy_arn)
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
               max_session_duration_seconds: 7200,
               tags: %{"team" => "storage"}
             )

    assert role.role_arn == role_arn
    assert role.max_session_duration_seconds == 7200
    assert role.tags == %{"team" => "storage"}
    assert {:ok, %{role_name: ^role_name}} = IAM.get_role_by_arn(role_arn)
    assert Enum.any?(IAM.list_roles(), &(&1.role_arn == role_arn))

    assert :ok = IAM.delete_role(role_arn)
    assert :error = IAM.get_role_by_arn(role_arn)
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

  test "access key lifecycle broadcasts invalidation" do
    :ok = Phoenix.PubSub.subscribe(Maxio.PubSub, Notify.topic())

    assert {:ok, %{access_key_id: "AKIANOTIFYKEY"}} =
             IAM.create_access_key(access_key_id: "AKIANOTIFYKEY", secret_key: "notify-secret")

    assert_receive {:iam_changed, "AKIANOTIFYKEY"}

    assert :ok = IAM.delete_access_key("AKIANOTIFYKEY")
    assert_receive {:iam_changed, "AKIANOTIFYKEY"}
  end
end
