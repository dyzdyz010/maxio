defmodule Mix.Tasks.Maxio.Admin.Policy.List do
  @shortdoc "Inspect the MinIO admin view of local managed policies"
  @moduledoc """
  Lists root-path managed policies as exposed by the MinIO admin API and names
  every non-root policy omitted from that compatibility view.

      mix maxio.admin.policy.list
      mix maxio.admin.policy.list --json
  """

  use Mix.Task

  alias Maxio.Admin.PolicyAdapter

  @switches [json: :boolean]

  @impl true
  def run(argv) do
    {opts, args, invalid} = OptionParser.parse(argv, strict: @switches)

    if args != [] or invalid != [] do
      Mix.raise("usage: mix maxio.admin.policy.list [--json]")
    end

    Mix.Task.run("app.start")
    {:ok, %{policies: policies, omitted: omitted}} = PolicyAdapter.list()
    omitted = Enum.map(omitted, &Map.put(&1, :reason, "non_root_path"))

    if opts[:json] do
      Mix.shell().info(Jason.encode!(%{policies: policies, omitted: omitted}))
    else
      policies
      |> Map.keys()
      |> Enum.sort()
      |> Enum.each(fn name ->
        Mix.shell().info("[maxio admin.policy.visible] name=#{name} path=/")
      end)

      omitted
      |> Enum.sort_by(&{&1.policy_name, &1.path, &1.policy_arn})
      |> Enum.each(fn policy ->
        Mix.shell().info(
          "[maxio admin.policy.omitted] name=#{policy.policy_name} " <>
            "path=#{policy.path} reason=non_root_path"
        )
      end)
    end
  end
end
