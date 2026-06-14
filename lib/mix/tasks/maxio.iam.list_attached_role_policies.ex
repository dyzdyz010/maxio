defmodule Mix.Tasks.Maxio.Iam.ListAttachedRolePolicies do
  @shortdoc "List managed policies attached to an IAM role"
  @moduledoc """
  List managed policies attached to an IAM role.

  用法：
      mix maxio.iam.list_attached_role_policies --role-arn ARN [--path-prefix PATH] [--json] [--with-document]
  """
  use Mix.Task

  @switches [role_arn: :string, path_prefix: :string, json: :boolean, with_document: :boolean]

  @impl true
  def run(argv) do
    Mix.Task.run("app.start")
    {opts, args, _} = OptionParser.parse(argv, strict: @switches)

    if args != [] do
      Mix.raise(
        "usage: mix maxio.iam.list_attached_role_policies --role-arn ARN [--path-prefix PATH] [--json] [--with-document]"
      )
    end

    role_arn = opts[:role_arn] || Mix.raise("--role-arn required")

    policies =
      Maxio.IAM.list_attached_role_policies(
        role_arn,
        path_prefix: Keyword.get(opts, :path_prefix, "/")
      )

    if opts[:json] do
      IO.puts(
        Jason.encode!(%{
          status: "ok",
          role_arn: role_arn,
          policies: render_policies(policies, opts)
        })
      )
    else
      IO.puts(
        "[maxio iam.list_attached_role_policies] status=ok role_arn=#{inspect(role_arn)} count=#{length(policies)}"
      )

      Enum.each(policies, fn policy ->
        IO.puts(
          "[maxio iam.attached_role_policy] policy_arn=#{inspect(policy.policy_arn)} policy_name=#{inspect(policy.policy_name)} path=#{inspect(policy.path)}"
        )
      end)
    end
  end

  defp render_policies(policies, opts) do
    Enum.map(policies, fn policy ->
      rendered = %{
        role_arn: policy.role_arn,
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
