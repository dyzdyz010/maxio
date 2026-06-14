defmodule Mix.Tasks.Maxio.Iam.ManagedPolicy.List do
  @shortdoc "列出 IAM managed policies"
  @moduledoc """
  列出本地 IAM managed policies。

  用法：
      mix maxio.iam.managed_policy.list
      mix maxio.iam.managed_policy.list --path-prefix /team/
      mix maxio.iam.managed_policy.list --json [--with-document] [--path-prefix /team/]
  """
  use Mix.Task

  @switches [json: :boolean, with_document: :boolean, path_prefix: :string]

  @impl true
  def run(argv) do
    Mix.Task.run("app.start")
    {opts, args, _} = OptionParser.parse(argv, strict: @switches)

    if args != [] do
      Mix.raise(
        "usage: mix maxio.iam.managed_policy.list [--json] [--with-document] [--path-prefix PATH]"
      )
    end

    policies = Maxio.IAM.list_managed_policies(path_prefix: Keyword.get(opts, :path_prefix, "/"))

    if opts[:json] do
      IO.puts(Jason.encode!(%{status: "ok", policies: render_policies(policies, opts)}))
    else
      IO.puts("[maxio iam.managed_policy.list] status=ok count=#{length(policies)}")

      Enum.each(policies, fn policy ->
        IO.puts(
          "[maxio iam.managed_policy] policy_arn=#{inspect(policy.policy_arn)} policy_name=#{inspect(policy.policy_name)} path=#{inspect(policy.path)}"
        )
      end)
    end
  end

  defp render_policies(policies, opts) do
    Enum.map(policies, fn policy ->
      rendered = %{
        policy_arn: policy.policy_arn,
        policy_name: policy.policy_name,
        path: policy.path,
        inserted_at: policy.inserted_at,
        updated_at: policy.updated_at
      }

      if opts[:with_document] do
        Map.put(rendered, :document, policy.document)
      else
        rendered
      end
    end)
  end
end
