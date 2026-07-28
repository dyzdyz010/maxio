defmodule Mix.Tasks.Maxio.Iam.CreateGroup do
  @shortdoc "创建 IAM group"
  @moduledoc """
  创建 IAM group。

  用法：
      mix maxio.iam.create_group --name readers
      mix maxio.iam.create_group --name readers --status inactive
  """
  use Mix.Task

  @usage "usage: mix maxio.iam.create_group --name NAME [--status active|inactive]"
  @switches [name: :string, status: :string]

  @impl true
  def run(argv) do
    Mix.Task.run("app.start")
    {opts, args, invalid} = OptionParser.parse(argv, strict: @switches)

    if args != [] or invalid != [] do
      Mix.raise(@usage)
    end

    case Maxio.IAM.create_group(
           name: opts[:name] || Mix.raise("--name required"),
           status: Keyword.get(opts, :status, "active")
         ) do
      {:ok, group} ->
        IO.puts(
          "[maxio iam.create_group] status=created group_name=#{inspect(group.group_name)} group_arn=#{inspect(group.group_arn)}"
        )

      {:error, reason} ->
        Mix.raise("create_group failed: #{inspect(reason)}")
    end
  end
end
