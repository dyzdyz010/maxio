defmodule Maxio.DataCaseTest do
  use Maxio.DataCase, async: true

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
end
