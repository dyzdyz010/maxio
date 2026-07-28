defmodule Mix.Tasks.Maxio.Iam.ListAttachedGroupPolicies do
  @shortdoc "List managed policies attached to an IAM group"
  @moduledoc """
  List managed policies attached to an IAM group.

  用法：
      mix maxio.iam.list_attached_group_policies --group GROUP_OR_ARN [--path-prefix PATH] [--json] [--with-document]
  """
  use Mix.Task

  @usage "usage: mix maxio.iam.list_attached_group_policies --group GROUP_OR_ARN [--path-prefix PATH] [--json] [--with-document]"
  @switches [group: :string, path_prefix: :string, json: :boolean, with_document: :boolean]

  @impl true
  def run(argv) do
    Mix.Task.run("app.start")
    {opts, args, invalid} = OptionParser.parse(argv, strict: @switches)

    if args != [] or invalid != [] do
      Mix.raise(@usage)
    end

    group = opts[:group] || Mix.raise("--group required")

    policies =
      Maxio.IAM.list_attached_group_policies(
        group,
        path_prefix: Keyword.get(opts, :path_prefix, "/")
      )

    if opts[:json] do
      IO.puts(
        Jason.encode!(%{status: "ok", group: group, policies: render_policies(policies, opts)})
      )
    else
      IO.puts(
        "[maxio iam.list_attached_group_policies] status=ok group=#{inspect(group)} count=#{length(policies)}"
      )

      Enum.each(policies, fn policy ->
        IO.puts(
          "[maxio iam.attached_group_policy] policy_arn=#{inspect(policy.policy_arn)} policy_name=#{inspect(policy.policy_name)} path=#{inspect(policy.path)}"
        )
      end)
    end
  end

  defp render_policies(policies, opts) do
    Enum.map(policies, fn policy ->
      rendered = %{
        group_arn: policy.group_arn,
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
