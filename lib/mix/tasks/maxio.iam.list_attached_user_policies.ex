defmodule Mix.Tasks.Maxio.Iam.ListAttachedUserPolicies do
  @shortdoc "List managed policies attached to an IAM user"
  @moduledoc """
  List managed policies attached to an IAM user.

  用法：
      mix maxio.iam.list_attached_user_policies --user USER_OR_ARN [--path-prefix PATH] [--json] [--with-document]
  """
  use Mix.Task

  @usage "usage: mix maxio.iam.list_attached_user_policies --user USER_OR_ARN [--path-prefix PATH] [--json] [--with-document]"
  @switches [user: :string, path_prefix: :string, json: :boolean, with_document: :boolean]

  @impl true
  def run(argv) do
    Mix.Task.run("app.start")
    {opts, args, invalid} = OptionParser.parse(argv, strict: @switches)

    if args != [] or invalid != [] do
      Mix.raise(@usage)
    end

    user = opts[:user] || Mix.raise("--user required")

    policies =
      Maxio.IAM.list_attached_user_policies(
        user,
        path_prefix: Keyword.get(opts, :path_prefix, "/")
      )

    if opts[:json] do
      IO.puts(
        Jason.encode!(%{status: "ok", user: user, policies: render_policies(policies, opts)})
      )
    else
      IO.puts(
        "[maxio iam.list_attached_user_policies] status=ok user=#{inspect(user)} count=#{length(policies)}"
      )

      Enum.each(policies, fn policy ->
        IO.puts(
          "[maxio iam.attached_user_policy] policy_arn=#{inspect(policy.policy_arn)} policy_name=#{inspect(policy.policy_name)} path=#{inspect(policy.path)}"
        )
      end)
    end
  end

  defp render_policies(policies, opts) do
    Enum.map(policies, fn policy ->
      rendered = %{
        user_arn: policy.user_arn,
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
