defmodule Mix.Tasks.Maxio.Admin.Policy.Detach do
  @shortdoc "Atomically detach builtin managed policies from one user or group"
  use Mix.Task

  alias Maxio.Config.CLI
  alias Maxio.IAM
  alias Maxio.S3.Log

  @switches [user: :string, group: :string, json: :boolean]
  @usage "usage: mix maxio.admin.policy.detach POLICY [POLICY ...] (--user NAME | --group NAME) [--json]"

  @impl true
  def run(argv) do
    {opts, policies, invalid} = OptionParser.parse(argv, strict: @switches)

    with true <- invalid == [] and policies != [],
         {:ok, principal} <- principal(opts),
         :ok <- CLI.boot(),
         {:ok, result} <-
           IAM.update_managed_policy_associations_strict(:detach, principal, policies) do
      emit(opts[:json], principal, result)
    else
      false ->
        Mix.raise(@usage)

      {:error, :usage} ->
        Mix.raise(@usage)

      {:error, :policy_change_already_applied} ->
        Mix.raise("policy association change is already applied")

      {:error, reason} ->
        Mix.raise(public_failure(reason))
    end
  end

  defp principal(opts) do
    case {opts[:user], opts[:group]} do
      {user, nil} when is_binary(user) and user != "" -> {:ok, {:user, user}}
      {nil, group} when is_binary(group) and group != "" -> {:ok, {:group, group}}
      _other -> {:error, :usage}
    end
  end

  defp emit(json?, {kind, name}, result) do
    changed = Enum.map(result.changed_policy_arns, &policy_name/1)
    updated_at = DateTime.to_iso8601(result.updated_at)

    Log.info("admin policy association updated from CLI",
      action: "admin_policy_association_detach",
      admin_action: "admin_policy_association_detach",
      principal_kind: kind,
      operation: "detach",
      requested_policy_count: length(changed),
      changed_policy_count: length(changed),
      surface: "cli"
    )

    if json? do
      Mix.shell().info(
        Jason.encode!(%{
          operation: "detach",
          principalKind: to_string(kind),
          principalName: name,
          changedPolicies: changed,
          updatedAt: updated_at
        })
      )
    else
      Mix.shell().info(
        "[maxio admin.policy.detach] principal=#{kind}:#{name} " <>
          "changed=#{Enum.join(changed, ",")} updated_at=#{updated_at}"
      )
    end
  end

  defp policy_name("arn:aws:iam:::policy/" <> name), do: name
  defp public_failure(:user_not_found), do: "admin user not found"
  defp public_failure(:group_not_found), do: "admin group not found"
  defp public_failure(:group_disabled), do: "admin group is disabled"
  defp public_failure(_reason), do: "admin policy detach failed"
end
