defmodule Mix.Tasks.Maxio.Iam.ListGroupUsers do
  @shortdoc "列出 IAM group 成员"
  @moduledoc """
  列出 IAM group 的 user 成员。

  用法：
      mix maxio.iam.list_group_users --group readers
  """
  use Mix.Task

  @usage "usage: mix maxio.iam.list_group_users --group GROUP"
  @switches [group: :string]

  @impl true
  def run(argv) do
    Mix.Task.run("app.start")
    {opts, args, invalid} = OptionParser.parse(argv, strict: @switches)

    if args != [] or invalid != [] do
      Mix.raise(@usage)
    end

    group = opts[:group] || Mix.raise("--group required")
    users = Maxio.IAM.list_users_in_group(group)

    IO.puts(
      "[maxio iam.list_group_users] status=ok group=#{inspect(group)} count=#{length(users)}"
    )

    Enum.each(users, fn user ->
      IO.puts("#{user.user_name}\t#{user.status}\t#{user.user_arn}")
    end)
  end
end
