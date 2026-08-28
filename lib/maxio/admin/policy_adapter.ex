defmodule Maxio.Admin.PolicyAdapter do
  @moduledoc """
  Root-path MinIO canned-policy projection over the public `Maxio.IAM` facade.

  The adapter never accesses policy storage or Ecto directly. MinIO names are
  validated before they can be interpreted as an IAM path.
  """

  alias Maxio.IAM

  @spec validate_name(term()) :: :ok | {:error, :invalid_argument | :invalid_resource_name}
  def validate_name(name) when is_binary(name) do
    segments = String.split(name, ["/", "\\"], trim: false)

    cond do
      name == "" -> {:error, :invalid_argument}
      String.trim(name) != name -> {:error, :invalid_resource_name}
      String.contains?(name, ",") -> {:error, :invalid_resource_name}
      String.contains?(name, ["/", "\\"]) -> {:error, :invalid_resource_name}
      Enum.any?(segments, &(&1 in [".", ".."])) -> {:error, :invalid_resource_name}
      true -> :ok
    end
  end

  def validate_name(_name), do: {:error, :invalid_argument}

  @spec create(term(), term()) :: {:ok, map()} | {:error, term()}
  def create(name, raw_document) when is_binary(raw_document) do
    with {:ok, arn} <- root_policy_target(name) do
      case IAM.get_managed_policy(arn) do
        {:ok, _policy} ->
          IAM.create_managed_policy_version_strict(arn, raw_document, true)

        :error ->
          case IAM.create_managed_policy_strict(
                 name: name,
                 path: "/",
                 document: raw_document
               ) do
            {:error, :already_exists} ->
              IAM.create_managed_policy_version_strict(arn, raw_document, true)

            result ->
              result
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def create(_name, _raw_document), do: {:error, :malformed_policy_document}

  @spec list() ::
          {:ok,
           %{
             policies: %{String.t() => map()},
             omitted: [%{policy_arn: String.t(), policy_name: String.t(), path: String.t()}]
           }}
  def list do
    {root, omitted} =
      "/"
      |> then(&IAM.list_managed_policies(path_prefix: &1))
      |> Enum.split_with(&(&1.path == "/"))

    policies = Map.new(root, &{&1.policy_name, &1.document})

    omitted =
      Enum.map(omitted, fn policy ->
        %{policy_arn: policy.policy_arn, policy_name: policy.policy_name, path: policy.path}
      end)

    {:ok, %{policies: policies, omitted: omitted}}
  end

  @spec info(term()) :: {:ok, map()} | {:error, term()}
  def info(name) do
    with {:ok, arn} <- root_policy_target(name) do
      case IAM.get_managed_policy(arn) do
        {:ok, policy} ->
          {:ok,
           %{
             "PolicyName" => policy.policy_name,
             "Policy" => policy.document,
             "CreateDate" => policy.inserted_at,
             "UpdateDate" => policy.updated_at
           }}

        :error ->
          {:error, :not_found}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @spec remove(term()) :: :ok | {:error, term()}
  def remove(name) do
    with {:ok, arn} <- root_policy_target(name) do
      case IAM.delete_managed_policy_strict(arn) do
        :ok ->
          :ok

        {:error, :policy_attached} ->
          case IAM.list_managed_policy_entities_strict(arn) do
            {:ok, entities} -> {:error, {:policy_attached, entities}}
            {:error, reason} -> {:error, reason}
          end

        {:error, :policy_has_non_default_versions} ->
          case IAM.list_managed_policy_versions_strict(arn) do
            {:ok, versions} ->
              count = Enum.count(versions, &(not &1.is_default_version))
              {:error, {:policy_has_non_default_versions, count}}

            {:error, reason} ->
              {:error, reason}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp root_policy_target(name) do
    with :ok <- validate_name(name),
         arn = IAM.managed_policy_arn(name, "/"),
         :ok <- IAM.validate_managed_policy_arn(arn) do
      expected_arn = "arn:aws:iam:::policy/" <> name
      resource_name = String.replace_prefix(arn, "arn:aws:iam:::policy/", "")

      if arn == expected_arn and resource_name == name and
           not String.contains?(resource_name, ["/", "\\"]) and
           IAM.managed_policy_arn(resource_name, "/") == arn do
        {:ok, arn}
      else
        {:error, :invalid_resource_name}
      end
    else
      {:error, :malformed} -> {:error, :invalid_resource_name}
      {:error, reason} -> {:error, reason}
    end
  end
end
