defmodule Mix.Tasks.Maxio.Iam.ListUserGroups do
  @shortdoc "列出 IAM user 所属 groups"
  @moduledoc """
  列出 IAM user 所属 groups。

  用法：
      mix maxio.iam.list_user_groups --user alice
  """
  use Mix.Task

  @usage "usage: mix maxio.iam.list_user_groups --user USER"
  @switches [user: :string]

  @impl true
  def run(argv) do
    Mix.Task.run("app.start")
    {opts, args, invalid} = OptionParser.parse(argv, strict: @switches)

    if args != [] or invalid != [] do
      Mix.raise(@usage)
    end

    user = opts[:user] || Mix.raise("--user required")
    groups = Maxio.IAM.list_groups_for_user(user)

    IO.puts(
      "[maxio iam.list_user_groups] status=ok user=#{inspect(user)} count=#{length(groups)}"
    )

    Enum.each(groups, fn group ->
      IO.puts("#{group.group_name}\t#{group.status}\t#{group.group_arn}")
    end)
  end
end
