defmodule Maxio.Admin.UserAdapterTest do
  use Maxio.DataCase, async: false

  import ExUnit.CaptureLog

  alias Maxio.Admin.UserAdapter
  alias Maxio.Auth.CredentialStore.EctoStore
  alias Maxio.IAM

  test "adds only valid enabled new users without exposing the supplied secret" do
    access_key = unique_access_name("ADDUSER")
    secret = "eight+++"

    log =
      capture_log(fn ->
        assert {:ok, result} =
                 UserAdapter.add(access_key, %{
                   secret_key: secret,
                   policy: "",
                   status: "enabled"
                 })

        refute inspect(result) =~ secret
        refute Map.has_key?(result.access_key, :secret_key)
      end)

    refute log =~ secret

    for valid <- [
          "a1b",
          "a!b",
          "a#b",
          "a:b",
          "a b",
          String.duplicate("A", 20),
          String.duplicate("B", 21),
          String.duplicate("C", 64)
        ] do
      assert {:ok, _boundary_user} =
               UserAdapter.add(valid, %{
                 secret_key: "12345678",
                 policy: "",
                 status: "enabled"
               })

      assert {:ok, %{secret_key: "12345678"}} = EctoStore.get_secret(valid)
    end

    for invalid <- [
          nil,
          "",
          "aa",
          " abc",
          "abc ",
          "a\tb",
          "a\nb",
          ",ab",
          "a,b",
          "ab,",
          "=ab",
          "abc=def",
          "ab=",
          "/ab",
          "a/b",
          "ab/",
          "\\ab",
          "a\\b",
          "ab\\",
          "abé",
          String.duplicate("D", 65)
        ] do
      assert {:error, :invalid_access_key} =
               UserAdapter.add(invalid, %{secret_key: "eight+++", policy: "", status: "enabled"})
    end

    assert {:error, :invalid_secret_key} =
             UserAdapter.add(unique_access_name("NOSECRET"), %{
               secret_key: "1234567",
               policy: "",
               status: "enabled"
             })

    assert {:error, :config_bad_json} =
             UserAdapter.add(unique_access_name("DISABLED"), %{
               secret_key: "12345678",
               policy: "",
               status: "disabled"
             })

    assert {:error, :config_bad_json} =
             UserAdapter.add(unique_access_name("POLICY"), %{
               secret_key: "12345678",
               policy: "readwrite",
               status: "enabled"
             })

    duplicate_result =
      UserAdapter.add(access_key, %{
        secret_key: "replacement-secret",
        policy: "",
        status: "enabled"
      })

    assert duplicate_result == {:error, :user_already_exists}
    refute inspect(duplicate_result) =~ "replacement-secret"
  end

  test "lists every explicit user as an exact UserInfo map and omits credential internals" do
    root_key = unique_access_name("ROOTONLY")
    root_secret = "root-only-secret"

    assert {:ok, _root} =
             IAM.create_access_key(
               access_key_id: root_key,
               secret_key: root_secret,
               type: "root",
               principal_arn: "arn:aws:iam:::root"
             )

    assert {:ok, %{wire: %{}, evidence: %{user_count: 0}}} = UserAdapter.list()

    enabled = unique_access_name("LISTENABLED")
    disabled = unique_access_name("LISTDISABLED")
    no_key = unique_access_name("LISTNOKEY")
    user_secret = "list-user-secret"

    assert {:ok, %{user: enabled_user}} =
             IAM.create_minio_user_strict(enabled, user_secret, "active")

    assert {:ok, disabled_user} = IAM.create_user(name: disabled, status: "inactive")
    assert {:ok, no_key_user} = IAM.create_user(name: no_key, status: "active")

    policy_name = unique_name("direct-policy")
    policy_arn = create_managed_policy!(policy_name)
    assert :ok = IAM.attach_user_policy(enabled, policy_arn)

    group_name = unique_name("list-group")
    group_policy_name = unique_name("group-policy")
    group_policy_arn = create_managed_policy!(group_policy_name)
    assert {:ok, _group} = IAM.create_group(name: group_name)
    assert :ok = IAM.add_user_to_group(enabled, group_name)
    assert :ok = IAM.attach_group_policy(group_name, group_policy_arn)

    assert {:ok, %{wire: wire, evidence: evidence} = result} = UserAdapter.list()

    assert wire == %{
             disabled => %{
               "status" => "disabled",
               "updatedAt" => DateTime.to_iso8601(disabled_user.updated_at)
             },
             enabled => %{
               "memberOf" => [group_name],
               "policyName" => policy_name,
               "status" => "enabled",
               "updatedAt" => DateTime.to_iso8601(enabled_user.updated_at)
             },
             no_key => %{
               "status" => "enabled",
               "updatedAt" => DateTime.to_iso8601(no_key_user.updated_at)
             }
           }

    assert evidence.user_count == 3
    assert evidence.user_names == Enum.sort([disabled, enabled, no_key])
    assert evidence.credential_bearing_count == 1
    refute Map.has_key?(wire, root_key)

    encoded = Jason.encode!(wire)

    for forbidden <- [
          "secretKey",
          "userAuthInfo",
          "credential_bearing",
          root_secret,
          user_secret,
          root_key,
          policy_json(),
          "session_token"
        ] do
      refute encoded =~ forbidden
    end

    for forbidden <- [root_secret, user_secret, root_key, policy_json(), "session_token"] do
      refute inspect(result.evidence) =~ forbidden
    end
  end

  test "validates MinIO user names before IAM lookup" do
    for name <- [nil, "", String.duplicate("a", 65), "team/alice", "team\\alice", "alice!"] do
      assert {:error, :invalid_argument} = UserAdapter.validate_name(name)
    end

    for name <- [" alice", "alice ", "\u00A0alice", "alice\u3000", "ali,ce"] do
      assert {:error, :invalid_resource_name} = UserAdapter.validate_name(name)
    end

    assert :ok = UserAdapter.validate_name("Alice_01+=.@-")
  end

  test "mutation names preserve the exact S2b access-key domain" do
    for name <- [
          "a1b",
          "a b",
          "a!b",
          "a#b",
          "a:b",
          String.duplicate("A", 64)
        ] do
      assert :ok = UserAdapter.validate_mutation_name(name)
    end

    for name <- [nil, "", "aa", "abc=def", "a/b", "a\\b", "ab茅", String.duplicate("A", 65)] do
      assert {:error, :invalid_argument} = UserAdapter.validate_mutation_name(name)
    end

    for name <- [" abc", "abc ", "\u00A0abc", "abc\u3000", "a,b"] do
      assert {:error, :invalid_resource_name} = UserAdapter.validate_mutation_name(name)
    end
  end

  test "status and remove delegate exact actors to reversible and permanent IAM facades" do
    access_key = unique_access_name("MUTATE")
    actor = Application.fetch_env!(:maxio, :s3) |> Keyword.fetch!(:root_user)

    assert {:ok, %{user: user}} =
             IAM.create_minio_user_strict(access_key, "mutation-secret", "active")

    assert {:ok, %{user: %{status: "inactive"}}} =
             UserAdapter.status(user.user_name, "disabled", actor)

    assert {:ok, %{user: %{status: "active"}}} =
             UserAdapter.status(user.user_name, "enabled", actor)

    assert {:error, :invalid_status_argument} =
             UserAdapter.status(user.user_name, "paused", actor)

    assert {:ok, %{user: %{user_name: user_name}}} =
             UserAdapter.remove(user.user_name, actor)

    assert user_name == user.user_name
    assert {:error, :minio_user_not_found} = UserAdapter.remove(user.user_name, actor)
  end

  test "reports a valid absent user without conflating policy absence" do
    assert {:error, :user_not_found} = UserAdapter.info(unique_name("missing-user"))
  end

  test "a user deleted after lookup is still normalized as user-not-found" do
    user_name = unique_name("deleted-between-queries")
    assert {:ok, _user} = IAM.create_user(name: user_name)
    assert {:ok, fetched_user} = IAM.get_user(user_name)
    assert :ok = IAM.delete_user(user_name)

    assert {:error, :user_not_found} = UserAdapter.project_fetched_user(fetched_user)
  end

  test "projects the exact partial UserInfo wire view and safe source evidence" do
    user_name = unique_name("adapter-user")
    assert {:ok, user} = IAM.create_user(name: user_name, status: "active")

    direct_a = unique_name("a-direct")
    direct_z = unique_name("z-direct")
    comma = unique_name("comma") <> ",ambiguous"
    direct_inline = unique_name("direct-inline")

    direct_arns =
      for policy_name <- [direct_z, comma, direct_a], into: %{} do
        arn = create_managed_policy!(policy_name)
        assert :ok = IAM.attach_user_policy(user_name, arn)
        {policy_name, arn}
      end

    assert :ok = IAM.put_principal_policy(user.user_arn, direct_inline, policy_json())

    group_a = unique_name("a-group")
    group_z = unique_name("z-group")
    group_inline = unique_name("group-inline")
    group_managed = unique_name("group-managed")

    assert {:ok, _group} = IAM.create_group(name: group_z)
    assert {:ok, _group} = IAM.create_group(name: group_a)
    assert :ok = IAM.add_user_to_group(user_name, group_z)
    assert :ok = IAM.add_user_to_group(user_name, group_a)
    assert :ok = IAM.put_group_policy(group_a, group_inline, policy_json())

    group_managed_arn = create_managed_policy!(group_managed)
    assert :ok = IAM.attach_group_policy(group_z, group_managed_arn)

    assert {:ok, %{wire: wire, evidence: evidence}} = UserAdapter.info(user_name)

    assert wire == %{
             "memberOf" => Enum.sort([group_a, group_z]),
             "policyName" => Enum.sort([direct_a, direct_z]) |> Enum.join(","),
             "status" => "enabled",
             "updatedAt" => DateTime.to_iso8601(user.updated_at)
           }

    refute Map.has_key?(wire, "secretKey")
    refute Map.has_key?(wire, "userAuthInfo")
    refute Map.has_key?(wire, "credential_bearing")
    refute Map.has_key?(wire, "direct_inline")

    assert evidence.credential_bearing == false

    assert evidence.direct_managed == %{
             arns: direct_arns |> Map.values() |> Enum.sort(),
             count: 3,
             names: Enum.sort([comma, direct_a, direct_z]),
             omitted_names: [comma],
             visible_names: Enum.sort([direct_a, direct_z])
           }

    assert evidence.direct_inline == %{count: 1, names: [direct_inline]}

    assert evidence.group_inline == %{
             count: 1,
             names: ["#{group_a}/#{group_inline}"]
           }

    assert evidence.group_managed == %{
             arns: [group_managed_arn],
             count: 1,
             names: ["#{group_z}/#{group_managed}"]
           }

    assert evidence.role_managed == %{arns: [], count: 0, names: []}
    assert evidence.minio_view_partial == true

    assert evidence.omitted_reason == [
             "ambiguous_direct_managed_policy_name",
             "direct_inline_policy",
             "group_inline_policy",
             "group_managed_policy"
           ]

    safe_evidence = inspect(evidence)
    refute safe_evidence =~ "s3:GetObject"
    refute safe_evidence =~ "Statement"
    refute safe_evidence =~ "secret"
  end

  test "projects disabled and nil timestamps with exact omit discipline" do
    user = %{
      user_name: "inactive-user",
      user_arn: IAM.user_arn("inactive-user"),
      status: "inactive",
      updated_at: nil
    }

    assert {:ok, %{wire: %{"status" => "disabled"} = wire}} =
             UserAdapter.project(user, empty_sources())

    refute Map.has_key?(wire, "policyName")
    refute Map.has_key?(wire, "memberOf")
    refute Map.has_key?(wire, "updatedAt")
  end

  test "credential-bearing evidence requires a same-name key anywhere in the list" do
    no_key = unique_access_name("NOKEY")
    other_only = unique_access_name("OTHERONLY")
    same_name_late = unique_access_name("SAMELATE")

    for user_name <- [no_key, other_only, same_name_late] do
      assert {:ok, _user} = IAM.create_user(name: user_name)
    end

    assert {:ok, _key} =
             IAM.create_access_key(
               access_key_id: unique_access_name("OTHERKEY"),
               secret_key: "other-only-secret-long-enough",
               user_name: other_only
             )

    assert {:ok, _key} =
             IAM.create_access_key(
               access_key_id: unique_access_name("FIRSTKEY"),
               secret_key: "first-secret-long-enough",
               user_name: same_name_late
             )

    assert {:ok, _key} =
             IAM.create_access_key(
               access_key_id: same_name_late,
               secret_key: "same-name-secret-long-enough",
               user_name: same_name_late
             )

    assert {:ok, %{wire: no_key_wire, evidence: %{credential_bearing: false}}} =
             UserAdapter.info(no_key)

    assert {:ok, %{wire: other_wire, evidence: %{credential_bearing: false}}} =
             UserAdapter.info(other_only)

    assert {:ok, %{wire: same_wire, evidence: %{credential_bearing: true}}} =
             UserAdapter.info(same_name_late)

    for wire <- [no_key_wire, other_wire, same_wire] do
      refute Map.has_key?(wire, "credential_bearing")
      refute Map.has_key?(wire, "secretKey")
    end
  end

  defp create_managed_policy!(name) do
    arn = IAM.managed_policy_arn(name, "/")

    assert {:ok, %{policy_arn: ^arn}} =
             IAM.create_managed_policy_strict(name: name, path: "/", document: policy_json())

    arn
  end

  defp empty_sources do
    %{
      credential_bearing: false,
      direct_managed: [],
      direct_inline: [],
      groups: [],
      role_managed: []
    }
  end

  defp policy_json do
    Jason.encode!(%{
      "Version" => "2012-10-17",
      "Statement" => %{
        "Effect" => "Allow",
        "Action" => "s3:GetObject",
        "Resource" => "arn:aws:s3:::admin-user-adapter/*"
      }
    })
  end

  defp unique_name(prefix), do: "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"

  defp unique_access_name(prefix) do
    suffix = System.unique_integer([:positive, :monotonic])
    String.pad_trailing("AKIA#{prefix}#{suffix}", 20, "X")
  end
end
