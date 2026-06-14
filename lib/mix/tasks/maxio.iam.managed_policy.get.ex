defmodule Mix.Tasks.Maxio.Iam.ManagedPolicy.Get do
  @shortdoc "读取 IAM managed policy"
  @moduledoc """
  读取本地 IAM managed policy。

  用法：
      mix maxio.iam.managed_policy.get --arn ARN
      mix maxio.iam.managed_policy.get --arn ARN --json
  """
  use Mix.Task

  @switches [arn: :string, json: :boolean]

  @impl true
  def run(argv) do
    Mix.Task.run("app.start")
    {opts, args, _} = OptionParser.parse(argv, strict: @switches)

    if args != [] do
      Mix.raise("usage: mix maxio.iam.managed_policy.get --arn ARN [--json]")
    end

    policy_arn = opts[:arn] || Mix.raise("--arn required")

    case Maxio.IAM.get_managed_policy(policy_arn) do
      {:ok, policy} ->
        if opts[:json] do
          IO.puts(
            Jason.encode!(%{
              status: "ok",
              policy_arn: policy.policy_arn,
              policy_name: policy.policy_name,
              path: policy.path,
              document: policy.document
            })
          )
        else
          IO.puts(Jason.encode!(policy.document))
        end

      :error ->
        Mix.raise("managed policy not found: #{policy_arn}")

      {:error, reason} ->
        Mix.raise("managed policy get failed: #{inspect(reason)}")
    end
  end
end
