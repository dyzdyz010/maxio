defmodule Mix.Tasks.Maxio.Admin.Group.Show do
  @shortdoc "Inspect one group through the MinIO Admin projection"
  use Mix.Task

  alias Maxio.Admin.GroupAdapter
  alias Maxio.Config.CLI

  @switches [json: :boolean]
  @usage "usage: mix maxio.admin.group.show NAME [--json]"

  @impl true
  def run(argv) do
    {opts, args, invalid} = OptionParser.parse(argv, strict: @switches)
    if invalid != [] or length(args) != 1, do: Mix.raise(@usage)
    [name] = args

    with :ok <- CLI.boot(), {:ok, result} <- GroupAdapter.info(name) do
      print(result, opts[:json])
    else
      {:error, :group_not_found} ->
        Mix.raise("admin group not found: #{name}")

      {:error, reason} when reason in [:invalid_argument, :invalid_resource_name] ->
        Mix.raise("invalid admin group name")

      {:error, _reason} ->
        Mix.raise("admin group lookup failed")
    end
  end

  defp print(result, true), do: Mix.shell().info(Jason.encode!(result))

  defp print(%{wire: wire, evidence: evidence}, _json?) do
    Mix.shell().info(
      "[maxio admin.group.show] name=#{wire["name"]} status=#{wire["status"]} " <>
        "members=#{Jason.encode!(wire["members"])} policy=#{wire["policy"]} " <>
        "updated_at=#{Map.get(wire, "updatedAt", "nil")}"
    )

    Mix.shell().info(
      "[maxio admin.group.omitted] inline_policy_names=#{Jason.encode!(evidence.inline_policy_names)} " <>
        "non_root_managed_policy_names=#{Jason.encode!(evidence.non_root_managed_policy_names)} " <>
        "visible_managed_policy_count=#{evidence.visible_managed_policy_count} " <>
        "member_count=#{evidence.member_count} snapshot=#{evidence.snapshot} " <>
        "member_order=#{evidence.member_order}"
    )
  end
end
