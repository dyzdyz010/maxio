defmodule Mix.Tasks.Maxio.Iam.ManagedPolicyTest do
  use Maxio.DataCase, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Maxio.Iam.ManagedPolicy

  @tasks [
    "maxio.iam.managed_policy.create",
    "maxio.iam.managed_policy.get",
    "maxio.iam.managed_policy.list",
    "maxio.iam.managed_policy.delete"
  ]

  setup do
    Enum.each(@tasks, &Mix.Task.reenable/1)

    on_exit(fn ->
      Enum.each(@tasks, &Mix.Task.reenable/1)
    end)
  end

  test "create stores, get prints document, and list shows ARN" do
    policy_name = unique_name("cli-read")
    policy_arn = Maxio.IAM.managed_policy_arn(policy_name, "/cli/")
    policy = policy_doc("s3:GetObject")

    create_output =
      capture_io(fn ->
        ManagedPolicy.Create.run(["--name", policy_name, "--path", "/cli/", "--policy", policy])
      end)

    assert create_output =~ "[maxio iam.managed_policy.create] status=created"
    assert create_output =~ policy_arn

    get_output =
      capture_io(fn ->
        ManagedPolicy.Get.run(["--arn", policy_arn])
      end)

    assert Jason.decode!(get_output)["Statement"]["Action"] == "s3:GetObject"

    list_output =
      capture_io(fn ->
        ManagedPolicy.List.run(["--path-prefix", "/cli/"])
      end)

    assert list_output =~ "[maxio iam.managed_policy.list] status=ok"
    assert list_output =~ policy_arn
    assert list_output =~ policy_name
  end

  test "json outputs are parseable and list hides documents unless requested" do
    policy_name = unique_name("json")
    policy_arn = Maxio.IAM.managed_policy_arn(policy_name)

    create_output =
      capture_io(fn ->
        ManagedPolicy.Create.run([
          "--name",
          policy_name,
          "--policy",
          policy_doc("s3:GetObject"),
          "--json"
        ])
      end)

    assert %{
             "status" => "created",
             "policy_arn" => ^policy_arn,
             "policy_name" => ^policy_name,
             "path" => "/"
           } = Jason.decode!(create_output)

    get_output =
      capture_io(fn ->
        ManagedPolicy.Get.run(["--arn", policy_arn, "--json"])
      end)

    assert %{
             "status" => "ok",
             "policy_arn" => ^policy_arn,
             "policy_name" => ^policy_name,
             "path" => "/",
             "document" => %{"Statement" => %{"Action" => "s3:GetObject"}}
           } = Jason.decode!(get_output)

    list_output =
      capture_io(fn ->
        ManagedPolicy.List.run(["--json"])
      end)

    assert %{"status" => "ok", "policies" => [listed]} = Jason.decode!(list_output)
    assert listed["policy_arn"] == policy_arn
    assert listed["policy_name"] == policy_name
    assert listed["path"] == "/"
    refute Map.has_key?(listed, "document")

    list_with_document_output =
      capture_io(fn ->
        ManagedPolicy.List.run(["--json", "--with-document"])
      end)

    assert %{"policies" => [listed_with_doc]} = Jason.decode!(list_with_document_output)
    assert listed_with_doc["document"]["Statement"]["Action"] == "s3:GetObject"
  end

  test "create refuses to overwrite existing managed policy" do
    policy_name = unique_name("no-overwrite")
    policy_arn = Maxio.IAM.managed_policy_arn(policy_name)

    capture_io(fn ->
      ManagedPolicy.Create.run(["--name", policy_name, "--policy", policy_doc("s3:GetObject")])
    end)

    assert_raise Mix.Error, ~r/managed policy create failed: :already_exists/, fn ->
      ManagedPolicy.Create.run(["--name", policy_name, "--policy", policy_doc("s3:PutObject")])
    end

    get_output =
      capture_io(fn ->
        ManagedPolicy.Get.run(["--arn", policy_arn])
      end)

    assert Jason.decode!(get_output)["Statement"]["Action"] == "s3:GetObject"
  end

  test "delete is idempotent and get fails after delete" do
    policy_name = unique_name("delete")
    policy_arn = Maxio.IAM.managed_policy_arn(policy_name)

    capture_io(fn ->
      ManagedPolicy.Create.run(["--name", policy_name, "--policy", policy_doc("s3:GetObject")])
    end)

    first =
      capture_io(fn ->
        ManagedPolicy.Delete.run(["--arn", policy_arn, "--json"])
      end)

    assert %{"status" => "deleted", "policy_arn" => ^policy_arn} = Jason.decode!(first)

    second =
      capture_io(fn ->
        ManagedPolicy.Delete.run(["--arn", policy_arn])
      end)

    assert second =~ "status=deleted"

    assert_raise Mix.Error, ~r/managed policy not found/, fn ->
      ManagedPolicy.Get.run(["--arn", policy_arn])
    end
  end

  test "invalid args and malformed policies raise" do
    policy_name = unique_name("bad")

    assert_raise Mix.Error, ~r/usage: mix maxio\.iam\.managed_policy\.list/, fn ->
      ManagedPolicy.List.run(["unexpected"])
    end

    assert_raise Mix.Error, ~r/--policy or --file required/, fn ->
      ManagedPolicy.Create.run(["--name", policy_name])
    end

    assert_raise Mix.Error, ~r/managed policy create failed: :malformed/, fn ->
      ManagedPolicy.Create.run(["--name", policy_name, "--policy", "{"])
    end

    with_principal =
      ~s({"Statement":{"Effect":"Allow","Principal":"*","Action":"s3:GetObject","Resource":"*"}})

    assert_raise Mix.Error, ~r/managed policy create failed: :malformed/, fn ->
      ManagedPolicy.Create.run(["--name", policy_name, "--policy", with_principal])
    end

    assert_raise Mix.Error, ~r/managed policy create failed: :malformed/, fn ->
      ManagedPolicy.Create.run(["--name", "bad/name", "--policy", policy_doc("s3:GetObject")])
    end
  end

  defp policy_doc(action) do
    Jason.encode!(%{
      "Version" => "2012-10-17",
      "Statement" => %{
        "Effect" => "Allow",
        "Action" => action,
        "Resource" => "arn:aws:s3:::bucket/*"
      }
    })
  end

  defp unique_name(name), do: "#{name}-#{System.unique_integer([:positive])}"
end
