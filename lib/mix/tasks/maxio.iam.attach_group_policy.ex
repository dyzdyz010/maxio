defmodule Mix.Tasks.Maxio.Iam.AttachGroupPolicy do
  @shortdoc "Attach a managed policy to an IAM group"
  @moduledoc """
  Attach a local managed policy to an IAM group.

  用法：
      mix maxio.iam.attach_group_policy --group GROUP_OR_ARN --policy-arn ARN [--json]
  """
  use Mix.Task

  @usage "usage: mix maxio.iam.attach_group_policy --group GROUP_OR_ARN --policy-arn ARN [--json]"
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

    case Maxio.IAM.attach_group_policy(group, policy_arn) do
      :ok ->
        if opts[:json] do
          IO.puts(Jason.encode!(%{status: "attached", group: group, policy_arn: policy_arn}))
        else
          IO.puts(
            "[maxio iam.attach_group_policy] status=attached group=#{inspect(group)} policy_arn=#{inspect(policy_arn)}"
          )
        end

      {:error, reason} ->
        Mix.raise("attach_group_policy failed: #{inspect(reason)}")
    end
  end
end
