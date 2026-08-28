defmodule Maxio.Admin.GroupAdapter do
  @moduledoc """
  Adapts the public IAM group lifecycle facade to MinIO Admin v3 wire values.

  Transactions, identity locking and policy projection remain behind
  `Maxio.IAM`; this module owns only protocol validation and safe wire fields.
  """

  alias Maxio.IAM

  @type reason :: term()

  @spec list() :: {:ok, %{wire: [String.t()], evidence: map()}} | {:error, reason()}
  def list do
    case IAM.list_minio_group_names() do
      {:ok, names} ->
        {:ok, %{wire: names, evidence: %{group_count: length(names), group_names: names}}}

      {:error, reason} ->
        {:error, wire_reason(reason)}
    end
  end

  @spec info(term()) :: {:ok, %{wire: map(), evidence: map()}} | {:error, reason()}
  def info(name) when is_binary(name) and name != "" do
    with {:ok, description} <- map_group_result(IAM.get_minio_group_description_strict(name)),
         {:ok, status} <- wire_status(description.status) do
      wire =
        %{
          "name" => description.group_name,
          "status" => status,
          "members" => description.member_names,
          "policy" => Enum.join(description.managed_policy_names, ",")
        }
        |> put_updated_at(description.updated_at)

      evidence =
        description.evidence
        |> Map.put(:inline_policy_names, description.inline_policy_names)
        |> Map.put(
          :non_root_managed_policy_names,
          description.non_root_managed_policy_names
        )
        |> Map.put(:visible_managed_policy_count, length(description.managed_policy_names))
        |> Map.put(:member_count, length(description.member_names))

      {:ok, %{wire: wire, evidence: evidence}}
    end
  end

  def info(_name), do: {:error, :invalid_argument}

  @spec update_members(map()) :: {:ok, map()} | {:error, reason()}
  def update_members(%{
        group: group,
        members: members,
        group_status: group_status,
        remove?: remove?
      })
      when is_binary(group) and is_list(members) and is_binary(group_status) and
             is_boolean(remove?) do
    case IAM.update_minio_group_members_strict(group, members, remove?, group_status) do
      {:ok, result} ->
        {:ok,
         result
         |> Map.put(:requested_member_count, length(members))
         |> Map.put(:evidence, %{
           group_status: group_status,
           group_status_ignored: result.group_status_ignored?
         })}

      {:error, reason} ->
        {:error, wire_reason(reason)}
    end
  end

  def update_members(_request), do: {:error, :invalid_argument}

  @spec status(term(), term()) :: {:ok, map()} | {:error, reason()}
  def status(group_name, status) when is_binary(group_name) and group_name != "" do
    with {:ok, internal_status} <- mutation_status(status) do
      IAM.update_minio_group_status_strict(group_name, internal_status)
      |> map_group_result()
    end
  end

  def status(_group_name, _status), do: {:error, :invalid_argument}

  defp mutation_status("enabled"), do: {:ok, "active"}
  defp mutation_status("disabled"), do: {:ok, "inactive"}

  defp mutation_status(status) when is_binary(status) and status != "",
    do: {:error, :invalid_status_argument}

  defp mutation_status(_status), do: {:error, :invalid_argument}

  defp wire_status("active"), do: {:ok, "enabled"}
  defp wire_status("inactive"), do: {:ok, "disabled"}
  defp wire_status(_status), do: {:error, :invalid_argument}

  defp put_updated_at(wire, nil), do: wire

  defp put_updated_at(wire, %DateTime{} = updated_at),
    do: Map.put(wire, "updatedAt", DateTime.to_iso8601(updated_at))

  defp map_group_result({:error, reason}), do: {:error, wire_reason(reason)}
  defp map_group_result(result), do: result

  defp wire_reason(:user_not_found), do: :minio_user_not_found
  defp wire_reason(:group_not_found), do: :minio_group_not_found
  defp wire_reason(:identity_changed), do: :minio_group_not_found
  defp wire_reason(:group_not_empty), do: :minio_group_not_empty
  defp wire_reason(:invalid_argument), do: :minio_invalid_argument
  defp wire_reason(reason), do: reason
end
