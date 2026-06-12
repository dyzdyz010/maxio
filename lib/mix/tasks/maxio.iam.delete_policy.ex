defmodule Mix.Tasks.Maxio.Iam.DeletePolicy do
  @shortdoc "删除某 principal 的 identity policy"
  @moduledoc "删除 principal identity policy（幂等）。用法：mix maxio.iam.delete_policy --principal ARN --name NAME"
  use Mix.Task

  @switches [principal: :string, name: :string]

  @impl true
  def run(argv) do
    Mix.Task.run("app.start")
    {opts, _, _} = OptionParser.parse(argv, strict: @switches)
    principal = opts[:principal] || Mix.raise("--principal required")
    name = opts[:name] || Mix.raise("--name required")

    :ok = Maxio.IAM.delete_principal_policy(principal, name)
    IO.puts("deleted principal policy: #{principal}\t#{name}")
  end
end
