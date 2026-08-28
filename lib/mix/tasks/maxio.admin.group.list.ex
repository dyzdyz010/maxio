defmodule Mix.Tasks.Maxio.Admin.Group.List do
  @shortdoc "List groups through the MinIO Admin projection"
  use Mix.Task

  alias Maxio.Admin.GroupAdapter
  alias Maxio.Config.CLI

  @switches [json: :boolean]
  @usage "usage: mix maxio.admin.group.list [--json]"

  @impl true
  def run(argv) do
    {opts, args, invalid} = OptionParser.parse(argv, strict: @switches)
    if invalid != [] or args != [], do: Mix.raise(@usage)

    with :ok <- CLI.boot(), {:ok, result} <- GroupAdapter.list() do
      if opts[:json] do
        Mix.shell().info(Jason.encode!(result))
      else
        Mix.shell().info(
          "[maxio admin.group.list] admin_action=admin_group_list " <>
            "required_action=admin:ListGroups surface=cli group_count=#{result.evidence.group_count}"
        )

        Enum.each(result.wire, &Mix.shell().info("[maxio admin.group] name=#{&1}"))
      end
    else
      {:error, _reason} -> Mix.raise("admin group list failed")
    end
  end
end
