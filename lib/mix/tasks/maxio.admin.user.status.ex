defmodule Mix.Tasks.Maxio.Admin.User.Status do
  @shortdoc "Enable or disable one MinIO-compatible IAM user"
  @moduledoc """
  Changes only the reversible user status through the public Admin adapter:

      mix maxio.admin.user.status NAME enabled|disabled

  The configured root access-key ID is the local actor. Its secret is never
  read, passed to the adapter, or printed.
  """

  use Mix.Task

  alias Maxio.Admin.UserAdapter
  alias Maxio.Config.CLI
  alias Maxio.S3.Log

  @usage "usage: mix maxio.admin.user.status NAME enabled|disabled"

  @impl true
  def run([name, status]) when status in ["enabled", "disabled"] do
    actor_access_key_id = configured_root_user()

    with :ok <- CLI.boot(),
         {:ok, result} <- UserAdapter.status(name, status, actor_access_key_id) do
      attention = invalidation_attention(result)

      Log.info("admin user status changed from CLI",
        action: "admin_user_status",
        admin_action: "admin_user_status",
        required_action: "admin:EnableUser",
        target_user: name,
        requested_status: status,
        affected_credentials: result.affected.credentials,
        invalidation_attention: attention,
        surface: "cli"
      )

      Mix.shell().info(
        "[maxio admin.user.status] admin_action=admin_user_status " <>
          "required_action=admin:EnableUser target_user=#{name} requested_status=#{status} " <>
          "affected_credentials=#{result.affected.credentials} " <>
          "invalidation_attention=#{attention} surface=cli"
      )
    else
      {:error, reason} -> Mix.raise(public_failure(reason))
    end
  end

  def run(_argv), do: Mix.raise(@usage)

  defp configured_root_user do
    Application.fetch_env!(:maxio, :s3)
    |> Keyword.fetch!(:root_user)
  end

  defp invalidation_attention(%{invalidation: %{failures: []}}), do: "ok"
  defp invalidation_attention(_result), do: "attention"

  defp public_failure(:minio_user_not_found), do: "admin user not found"
  defp public_failure(:invalid_status_self_target), do: "cannot change the signing user's status"
  defp public_failure(:minio_action_not_allowed), do: "admin user status action is not allowed"
  defp public_failure(_reason), do: "admin user status change failed"
end
