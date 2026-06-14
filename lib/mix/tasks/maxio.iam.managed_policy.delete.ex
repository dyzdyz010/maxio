defmodule Mix.Tasks.Maxio.Iam.ManagedPolicy.Delete do
  @shortdoc "删除 IAM managed policy"
  @moduledoc """
  删除本地 IAM managed policy（幂等）。

  用法：
      mix maxio.iam.managed_policy.delete --arn ARN
      mix maxio.iam.managed_policy.delete --arn ARN --json
  """
  use Mix.Task

  @switches [arn: :string, json: :boolean]

  @impl true
  def run(argv) do
    Mix.Task.run("app.start")
    {opts, args, _} = OptionParser.parse(argv, strict: @switches)

    if args != [] do
      Mix.raise("usage: mix maxio.iam.managed_policy.delete --arn ARN [--json]")
    end

    policy_arn = opts[:arn] || Mix.raise("--arn required")

    case Maxio.IAM.delete_managed_policy(policy_arn) do
      :ok ->
        if opts[:json] do
          IO.puts(Jason.encode!(%{status: "deleted", policy_arn: policy_arn}))
        else
          IO.puts(
            "[maxio iam.managed_policy.delete] status=deleted policy_arn=#{inspect(policy_arn)}"
          )
        end

      {:error, reason} ->
        Mix.raise("managed policy delete failed: #{inspect(reason)}")
    end
  end
end
