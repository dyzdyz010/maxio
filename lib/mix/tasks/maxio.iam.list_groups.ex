defmodule Mix.Tasks.Maxio.Iam.ListGroups do
  @shortdoc "列出 IAM groups"
  @moduledoc "列出 IAM groups。用法：mix maxio.iam.list_groups"
  use Mix.Task

  @impl true
  def run(argv) do
    case argv do
      [] -> :ok
      _ -> Mix.raise("usage: mix maxio.iam.list_groups")
    end

    Mix.Task.run("app.start")
    groups = Maxio.IAM.list_groups()
    IO.puts("[maxio iam.list_groups] status=ok count=#{length(groups)}")

    Enum.each(groups, fn group ->
      IO.puts("#{group.group_name}\t#{group.status}\t#{group.group_arn}")
    end)
  end
end
