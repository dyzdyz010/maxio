defmodule Mix.Tasks.Maxio.IamRewrapSecretsTest do
  use Maxio.DataCase, async: false

  import ExUnit.CaptureIO

  alias Maxio.IAM
  alias Maxio.IAM.AccessKey
  alias Mix.Tasks.Maxio.Iam

  @task "maxio.iam.rewrap_secrets"

  setup do
    Mix.Task.reenable(@task)

    on_exit(fn ->
      Mix.Task.reenable(@task)
    end)
  end

  test "CLI is dry-run by default and requires confirm to rewrite" do
    old_key = b64_secret("cli-rewrite-old")
    new_key = b64_secret("cli-rewrite-new")

    with_access_key_secret_config([current_key_id: "old", secret_key: old_key], fn ->
      {:ok, key} =
        IAM.create_access_key(access_key_id: unique_ak("CLIREWRITE"), secret_key: "cli-secret")

      with_access_key_secret_config(
        [current_key_id: "new", secret_key: new_key, keys: %{"old" => old_key}],
        fn ->
          dry_output =
            capture_io(fn ->
              Iam.RewrapSecrets.run(["--access-keys", "--json"])
            end)

          assert %{
                   "status" => "dry_run",
                   "dry_run" => true,
                   "totals" => %{"candidates" => 1, "rewrapped" => 0}
                 } = Jason.decode!(dry_output)

          assert row_key_id(Repo.get_by!(AccessKey, access_key_id: key.access_key_id).secret_key) ==
                   "old"

          Mix.Task.reenable(@task)

          confirm_output =
            capture_io(fn ->
              Iam.RewrapSecrets.run(["--access-keys", "--confirm"])
            end)

          assert confirm_output =~ "[maxio iam.rewrap_secrets] status=rewrapped"
          assert confirm_output =~ "rewrapped=1"

          assert row_key_id(Repo.get_by!(AccessKey, access_key_id: key.access_key_id).secret_key) ==
                   "new"
        end
      )
    end)
  end

  test "CLI blocked runs fail, print sanitized reports, and reject conflicting flags" do
    new_key = b64_secret("cli-rewrite-block-new")
    bad_access_key = unique_ak("CLIBLOCK")

    with_access_key_secret_config([current_key_id: "new", secret_key: new_key], fn ->
      Repo.insert!(%AccessKey{
        access_key_id: bad_access_key,
        secret_key: invalid_access_key_envelope("cli-output-secret"),
        principal_arn: IAM.user_arn(bad_access_key),
        type: "iam_user",
        status: "active",
        tags: %{}
      })

      {json_output, json_error} =
        run_task_capturing_mix_error(["--access-keys", "--confirm", "--json"])

      assert json_error =~ "iam signing secret rewrap blocked"

      assert %{
               "status" => "blocked",
               "totals" => %{"errors" => 1},
               "scopes" => %{"access_keys" => %{"errors" => 1}}
             } = Jason.decode!(json_output)

      refute json_output =~ "cli-output-secret"
      refute json_error =~ "cli-output-secret"

      Mix.Task.reenable(@task)

      {text_output, text_error} =
        run_task_capturing_mix_error(["--access-keys", "--confirm"])

      assert text_output =~ "[maxio iam.rewrap_secrets] status=blocked"
      refute text_output =~ "cli-output-secret"
      refute text_error =~ "cli-output-secret"

      Mix.Task.reenable(@task)

      assert_raise Mix.Error, ~r/--dry-run and --confirm are mutually exclusive/, fn ->
        Iam.RewrapSecrets.run(["--dry-run", "--confirm"])
      end
    end)
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
  defp unique_ak(prefix), do: "AKIA#{prefix}#{System.unique_integer([:positive])}"

  defp invalid_access_key_envelope(payload) do
    "maxio-ak-secret-v1:" <> Base.url_encode64(payload, padding: false)
  end

  defp run_task_capturing_mix_error(args) do
    parent = self()

    output =
      capture_io(fn ->
        try do
          Iam.RewrapSecrets.run(args)
        rescue
          error in Mix.Error -> send(parent, {:mix_error, error.message})
        end
      end)

    assert_receive {:mix_error, message}
    {output, message}
  end

  defp row_key_id(secret_key) do
    secret_key
    |> String.replace_prefix("maxio-ak-secret-v1:", "")
    |> Base.url_decode64!(padding: false)
    |> Jason.decode!()
    |> Map.fetch!("key_id")
  end
end
