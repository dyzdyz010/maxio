defmodule Mix.Tasks.Maxio.Iam.PutGroupPolicy do
  @shortdoc "绑定或覆盖 IAM group identity policy"
  @moduledoc """
  绑定或覆盖 IAM group identity policy。

  用法：
      mix maxio.iam.put_group_policy --group readers --name read --file policy.json
      mix maxio.iam.put_group_policy --group readers --name read --policy '{"Statement":...}'
  """
  use Mix.Task

  @usage "usage: mix maxio.iam.put_group_policy --group GROUP --name NAME (--file PATH | --policy JSON)"
  @switches [group: :string, name: :string, file: :string, policy: :string]

  @impl true
  def run(argv) do
    Mix.Task.run("app.start")
    {opts, args, invalid} = OptionParser.parse(argv, strict: @switches)

    if args != [] or invalid != [] do
      Mix.raise(@usage)
    end

    group = opts[:group] || Mix.raise("--group required")
    name = opts[:name] || Mix.raise("--name required")

    case Maxio.IAM.put_group_policy(group, name, policy_body(opts)) do
      :ok ->
        IO.puts(
          "[maxio iam.put_group_policy] status=stored group=#{inspect(group)} policy_name=#{inspect(name)}"
        )

      {:error, reason} ->
        Mix.raise("put_group_policy failed: #{inspect(reason)}")
    end
  end

  defp policy_body(opts) do
    cond do
      is_binary(opts[:policy]) and is_binary(opts[:file]) ->
        Mix.raise("--policy and --file are mutually exclusive")

      is_binary(opts[:policy]) ->
        opts[:policy]

      is_binary(opts[:file]) ->
        File.read!(opts[:file])

      true ->
        Mix.raise("--policy or --file required")
    end
  end
end
