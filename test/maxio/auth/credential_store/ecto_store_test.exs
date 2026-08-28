defmodule Maxio.Auth.CredentialStore.EctoStoreTest do
  use Maxio.DataCase, async: false

  alias Maxio.Auth.CredentialStore.EctoStore
  alias Maxio.IAM
  alias Maxio.IAM.AccessKey

  test "put_access_key is read-only while configured-root bootstrap remains available" do
    access_key = "AKIABYPASS#{System.unique_integer([:positive, :monotonic])}"

    assert {:error, :read_only_store} =
             EctoStore.put_access_key(%{
               access_key: access_key,
               secret_key: "must-not-be-written",
               principal: %{type: :iam_user, arn: IAM.user_arn(access_key)}
             })

    refute Repo.get_by(AccessKey, access_key_id: access_key)
    assert :ok = IAM.bootstrap_root()

    root_access_key = Application.fetch_env!(:maxio, :s3) |> Keyword.fetch!(:root_user)

    assert %AccessKey{type: "root", status: "active"} =
             Repo.get_by(AccessKey, access_key_id: root_access_key)
  end
end
