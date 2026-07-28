defmodule Mix.Tasks.Maxio.Iam.ListUsers do
  @shortdoc "列出 IAM users"
  @moduledoc "列出显式 IAM users。用法：mix maxio.iam.list_users"
  use Mix.Task

  @impl true
  def run(argv) do
    case argv do
      [] -> :ok
      _ -> Mix.raise("usage: mix maxio.iam.list_users")
    end

    Mix.Task.run("app.start")
    users = Maxio.IAM.list_users()
    IO.puts("[maxio iam.list_users] status=ok count=#{length(users)}")

    Enum.each(users, fn user ->
      IO.puts("#{user.user_name}\t#{user.status}\t#{user.user_arn}")
    end)
  end
end
