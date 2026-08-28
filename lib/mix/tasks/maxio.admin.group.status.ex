defmodule Mix.Tasks.Maxio.Admin.Group.Status do
  @shortdoc "Enable or disable a MinIO-compatible IAM group"
  use Mix.Task

  alias Maxio.Admin.GroupAdapter
  alias Maxio.Config.CLI

  @switches [json: :boolean]
  @usage "usage: mix maxio.admin.group.status GROUP enabled|disabled [--json]"

  @impl true
  def run(argv) do
    {opts, args, invalid} = OptionParser.parse(argv, strict: @switches)

    case {invalid, args} do
      {[], [group, status]} when status in ["enabled", "disabled"] ->
        run_status(group, status, opts[:json])

      _other ->
        Mix.raise(@usage)
    end
  end

  defp run_status(group, status, json?) do
    with :ok <- CLI.boot(), {:ok, result} <- GroupAdapter.status(group, status) do
      wire = %{
        group: result.group.group_name,
        requested_status: status,
        actual_status: result.group.status,
        affected_member_count: length(result.affected_member_arns),
        updated_at: DateTime.to_iso8601(result.updated_at),
        invalidation_failure_count: length(result.invalidation.failures)
      }

      if json? do
        Mix.shell().info(Jason.encode!(wire))
      else
        Mix.shell().info(
          "[maxio admin.group.status] admin_action=admin_group_status " <>
            "required_action=admin:EnableGroup target_group=#{wire.group} " <>
            "requested_status=#{status} actual_status=#{wire.actual_status} " <>
            "affected_member_count=#{wire.affected_member_count} " <>
            "updated_at=#{wire.updated_at} surface=cli"
        )
      end
    else
      {:error, :group_not_found} -> Mix.raise("admin group not found")
      {:error, _reason} -> Mix.raise("admin group status change failed")
    end
  end
end
