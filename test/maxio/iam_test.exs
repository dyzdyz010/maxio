defmodule Maxio.IAMTest do
  use Maxio.DataCase, async: true
  alias Maxio.IAM
  alias Maxio.Auth.CredentialStore.EctoStore

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
        type: "iam_user"
      )

    assert key.access_key_id == "AKIATESTKEY1"
    assert key.principal_arn == "arn:aws:iam:::user/AKIATESTKEY1"

    assert {:ok, %{secret_key: "topsecret", principal: %{type: :iam_user}}} =
             EctoStore.get_secret("AKIATESTKEY1")

    assert Enum.any?(IAM.list_access_keys(), &(&1.access_key_id == "AKIATESTKEY1"))

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

  test "拒绝删除最后一个 root" do
    IAM.bootstrap_root()
    s3 = Application.fetch_env!(:maxio, :s3)
    root_ak = Keyword.fetch!(s3, :root_user)
    assert {:error, :cannot_delete_last_root} = IAM.delete_access_key(root_ak)
  end
end
