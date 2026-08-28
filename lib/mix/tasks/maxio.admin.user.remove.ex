defmodule Mix.Tasks.Maxio.Admin.User.Remove do
  @shortdoc "Atomically remove one MinIO-compatible IAM user"
  @moduledoc """
  Removes a user through the public locked cascade facade:

      mix maxio.admin.user.remove NAME --confirm NAME

  Exact confirmation is mandatory. The configured root secret is never read,
  passed through argv, logged, or printed.
  """

  use Mix.Task

  alias Maxio.Admin.UserAdapter
  alias Maxio.Config.CLI
  alias Maxio.S3.Log

  @switches [confirm: :string]
  @usage "usage: mix maxio.admin.user.remove NAME --confirm NAME"

  @impl true
  def run(argv) do
    {opts, args, invalid} = OptionParser.parse(argv, strict: @switches)

    if invalid != [] or length(args) != 1 or not is_binary(opts[:confirm]) do
      Mix.raise(@usage)
    end

    [name] = args

    if opts[:confirm] != name do
      Mix.raise("remove confirmation must exactly match the target user name")
    end

    actor_access_key_id = configured_root_user()

    with :ok <- CLI.boot(),
         {:ok, result} <- UserAdapter.remove(name, actor_access_key_id) do
      affected = result.affected
      attention = invalidation_attention(result)

      Log.info("admin user removed from CLI",
        action: "admin_user_remove",
        admin_action: "admin_user_remove",
        required_action: "admin:DeleteUser",
        target_user: name,
        access_keys_deleted: affected.access_keys_deleted,
        sessions_revoked: affected.sessions_revoked,
        principal_policies_deleted: affected.principal_policies_deleted,
        memberships_deleted: affected.memberships_deleted,
        mfa_devices_deleted: affected.mfa_devices_deleted,
        invalidation_attention: attention,
        surface: "cli"
      )

      Mix.shell().info(
        "[maxio admin.user.remove] admin_action=admin_user_remove " <>
          "required_action=admin:DeleteUser target_user=#{name} " <>
          "access_keys_deleted=#{affected.access_keys_deleted} " <>
          "sessions_revoked=#{affected.sessions_revoked} " <>
          "principal_policies_deleted=#{affected.principal_policies_deleted} " <>
          "memberships_deleted=#{affected.memberships_deleted} " <>
          "mfa_devices_deleted=#{affected.mfa_devices_deleted} " <>
          "invalidation_attention=#{attention} surface=cli"
      )
    else
      {:error, reason} -> Mix.raise(public_failure(reason))
    end
  end

  defp configured_root_user do
    Application.fetch_env!(:maxio, :s3)
    |> Keyword.fetch!(:root_user)
  end

  defp invalidation_attention(%{invalidation: %{failures: []}}), do: "ok"
  defp invalidation_attention(_result), do: "attention"

  defp public_failure(:minio_user_not_found), do: "admin user not found"
  defp public_failure(:minio_action_not_allowed), do: "admin user remove action is not allowed"
  defp public_failure(_reason), do: "admin user remove failed"
end
