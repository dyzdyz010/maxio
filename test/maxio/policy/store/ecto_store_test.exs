defmodule Maxio.Policy.Store.EctoStoreTest do
  use Maxio.DataCase, async: false

  alias Maxio.IAM
  alias Maxio.Policy.PrincipalPolicy
  alias Maxio.Policy.Store.EctoStore

  @policy ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:GetObject","Resource":"arn:aws:s3:::identity/*"}})

  test "backend user policy writes require the exact concrete user generation" do
    user_name = "policy-owner-#{System.unique_integer([:positive, :monotonic])}"
    user_arn = IAM.user_arn(user_name)

    assert {:error, :user_not_found} = EctoStore.put_principal_policy(user_arn, "read", @policy)
    refute Repo.get_by(PrincipalPolicy, principal_arn: user_arn)

    assert {:ok, user} = IAM.create_user(name: user_name)
    assert :ok = EctoStore.put_principal_policy(user.user_arn, "read", @policy)
    assert %PrincipalPolicy{} = Repo.get_by(PrincipalPolicy, principal_arn: user.user_arn)
  end
end
