defmodule Mix.Tasks.Maxio.Iam.AttachUserPolicy do
  @shortdoc "Attach a managed policy to an IAM user"
  @moduledoc """
  Attach a local managed policy to an IAM user.

  用法：
      mix maxio.iam.attach_user_policy --user USER_OR_ARN --policy-arn ARN [--json]
  """
  use Mix.Task

  @usage "usage: mix maxio.iam.attach_user_policy --user USER_OR_ARN --policy-arn ARN [--json]"
  @switches [user: :string, policy_arn: :string, json: :boolean]

  @impl true
  def run(argv) do
    Mix.Task.run("app.start")
    {opts, args, invalid} = OptionParser.parse(argv, strict: @switches)

    if args != [] or invalid != [] do
      Mix.raise(@usage)
    end

    user = opts[:user] || Mix.raise("--user required")
    policy_arn = opts[:policy_arn] || Mix.raise("--policy-arn required")

    case Maxio.IAM.attach_user_policy(user, policy_arn) do
      :ok ->
        if opts[:json] do
          IO.puts(Jason.encode!(%{status: "attached", user: user, policy_arn: policy_arn}))
        else
          IO.puts(
            "[maxio iam.attach_user_policy] status=attached user=#{inspect(user)} policy_arn=#{inspect(policy_arn)}"
          )
        end

      {:error, reason} ->
        Mix.raise("attach_user_policy failed: #{inspect(reason)}")
    end
  end
end
