defmodule Mix.Tasks.Maxio.Iam.RemoveUserFromGroup do
  @shortdoc "把 IAM user 从 group 移除"
  @moduledoc """
  把 IAM user 从 IAM group 移除（幂等）。

  用法：
      mix maxio.iam.remove_user_from_group --user alice --group readers
  """
  use Mix.Task

  @usage "usage: mix maxio.iam.remove_user_from_group --user USER --group GROUP"
  @switches [user: :string, group: :string]

  @impl true
  def run(argv) do
    Mix.Task.run("app.start")
    {opts, args, invalid} = OptionParser.parse(argv, strict: @switches)

    if args != [] or invalid != [] do
      Mix.raise(@usage)
    end

    user = opts[:user] || Mix.raise("--user required")
    group = opts[:group] || Mix.raise("--group required")
    :ok = Maxio.IAM.remove_user_from_group(user, group)

    IO.puts(
      "[maxio iam.remove_user_from_group] status=detached user=#{inspect(user)} group=#{inspect(group)}"
    )
  end
end
