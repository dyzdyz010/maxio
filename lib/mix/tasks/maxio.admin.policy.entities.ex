defmodule Mix.Tasks.Maxio.Admin.Policy.Entities do
  @shortdoc "Inspect builtin policy association mappings"
  use Mix.Task

  alias Maxio.Config.CLI
  alias Maxio.IAM
  alias Maxio.S3.Log

  @switches [user: :keep, group: :keep, policy: :keep, json: :boolean]
  @usage "usage: mix maxio.admin.policy.entities [--user NAME] [--group NAME] [--policy NAME] [--json]"

  @impl true
  def run(argv) do
    {opts, args, invalid} = OptionParser.parse(argv, strict: @switches)

    if args != [] or invalid != [] do
      Mix.raise(@usage)
    end

    users = normalize(Keyword.get_values(opts, :user))
    groups = normalize(Keyword.get_values(opts, :group))
    policies = normalize(Keyword.get_values(opts, :policy))
    requested = requested_dimensions(opts)

    filters = %{
      users: users,
      groups: groups,
      policy_arns: Enum.map(policies, &IAM.managed_policy_arn(&1, "/")),
      requested: requested
    }

    with :ok <- CLI.boot(),
         {:ok, projection} <- IAM.query_builtin_policy_entities(filters) do
      result = project(projection)

      Log.info("admin policy entities inspected from CLI",
        action: "admin_policy_entities",
        admin_action: "admin_policy_entities",
        requested_user_count: length(users),
        requested_group_count: length(groups),
        requested_policy_count: length(policies),
        user_mapping_count: length(projection.user_mappings),
        group_mapping_count: length(projection.group_mappings),
        policy_mapping_count: length(projection.policy_mappings),
        surface: "cli"
      )

      if opts[:json] do
        Mix.shell().info(
          Jason.encode!(%{
            requested: %{users: users, groups: groups, policies: policies},
            result: result
          })
        )
      else
        Mix.shell().info(
          "[maxio admin.policy.entities] users=#{length(projection.user_mappings)} " <>
            "groups=#{length(projection.group_mappings)} " <>
            "policies=#{length(projection.policy_mappings)} timestamp=#{result["timestamp"]}"
        )
      end
    else
      {:error, _reason} -> Mix.raise("admin policy entities query failed")
    end
  end

  defp normalize(values), do: values |> Enum.filter(&(&1 != "")) |> Enum.uniq() |> Enum.sort()

  defp requested_dimensions(opts) do
    [:user, :group, :policy]
    |> Enum.filter(&Keyword.has_key?(opts, &1))
    |> MapSet.new()
  end

  defp project(projection) do
    %{"timestamp" => DateTime.to_iso8601(projection.timestamp)}
    |> maybe_put("userMappings", Enum.map(projection.user_mappings, &project_user/1))
    |> maybe_put("groupMappings", Enum.map(projection.group_mappings, &project_group/1))
    |> maybe_put("policyMappings", Enum.map(projection.policy_mappings, &project_policy/1))
  end

  defp project_user(mapping) do
    %{"user" => mapping.user, "policies" => policy_names_or_nil(mapping.policy_arns)}
    |> maybe_put(
      "memberOfMappings",
      Enum.map(mapping.member_of_mappings, fn inherited ->
        %{"group" => inherited.group, "policies" => policy_names_or_nil(inherited.policy_arns)}
      end)
    )
  end

  defp project_group(mapping),
    do: %{"group" => mapping.group, "policies" => policy_names_or_nil(mapping.policy_arns)}

  defp project_policy(mapping),
    do: %{
      "policy" => policy_name(mapping.policy_arn),
      "users" => empty_to_nil(mapping.users),
      "groups" => empty_to_nil(mapping.groups)
    }

  defp policy_names_or_nil([]), do: nil
  defp policy_names_or_nil(arns), do: Enum.map(arns, &policy_name/1)
  defp policy_name("arn:aws:iam:::policy/" <> name), do: name
  defp empty_to_nil([]), do: nil
  defp empty_to_nil(values), do: values
  defp maybe_put(map, _key, []), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
