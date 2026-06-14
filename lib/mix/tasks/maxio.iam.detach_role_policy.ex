defmodule Mix.Tasks.Maxio.Iam.DetachRolePolicy do
  @shortdoc "Detach a managed policy from an IAM role"
  @moduledoc """
  Detach a managed policy from an IAM role.

  用法：
      mix maxio.iam.detach_role_policy --role-arn ARN --policy-arn ARN [--json]
  """
  use Mix.Task

  @switches [role_arn: :string, policy_arn: :string, json: :boolean]

  @impl true
  def run(argv) do
    Mix.Task.run("app.start")
    {opts, args, _} = OptionParser.parse(argv, strict: @switches)

    if args != [] do
      Mix.raise("usage: mix maxio.iam.detach_role_policy --role-arn ARN --policy-arn ARN")
    end

    role_arn = opts[:role_arn] || Mix.raise("--role-arn required")
    policy_arn = opts[:policy_arn] || Mix.raise("--policy-arn required")

    case Maxio.IAM.detach_role_policy(role_arn, policy_arn) do
      :ok ->
        if opts[:json] do
          IO.puts(
            Jason.encode!(%{status: "detached", role_arn: role_arn, policy_arn: policy_arn})
          )
        else
          IO.puts(
            "[maxio iam.detach_role_policy] status=detached role_arn=#{inspect(role_arn)} policy_arn=#{inspect(policy_arn)}"
          )
        end

      {:error, reason} ->
        Mix.raise("detach_role_policy failed: #{inspect(reason)}")
    end
  end
end
