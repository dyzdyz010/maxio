defmodule Mix.Tasks.Maxio.Iam.CreateUser do
  @shortdoc "创建 IAM user"
  @moduledoc """
  创建显式 IAM user。

  用法：
      mix maxio.iam.create_user --name alice
      mix maxio.iam.create_user --name alice --status inactive
  """
  use Mix.Task

  @usage "usage: mix maxio.iam.create_user --name NAME [--status active|inactive]"
  @switches [name: :string, status: :string]

  @impl true
  def run(argv) do
    Mix.Task.run("app.start")
    {opts, args, invalid} = OptionParser.parse(argv, strict: @switches)

    if args != [] or invalid != [] do
      Mix.raise(@usage)
    end

    case Maxio.IAM.create_user(
           name: opts[:name] || Mix.raise("--name required"),
           status: Keyword.get(opts, :status, "active")
         ) do
      {:ok, user} ->
        IO.puts(
          "[maxio iam.create_user] status=created user_name=#{inspect(user.user_name)} user_arn=#{inspect(user.user_arn)}"
        )

      {:error, reason} ->
        Mix.raise("create_user failed: #{inspect(reason)}")
    end
  end
end
