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

  test "access key lifecycle broadcasts invalidation" do
    :ok = Phoenix.PubSub.subscribe(Maxio.PubSub, Notify.topic())

    assert {:ok, %{access_key_id: "AKIANOTIFYKEY"}} =
             IAM.create_access_key(access_key_id: "AKIANOTIFYKEY", secret_key: "notify-secret")

    assert_receive {:iam_changed, "AKIANOTIFYKEY"}

    assert :ok = IAM.delete_access_key("AKIANOTIFYKEY")
    assert_receive {:iam_changed, "AKIANOTIFYKEY"}
  end
end
