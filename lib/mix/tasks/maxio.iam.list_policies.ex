defmodule Mix.Tasks.Maxio.Iam.ListPolicies do
  @shortdoc "列出某 principal 的 identity policies"
  @moduledoc "列出 principal identity policies。用法：mix maxio.iam.list_policies --principal ARN"
  use Mix.Task

  @switches [principal: :string]

  @impl true
  def run(argv) do
    Mix.Task.run("app.start")
    {opts, _, _} = OptionParser.parse(argv, strict: @switches)
    principal = opts[:principal] || Mix.raise("--principal required")

    principal
    |> Maxio.IAM.list_principal_policies()
    |> Enum.each(fn policy ->
      IO.puts("#{policy.principal_arn}\t#{policy.policy_name}")
    end)
  end
end
