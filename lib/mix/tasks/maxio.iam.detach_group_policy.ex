defmodule Mix.Tasks.Maxio.Iam.DetachGroupPolicy do
  @shortdoc "Detach a managed policy from an IAM group"
  @moduledoc """
  Detach a managed policy from an IAM group.

  用法：
      mix maxio.iam.detach_group_policy --group GROUP_OR_ARN --policy-arn ARN [--json]
  """
  use Mix.Task

  @usage "usage: mix maxio.iam.detach_group_policy --group GROUP_OR_ARN --policy-arn ARN [--json]"
  @switches [group: :string, policy_arn: :string, json: :boolean]

  @impl true
  def run(argv) do
    Mix.Task.run("app.start")
    {opts, args, invalid} = OptionParser.parse(argv, strict: @switches)

    if args != [] or invalid != [] do
      Mix.raise(@usage)
    end

    group = opts[:group] || Mix.raise("--group required")
    policy_arn = opts[:policy_arn] || Mix.raise("--policy-arn required")

    case Maxio.IAM.detach_group_policy(group, policy_arn) do
      :ok ->
        if opts[:json] do
          IO.puts(Jason.encode!(%{status: "detached", group: group, policy_arn: policy_arn}))
        else
          IO.puts(
            "[maxio iam.detach_group_policy] status=detached group=#{inspect(group)} policy_arn=#{inspect(policy_arn)}"
          )
        end

      {:error, reason} ->
        Mix.raise("detach_group_policy failed: #{inspect(reason)}")
    end
  end
end
