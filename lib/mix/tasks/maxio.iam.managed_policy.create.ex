defmodule Mix.Tasks.Maxio.Iam.ManagedPolicy.Create do
  @shortdoc "创建 IAM managed policy"
  @moduledoc """
  创建本地 IAM managed policy。

  用法：
      mix maxio.iam.managed_policy.create --name NAME --file policy.json
      mix maxio.iam.managed_policy.create --name NAME --path /team/dev/ --policy '{"Statement":...}' --json

  managed policy 可被 STS AssumeRole 的 PolicyArns 引用。当前不把 managed
  policy 附着到 user/group/role identity policy。
  """
  use Mix.Task

  @switches [name: :string, path: :string, file: :string, policy: :string, json: :boolean]

  @impl true
  def run(argv) do
    Mix.Task.run("app.start")
    {opts, args, _} = OptionParser.parse(argv, strict: @switches)

    if args != [] do
      Mix.raise(
        "usage: mix maxio.iam.managed_policy.create --name NAME [--path PATH] (--file PATH | --policy JSON)"
      )
    end

    policy_name = opts[:name] || Mix.raise("--name required")
    policy = policy_body(opts)

    case Maxio.IAM.create_managed_policy(
           name: policy_name,
           path: Keyword.get(opts, :path, "/"),
           policy: policy
         ) do
      {:ok, managed_policy} ->
        if opts[:json] do
          IO.puts(
            Jason.encode!(%{
              status: "created",
              policy_arn: managed_policy.policy_arn,
              policy_name: managed_policy.policy_name,
              path: managed_policy.path
            })
          )
        else
          IO.puts(
            "[maxio iam.managed_policy.create] status=created policy_arn=#{inspect(managed_policy.policy_arn)}"
          )
        end

      {:error, reason} ->
        Mix.raise("managed policy create failed: #{inspect(reason)}")
    end
  end

  defp policy_body(opts) do
    cond do
      is_binary(opts[:policy]) -> opts[:policy]
      is_binary(opts[:file]) -> File.read!(opts[:file])
      true -> Mix.raise("--policy or --file required")
    end
  end
end
