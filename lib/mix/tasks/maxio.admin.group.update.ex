defmodule Mix.Tasks.Maxio.Admin.Group.Update do
  @shortdoc "Atomically add, remove, or delete-empty an Admin group"
  use Mix.Task

  alias Maxio.Admin.GroupAdapter
  alias Maxio.Config.CLI

  @switches [
    member: :keep,
    remove: :boolean,
    delete_empty: :boolean,
    group_status: :string,
    json: :boolean
  ]
  @usage "usage: mix maxio.admin.group.update GROUP (--member NAME ... [--remove] | --delete-empty) [--group-status VALUE] [--json]"

  @impl true
  def run(argv) do
    {opts, args, invalid} = OptionParser.parse(argv, strict: @switches)
    members = Keyword.get_values(opts, :member)
    delete_empty? = opts[:delete_empty] == true
    remove? = opts[:remove] == true or delete_empty?

    if invalid != [] or length(args) != 1 or invalid_mode?(members, opts) do
      Mix.raise(@usage)
    end

    [group] = args

    request = %{
      group: group,
      members: members,
      group_status: opts[:group_status] || "",
      remove?: remove?
    }

    with :ok <- CLI.boot(), {:ok, result} <- GroupAdapter.update_members(request) do
      print(result, request, delete_empty?, opts[:json])
    else
      {:error, reason} -> Mix.raise(public_failure(reason))
    end
  end

  defp invalid_mode?(members, opts) do
    delete_empty? = opts[:delete_empty] == true

    (delete_empty? and (members != [] or opts[:remove] == true)) or
      (not delete_empty? and members == [])
  end

  defp print(result, request, delete_empty?, true) do
    Mix.shell().info(
      Jason.encode!(%{
        operation: operation(request.remove?, delete_empty?),
        group: request.group,
        requested_member_count: length(request.members),
        changed_member_count: length(Map.get(result, :changed_member_arns, [])),
        affected_member_count: length(Map.get(result, :affected_member_arns, [])),
        group_status_ignored: result.evidence.group_status_ignored,
        updated_at: DateTime.to_iso8601(result.updated_at),
        invalidation_failure_count:
          result |> Map.get(:invalidation, %{failures: []}) |> Map.get(:failures) |> length()
      })
    )
  end

  defp print(result, request, delete_empty?, _json?) do
    Mix.shell().info(
      "[maxio admin.group.update] admin_action=admin_group_members " <>
        "required_action=admin:AddUserToGroup target_group=#{request.group} " <>
        "operation=#{operation(request.remove?, delete_empty?)} " <>
        "requested_member_count=#{length(request.members)} " <>
        "changed_member_count=#{length(Map.get(result, :changed_member_arns, []))} " <>
        "affected_member_count=#{length(Map.get(result, :affected_member_arns, []))} " <>
        "group_status_ignored=#{result.evidence.group_status_ignored} " <>
        "updated_at=#{DateTime.to_iso8601(result.updated_at)} surface=cli"
    )
  end

  defp operation(_remove?, true), do: "delete_empty"
  defp operation(true, false), do: "remove"
  defp operation(false, false), do: "add"

  defp public_failure(:group_not_found), do: "admin group not found"
  defp public_failure(:user_not_found), do: "admin group member not found"
  defp public_failure(:group_not_empty), do: "admin group is not empty"
  defp public_failure(:invalid_resource_name), do: "invalid admin group name"
  defp public_failure(:invalid_group_name), do: "invalid admin group name"
  defp public_failure(:minio_action_not_allowed), do: "admin group member action is not allowed"
  defp public_failure(_reason), do: "admin group update failed"
end
