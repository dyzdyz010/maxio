defmodule Mix.Tasks.Maxio.Iam.AddUserToGroup do
  @shortdoc "把 IAM user 加入 group"
  @moduledoc """
  把 IAM user 加入 IAM group（幂等）。

  用法：
      mix maxio.iam.add_user_to_group --user alice --group readers
  """
  use Mix.Task

  @usage "usage: mix maxio.iam.add_user_to_group --user USER --group GROUP"
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

    case Maxio.IAM.add_user_to_group(user, group) do
      :ok ->
        IO.puts(
          "[maxio iam.add_user_to_group] status=attached user=#{inspect(user)} group=#{inspect(group)}"
        )

      {:error, reason} ->
        Mix.raise("add_user_to_group failed: #{inspect(reason)}")
    end
  end
end
