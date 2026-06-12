defmodule Mix.Tasks.Maxio.Iam.PutPolicy do
  @shortdoc "绑定或覆盖 principal identity policy"
  @moduledoc """
  绑定或覆盖 IAM identity policy（铁律 4：CLI 管身份策略生命周期）。

  用法：
      mix maxio.iam.put_policy --principal ARN --name NAME --file policy.json
      mix maxio.iam.put_policy --principal ARN --name NAME --policy '{"Statement":...}'

  identity policy 不允许 `Principal` 字段；principal 由 --principal 绑定关系隐式提供。
  """
  use Mix.Task

  @switches [principal: :string, name: :string, file: :string, policy: :string]

  @impl true
  def run(argv) do
    Mix.Task.run("app.start")
    {opts, _, _} = OptionParser.parse(argv, strict: @switches)

    principal = opts[:principal] || Mix.raise("--principal required")
    name = opts[:name] || Mix.raise("--name required")
    policy = policy_body(opts)

    case Maxio.IAM.put_principal_policy(principal, name, policy) do
      :ok -> IO.puts("stored principal policy: #{principal}\t#{name}")
      {:error, reason} -> Mix.raise("put_principal_policy failed: #{inspect(reason)}")
    end
  end

  defp policy_body(opts) do
    cond do
      is_binary(opts[:policy]) ->
        opts[:policy]

      is_binary(opts[:file]) ->
        File.read!(opts[:file])

      true ->
        Mix.raise("--policy or --file required")
    end
  end
end
