defmodule Maxio.Admin.ErrorMap do
  @moduledoc """
  Maps IAM and policy-adapter failures to the MinIO admin JSON error contract.

  Unknown reasons are deliberately redacted. Entity-bearing delete conflicts
  project only stable public names and never serialize the underlying records.
  """

  alias Maxio.S3.Error

  @spec from_reason(term()) :: Error.t()
  def from_reason(reason) when reason in [:not_found, :policy_not_found],
    do: Error.new(:admin_no_such_policy)

  def from_reason(reason) when reason in [:invalid_argument, :malformed, :already_exists],
    do: Error.new(:admin_invalid_argument)

  def from_reason(:invalid_resource_name),
    do: Error.new(:admin_resource_invalid_argument)

  def from_reason(:malformed_policy_document),
    do: Error.new(:malformed_policy_wire)

  def from_reason(:policy_limit_exceeded) do
    Error.new(:admin_invalid_argument,
      message:
        "The managed policy quota was exceeded. Reduce the policy document to 6,144 " <>
          "characters or delete an unused managed policy before retrying."
    )
  end

  def from_reason(:policy_version_limit_exceeded) do
    Error.new(:admin_invalid_argument,
      message:
        "The policy already has the 5 allowed versions. Delete a non-default version with " <>
          "DeletePolicyVersion before creating another version."
    )
  end

  def from_reason({:policy_attached, entities}) do
    Error.new(:admin_invalid_argument, message: attached_message(entities))
  end

  def from_reason({:policy_has_non_default_versions, count}) do
    Error.new(:admin_invalid_argument,
      message:
        "The policy has #{count} non-default version(s). Delete them with " <>
          "DeletePolicyVersion before removing the policy."
    )
  end

  def from_reason(_reason), do: Error.new(:internal_error)

  defp attached_message(entities) when is_map(entities) do
    targets =
      [
        named_targets(entities, :users, :user_name, "users"),
        named_targets(entities, :groups, :group_name, "groups"),
        named_targets(entities, :roles, :role_name, "roles")
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("; ")

    suffix = if targets == "", do: "attached entities", else: targets
    "The policy is attached to #{suffix}; detach it from every entity before removing it."
  end

  defp attached_message(_entities) do
    "The policy is attached to one or more entities; detach it before removing it."
  end

  defp named_targets(entities, collection_key, name_key, label) do
    names =
      entities
      |> Map.get(collection_key, [])
      |> Enum.flat_map(fn
        entity when is_map(entity) ->
          case Map.get(entity, name_key) do
            name when is_binary(name) -> [name]
            _other -> []
          end

        _other ->
          []
      end)
      |> Enum.uniq()
      |> Enum.sort()

    if names == [], do: nil, else: "#{label} [#{Enum.join(names, ", ")}]"
  end
end
