defmodule Mix.Tasks.Maxio.Iam.ListPolicies do
  @shortdoc "列出某 principal 的 identity policies"
  @moduledoc """
  列出 principal identity policies。

  用法：
      mix maxio.iam.list_policies --principal ARN
      mix maxio.iam.list_policies --principal ARN --json --with-document
  """
  use Mix.Task

  @usage "usage: mix maxio.iam.list_policies --principal ARN [--json] [--with-document]"
  @switches [principal: :string, json: :boolean, with_document: :boolean]

  @impl true
  def run(argv) do
    Mix.Task.run("app.start")
    {opts, args, invalid} = OptionParser.parse(argv, strict: @switches)

    if args != [] or invalid != [] do
      Mix.raise(@usage)
    end

    principal = opts[:principal] || Mix.raise("--principal required")
    policies = Maxio.IAM.list_principal_policies(principal)

    if opts[:json] do
      IO.puts(
        Jason.encode!(%{
          status: "ok",
          principal_arn: principal,
          policies: Enum.map(policies, &json_policy(&1, opts[:with_document]))
        })
      )
    else
      IO.puts(
        "[maxio iam.list_policies] status=ok principal=#{inspect(principal)} count=#{length(policies)}"
      )

      Enum.each(policies, fn policy ->
        IO.puts("#{policy.policy_name}\t#{policy.principal_arn}")
      end)
    end
  end

  defp json_policy(policy, true), do: policy

  defp json_policy(policy, _with_document), do: Map.delete(policy, :document)
end
