defmodule Maxio.Admin.UserAdapter do
  @moduledoc """
  Projects maxio IAM users into the deliberately partial MinIO UserInfo view.

  The adapter calls only the public `Maxio.IAM` facade. Policy documents and
  credential material are reduced to safe names, ARNs, and counts before any
  result leaves this module.
  """

  alias Maxio.IAM

  @user_name_pattern ~r/\A[A-Za-z0-9+=.@_-]{1,64}\z/
  @access_key_pattern ~r/\A[A-Za-z0-9+.@_-]{3,64}\z/

  @type reason :: :invalid_argument | :invalid_resource_name | :user_not_found | term()

  @spec validate_name(term()) :: :ok | {:error, :invalid_argument | :invalid_resource_name}
  def validate_name(name) when is_binary(name) do
    cond do
      name == "" ->
        {:error, :invalid_argument}

      String.trim(name) != name or String.contains?(name, ",") ->
        {:error, :invalid_resource_name}

      byte_size(name) > 64 or not Regex.match?(@user_name_pattern, name) ->
        {:error, :invalid_argument}

      true ->
        :ok
    end
  end

  def validate_name(_name), do: {:error, :invalid_argument}

  @spec add(term(), map()) :: {:ok, map()} | {:error, reason()}
  def add(access_key, request) do
    with :ok <- validate_access_key(access_key),
         {:ok, secret_key} <- validate_add_request(request),
         {:ok, result} <- IAM.create_minio_user_strict(access_key, secret_key, "active") do
      {:ok, result}
    end
  end

  @spec list() :: {:ok, %{wire: %{String.t() => map()}, evidence: map()}} | {:error, reason()}
  def list do
    IAM.list_users()
    |> Enum.reduce_while({:ok, %{wire: %{}, projections: []}}, fn user, {:ok, acc} ->
      case project_fetched_user(user) do
        {:ok, projection} ->
          next = %{
            wire: Map.put(acc.wire, user.user_name, projection.wire),
            projections: [{user.user_name, projection.evidence} | acc.projections]
          }

          {:cont, {:ok, next}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, %{wire: wire, projections: projections}} ->
        {:ok, %{wire: wire, evidence: list_evidence(projections)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec info(term()) :: {:ok, %{wire: map(), evidence: map()}} | {:error, reason()}
  def info(name) do
    with :ok <- validate_name(name),
         {:ok, user} <- fetch_user(name) do
      project_fetched_user(user)
    end
  end

  @doc false
  @spec project_fetched_user(map()) ::
          {:ok, %{wire: map(), evidence: map()}} | {:error, reason()}
  def project_fetched_user(%{} = user) do
    with {:ok, sources} <- collect_sources(user) do
      project(user, sources)
    end
  end

  def project_fetched_user(_user), do: {:error, :invalid_argument}

  @doc false
  @spec project(map(), map()) ::
          {:ok, %{wire: map(), evidence: map()}} | {:error, :invalid_argument}
  def project(%{} = user, %{} = sources) do
    with {:ok, status} <- wire_status(Map.get(user, :status)),
         {:ok, updated_at} <- wire_updated_at(Map.get(user, :updated_at)) do
      direct_managed = managed_source(Map.get(sources, :direct_managed, []))
      visible_names = Enum.reject(direct_managed.names, &String.contains?(&1, ","))
      omitted_names = direct_managed.names -- visible_names
      group_names = group_names(Map.get(sources, :groups, []))
      direct_inline = inline_source(Map.get(sources, :direct_inline, []))
      group_inline = group_inline_source(Map.get(sources, :groups, []))
      group_managed = group_managed_source(Map.get(sources, :groups, []))
      role_managed = managed_source(Map.get(sources, :role_managed, []))

      omitted_reason =
        [
          {omitted_names != [], "ambiguous_direct_managed_policy_name"},
          {direct_inline.count > 0, "direct_inline_policy"},
          {group_inline.count > 0, "group_inline_policy"},
          {group_managed.count > 0, "group_managed_policy"},
          {role_managed.count > 0, "role_managed_policy"}
        ]
        |> Enum.flat_map(fn
          {true, reason} -> [reason]
          {false, _reason} -> []
        end)

      evidence = %{
        credential_bearing: Map.get(sources, :credential_bearing, false) == true,
        direct_managed:
          direct_managed
          |> Map.put(:visible_names, visible_names)
          |> Map.put(:omitted_names, omitted_names),
        direct_inline: direct_inline,
        group_inline: group_inline,
        group_managed: group_managed,
        role_managed: role_managed,
        minio_view_partial: omitted_reason != [],
        omitted_reason: omitted_reason
      }

      wire =
        %{"status" => status}
        |> put_when_present("policyName", join_names(visible_names))
        |> put_when_present("memberOf", group_names)
        |> put_when_present("updatedAt", updated_at)

      {:ok, %{wire: wire, evidence: evidence}}
    end
  end

  def project(_user, _sources), do: {:error, :invalid_argument}

  defp validate_access_key(access_key) when is_binary(access_key) do
    if Regex.match?(@access_key_pattern, access_key) do
      :ok
    else
      {:error, :invalid_access_key}
    end
  end

  defp validate_access_key(_access_key), do: {:error, :invalid_access_key}

  defp validate_add_request(%{secret_key: secret_key, policy: "", status: "enabled"})
       when is_binary(secret_key) do
    if byte_size(secret_key) >= 8 do
      {:ok, secret_key}
    else
      {:error, :invalid_secret_key}
    end
  end

  defp validate_add_request(%{secret_key: secret_key})
       when not is_binary(secret_key) or byte_size(secret_key) < 8,
       do: {:error, :invalid_secret_key}

  defp validate_add_request(_request), do: {:error, :config_bad_json}

  defp list_evidence(projections) do
    entries = Enum.reverse(projections)

    %{
      user_count: length(entries),
      user_names: entries |> Enum.map(&elem(&1, 0)) |> Enum.sort(),
      credential_bearing_count: count_evidence(entries, & &1.credential_bearing),
      managed_policies: sum_evidence(entries, & &1.direct_managed.count),
      inline_policies: sum_evidence(entries, & &1.direct_inline.count),
      group_inherited: sum_evidence(entries, &(&1.group_inline.count + &1.group_managed.count)),
      role_attached: sum_evidence(entries, & &1.role_managed.count),
      minio_view_partial_count: count_evidence(entries, & &1.minio_view_partial),
      omitted_reason:
        entries
        |> Enum.flat_map(fn {_name, evidence} -> evidence.omitted_reason end)
        |> Enum.uniq()
        |> Enum.sort()
    }
  end

  defp count_evidence(entries, predicate) do
    Enum.count(entries, fn {_name, evidence} -> predicate.(evidence) end)
  end

  defp sum_evidence(entries, mapper) do
    Enum.reduce(entries, 0, fn {_name, evidence}, total -> total + mapper.(evidence) end)
  end

  defp fetch_user(name) do
    case IAM.get_user(name) do
      {:ok, user} -> {:ok, user}
      :error -> {:error, :user_not_found}
    end
  end

  defp collect_sources(user) do
    with {:ok, keys} <- IAM.list_access_keys_strict(user.user_name) do
      groups =
        user.user_name
        |> IAM.list_groups_for_user()
        |> Enum.map(fn group ->
          group_name = Map.get(group, :group_name)

          %{
            group_name: group_name,
            inline: safe_inline_policies(IAM.list_group_policies(group_name)),
            managed: safe_managed_policies(IAM.list_attached_group_policies(group_name))
          }
        end)

      {:ok,
       %{
         credential_bearing: Enum.any?(keys, &(Map.get(&1, :access_key_id) == user.user_name)),
         direct_managed:
           user.user_name
           |> IAM.list_attached_user_policies()
           |> safe_managed_policies(),
         direct_inline:
           user.user_arn
           |> IAM.list_principal_policies()
           |> safe_inline_policies(),
         groups: groups,
         role_managed:
           user.user_arn
           |> IAM.list_attached_role_policies()
           |> safe_managed_policies()
       }}
    else
      {:error, :not_found} -> {:error, :user_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp safe_inline_policies(policies) do
    policies
    |> Enum.flat_map(fn policy ->
      case Map.get(policy, :policy_name) do
        name when is_binary(name) -> [%{policy_name: name}]
        _other -> []
      end
    end)
  end

  defp safe_managed_policies(policies) do
    policies
    |> Enum.flat_map(fn policy ->
      case {Map.get(policy, :policy_name), Map.get(policy, :policy_arn)} do
        {name, arn} when is_binary(name) and is_binary(arn) ->
          [%{policy_name: name, policy_arn: arn}]

        _other ->
          []
      end
    end)
  end

  defp wire_status("active"), do: {:ok, "enabled"}
  defp wire_status("inactive"), do: {:ok, "disabled"}
  defp wire_status(_status), do: {:error, :invalid_argument}

  defp wire_updated_at(nil), do: {:ok, nil}
  defp wire_updated_at(%DateTime{} = updated_at), do: {:ok, DateTime.to_iso8601(updated_at)}
  defp wire_updated_at(_updated_at), do: {:error, :invalid_argument}

  defp managed_source(policies) do
    entries =
      policies
      |> safe_managed_policies()
      |> Enum.uniq()
      |> Enum.sort_by(&{&1.policy_name, &1.policy_arn})

    %{
      count: length(entries),
      names: entries |> Enum.map(& &1.policy_name) |> Enum.uniq(),
      arns: entries |> Enum.map(& &1.policy_arn) |> Enum.uniq() |> Enum.sort()
    }
  end

  defp inline_source(policies) do
    names =
      policies
      |> safe_inline_policies()
      |> Enum.map(& &1.policy_name)
      |> Enum.uniq()
      |> Enum.sort()

    %{count: length(names), names: names}
  end

  defp group_names(groups) do
    groups
    |> Enum.flat_map(fn group ->
      case Map.get(group, :group_name) do
        name when is_binary(name) -> [name]
        _other -> []
      end
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp group_inline_source(groups) do
    names =
      groups
      |> Enum.flat_map(fn group ->
        group_name = Map.get(group, :group_name)

        group
        |> Map.get(:inline, [])
        |> safe_inline_policies()
        |> Enum.map(&"#{group_name}/#{&1.policy_name}")
      end)
      |> Enum.uniq()
      |> Enum.sort()

    %{count: length(names), names: names}
  end

  defp group_managed_source(groups) do
    entries =
      groups
      |> Enum.flat_map(fn group ->
        group_name = Map.get(group, :group_name)

        group
        |> Map.get(:managed, [])
        |> safe_managed_policies()
        |> Enum.map(&%{name: "#{group_name}/#{&1.policy_name}", arn: &1.policy_arn})
      end)
      |> Enum.uniq()
      |> Enum.sort_by(&{&1.name, &1.arn})

    %{
      count: length(entries),
      names: Enum.map(entries, & &1.name),
      arns: entries |> Enum.map(& &1.arn) |> Enum.uniq() |> Enum.sort()
    }
  end

  defp join_names([]), do: nil
  defp join_names(names), do: Enum.join(names, ",")

  defp put_when_present(map, _key, nil), do: map
  defp put_when_present(map, _key, []), do: map
  defp put_when_present(map, key, value), do: Map.put(map, key, value)
end
