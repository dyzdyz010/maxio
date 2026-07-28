defmodule Mix.Tasks.Maxio.Iam.DeleteGroup do
  @shortdoc "删除 IAM group"
  @moduledoc """
  删除 IAM group，并清理该 group 的 policies 与 memberships。

  用法：
      mix maxio.iam.delete_group --name readers
  """
  use Mix.Task

  @usage "usage: mix maxio.iam.delete_group --name NAME"
  @switches [name: :string]

  @impl true
  def run(argv) do
    Mix.Task.run("app.start")
    {opts, args, invalid} = OptionParser.parse(argv, strict: @switches)

    if args != [] or invalid != [] do
      Mix.raise(@usage)
    end

    group = opts[:name] || Mix.raise("--name required")
    :ok = Maxio.IAM.delete_group(group)
    IO.puts("[maxio iam.delete_group] status=deleted group=#{inspect(group)}")
  end
end
