defmodule Mix.Tasks.Maxio.Admin.User.List do
  @shortdoc "List IAM users through the encrypted MinIO admin projection"
  @moduledoc """
  Prints the same safe projection served by `GET /minio/admin/v3/list-users`.

      mix maxio.admin.user.list
      mix maxio.admin.user.list --json

  No access-key records, signing secrets, policy documents, or session data are
  fetched or rendered.
  """

  use Mix.Task

  alias Maxio.Admin.UserAdapter
  alias Maxio.Config.CLI
  alias Maxio.S3.Log

  @switches [json: :boolean]
  @usage "usage: mix maxio.admin.user.list [--json]"

  @impl true
  def run(argv) do
    {opts, args, invalid} = OptionParser.parse(argv, strict: @switches)

    if invalid != [] or args != [] do
      Mix.raise(@usage)
    end

    with :ok <- CLI.boot(),
         {:ok, result} <- UserAdapter.list() do
      counts = status_counts(result.wire)
      log_projection(result.evidence, counts)
      print(result, counts, opts[:json])
    else
      {:error, _reason} -> Mix.raise("admin user list failed")
    end
  end

  defp print(result, _counts, true), do: Mix.shell().info(Jason.encode!(result))

  defp print(%{wire: wire, evidence: evidence}, counts, _json?) do
    Mix.shell().info(
      "[maxio admin.user.list] admin_action=admin_user_list " <>
        "required_action=admin:ListUsers surface=cli user_count=#{evidence.user_count} " <>
        "enabled_count=#{counts.enabled} disabled_count=#{counts.disabled} " <>
        "minio_view_partial=#{evidence.minio_view_partial_count > 0}"
    )

    wire
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.each(fn {name, user_info} ->
      Mix.shell().info(
        "[maxio admin.user] name=#{name} status=#{user_info["status"]} " <>
          "policy_name=#{Map.get(user_info, "policyName", "nil")} " <>
          "member_of=#{Jason.encode!(Map.get(user_info, "memberOf", []))} " <>
          "updated_at=#{Map.get(user_info, "updatedAt", "nil")}"
      )
    end)

    Mix.shell().info(
      "[maxio admin.user.partial] minio_view_partial=#{evidence.minio_view_partial_count > 0} " <>
        "partial_count=#{evidence.minio_view_partial_count} " <>
        "reasons=#{Jason.encode!(evidence.omitted_reason)}"
    )
  end

  defp status_counts(wire) do
    Enum.reduce(wire, %{enabled: 0, disabled: 0}, fn {_name, user_info}, counts ->
      case user_info["status"] do
        "enabled" -> Map.update!(counts, :enabled, &(&1 + 1))
        "disabled" -> Map.update!(counts, :disabled, &(&1 + 1))
      end
    end)
  end

  defp log_projection(evidence, counts) do
    Log.info("admin user list projected from CLI",
      action: "admin_user_list",
      admin_action: "admin_user_list",
      required_action: "admin:ListUsers",
      user_count: evidence.user_count,
      enabled_count: counts.enabled,
      disabled_count: counts.disabled,
      minio_view_partial: evidence.minio_view_partial_count > 0,
      request_id: nil,
      surface: "cli"
    )
  end
end
