defmodule Mix.Tasks.Maxio.Iam.DeleteUser do
  @shortdoc "删除 IAM user"
  @moduledoc """
  删除 IAM user，并清理该 user 的 direct policies、group memberships 与绑定 access keys。

  用法：
      mix maxio.iam.delete_user --name alice
  """
  use Mix.Task

  @usage "usage: mix maxio.iam.delete_user --name NAME"
  @switches [name: :string]

  @impl true
  def run(argv) do
    Mix.Task.run("app.start")
    {opts, args, invalid} = OptionParser.parse(argv, strict: @switches)

    if args != [] or invalid != [] do
      Mix.raise(@usage)
    end

    user = opts[:name] || Mix.raise("--name required")
    :ok = Maxio.IAM.delete_user(user)
    IO.puts("[maxio iam.delete_user] status=deleted user=#{inspect(user)}")
  end
end
