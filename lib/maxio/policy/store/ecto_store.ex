defmodule Maxio.Policy.Store.EctoStore do
  @moduledoc """
  Postgres 策略后端（实现 Maxio.Policy.Store behaviour）。document 存 jsonb（解析后的 map），
  get 时 Jason.encode! 回放为 JSON 字节（round-trip 语义等价）。principal_policies/1 读取绑定到
  principal ARN 的 identity policy，并与 bucket policy / ACL 一起交给统一 Evaluator。
  """
  @behaviour Maxio.Policy.Store

  import Ecto.Query

  alias Maxio.Repo
  alias Maxio.IAM.RoleManagedPolicyAttachment
  alias Maxio.Policy.{BucketPolicy, ManagedPolicy, PrincipalPolicy, Statement}

  @impl true
  def get_bucket_policy(bucket) do
    case Repo.get_by(BucketPolicy, bucket_name: bucket) do
      nil -> :none
      %BucketPolicy{document: doc} -> {:ok, Jason.encode!(doc)}
    end
  end

  @impl true
  def put_bucket_policy(bucket, json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{} = doc} ->
        %BucketPolicy{}
        |> BucketPolicy.changeset(%{bucket_name: bucket, document: doc})
        |> Repo.insert(
          on_conflict: {:replace, [:document, :updated_at]},
          conflict_target: :bucket_name
        )
        |> case do
          {:ok, _} -> :ok
          {:error, cs} -> {:error, cs}
        end

      _ ->
        {:error, :malformed}
    end
  end

  @impl true
  def delete_bucket_policy(bucket) do
    Repo.delete_all(from p in BucketPolicy, where: p.bucket_name == ^bucket)
    :ok
  end

  @impl true
  def principal_policies(:anonymous), do: []

  def principal_policies(%{arn: principal_arn}) when is_binary(principal_arn) do
    inline_principal_policies(principal_arn) ++
      attached_role_managed_policy_statements(principal_arn)
  end

  def principal_policies(_principal), do: []

  @impl true
  def put_principal_policy(principal_arn, name, json)
      when is_binary(principal_arn) and is_binary(name) and is_binary(json) do
    with {:ok, statements} <- Statement.parse_identity_policy(json),
         true <- statements != [],
         {:ok, %{} = doc} <- Jason.decode(json) do
      %PrincipalPolicy{}
      |> PrincipalPolicy.changeset(%{
        principal_arn: principal_arn,
        policy_name: name,
        document: doc
      })
      |> Repo.insert(
        on_conflict: {:replace, [:document, :updated_at]},
        conflict_target: [:principal_arn, :policy_name]
      )
      |> case do
        {:ok, _} -> :ok
        {:error, cs} -> {:error, cs}
      end
    else
      _ -> {:error, :malformed}
    end
  end

  def put_principal_policy(_principal_arn, _name, _json), do: {:error, :malformed}

  @impl true
  def delete_principal_policy(principal_arn, name)
      when is_binary(principal_arn) and is_binary(name) do
    Repo.delete_all(
      from p in PrincipalPolicy,
        where: p.principal_arn == ^principal_arn and p.policy_name == ^name
    )

    :ok
  end

  def delete_principal_policy(_principal_arn, _name), do: :ok

  @impl true
  def list_principal_policies(principal_arn) when is_binary(principal_arn) do
    from(p in PrincipalPolicy,
      where: p.principal_arn == ^principal_arn,
      order_by: [asc: p.policy_name]
    )
    |> Repo.all()
    |> Enum.map(fn p ->
      %{
        principal_arn: p.principal_arn,
        policy_name: p.policy_name,
        document: p.document
      }
    end)
  end

  def list_principal_policies(_principal_arn), do: []

  @impl true
  def put_managed_session_policy(policy_arn, json)
      when is_binary(policy_arn) and is_binary(json) do
    with {:ok, doc} <- decode_managed_session_policy(json) do
      %ManagedPolicy{}
      |> ManagedPolicy.changeset(%{
        policy_arn: policy_arn,
        document: doc
      })
      |> Repo.insert(
        on_conflict: {:replace, [:document, :updated_at]},
        conflict_target: :policy_arn
      )
      |> case do
        {:ok, _} -> :ok
        {:error, cs} -> {:error, cs}
      end
    else
      _ -> {:error, :malformed}
    end
  end

  def put_managed_session_policy(_policy_arn, _json), do: {:error, :malformed}

  @impl true
  def create_managed_session_policy(policy_arn, json)
      when is_binary(policy_arn) and is_binary(json) do
    with {:ok, doc} <- decode_managed_session_policy(json) do
      %ManagedPolicy{}
      |> ManagedPolicy.changeset(%{
        policy_arn: policy_arn,
        document: doc
      })
      |> Repo.insert()
      |> case do
        {:ok, _} -> :ok
        {:error, %Ecto.Changeset{} = changeset} -> managed_policy_insert_error(changeset)
      end
    else
      _ -> {:error, :malformed}
    end
  end

  def create_managed_session_policy(_policy_arn, _json), do: {:error, :malformed}

  @impl true
  def managed_session_policy(policy_arn) when is_binary(policy_arn) do
    case Repo.get_by(ManagedPolicy, policy_arn: policy_arn) do
      %ManagedPolicy{document: doc} ->
        {:ok, Jason.encode!(doc)}

      nil ->
        {:error, :not_found}
    end
  end

  def managed_session_policy(_policy_arn), do: {:error, :not_found}

  @impl true
  def delete_managed_session_policy(policy_arn) when is_binary(policy_arn) do
    if managed_session_policy_attached?(policy_arn) do
      {:error, :policy_attached}
    else
      Repo.delete_all(from p in ManagedPolicy, where: p.policy_arn == ^policy_arn)
      :ok
    end
  end

  def delete_managed_session_policy(_policy_arn), do: :ok

  @impl true
  def list_managed_session_policies do
    ManagedPolicy
    |> order_by([p], asc: p.policy_arn)
    |> Repo.all()
    |> Enum.map(fn policy ->
      %{
        policy_arn: policy.policy_arn,
        document: policy.document,
        inserted_at: policy.inserted_at,
        updated_at: policy.updated_at
      }
    end)
  end

  @impl true
  def attach_role_managed_policy(role_arn, policy_arn)
      when is_binary(role_arn) and is_binary(policy_arn) do
    %RoleManagedPolicyAttachment{}
    |> RoleManagedPolicyAttachment.changeset(%{role_arn: role_arn, policy_arn: policy_arn})
    |> Repo.insert(
      on_conflict: :nothing,
      conflict_target: [:role_arn, :policy_arn]
    )
    |> case do
      {:ok, _attachment} -> :ok
      {:error, %Ecto.Changeset{} = changeset} -> role_attachment_error(changeset)
    end
  end

  def attach_role_managed_policy(_role_arn, _policy_arn), do: {:error, :malformed}

  @impl true
  def detach_role_managed_policy(role_arn, policy_arn)
      when is_binary(role_arn) and is_binary(policy_arn) do
    Repo.delete_all(
      from a in RoleManagedPolicyAttachment,
        where: a.role_arn == ^role_arn and a.policy_arn == ^policy_arn
    )

    :ok
  end

  def detach_role_managed_policy(_role_arn, _policy_arn), do: :ok

  @impl true
  def list_attached_role_managed_policies(role_arn) when is_binary(role_arn) do
    from(a in RoleManagedPolicyAttachment,
      join: p in ManagedPolicy,
      on: p.policy_arn == a.policy_arn,
      where: a.role_arn == ^role_arn,
      order_by: [asc: p.policy_arn],
      select: %{
        role_arn: a.role_arn,
        policy_arn: p.policy_arn,
        document: p.document,
        inserted_at: a.inserted_at,
        updated_at: a.updated_at
      }
    )
    |> Repo.all()
  end

  def list_attached_role_managed_policies(_role_arn), do: []

  @impl true
  def managed_session_policy_attached?(policy_arn) when is_binary(policy_arn) do
    Repo.exists?(from a in RoleManagedPolicyAttachment, where: a.policy_arn == ^policy_arn)
  end

  def managed_session_policy_attached?(_policy_arn), do: false

  defp inline_principal_policies(principal_arn) do
    from(p in PrincipalPolicy,
      where: p.principal_arn == ^principal_arn,
      order_by: [asc: p.policy_name]
    )
    |> Repo.all()
    |> Enum.flat_map(fn %PrincipalPolicy{document: doc, policy_name: name} ->
      parse_stored_identity_policy(doc,
        principal_arn: principal_arn,
        policy_name: name,
        source: "principal_policy"
      )
    end)
  end

  defp attached_role_managed_policy_statements(role_arn) do
    from(a in RoleManagedPolicyAttachment,
      join: p in ManagedPolicy,
      on: p.policy_arn == a.policy_arn,
      where: a.role_arn == ^role_arn,
      order_by: [asc: p.policy_arn],
      select: {p.policy_arn, p.document}
    )
    |> Repo.all()
    |> Enum.flat_map(fn {policy_arn, doc} ->
      parse_stored_identity_policy(doc,
        principal_arn: role_arn,
        policy_name: policy_arn,
        source: "role_managed_policy"
      )
    end)
  end

  defp parse_stored_identity_policy(doc, log_metadata) do
    doc
    |> Jason.encode!()
    |> Statement.parse_identity_policy()
    |> case do
      {:ok, statements} ->
        statements

      {:error, _} ->
        require Logger
        Logger.warning("stored identity policy failed to parse", log_metadata)
        []
    end
  end

  defp decode_managed_session_policy(json) do
    with {:ok, statements} <- Statement.parse_identity_policy(json),
         true <- statements != [],
         {:ok, %{} = doc} <- Jason.decode(json) do
      {:ok, doc}
    else
      _ -> {:error, :malformed}
    end
  end

  defp managed_policy_insert_error(%Ecto.Changeset{} = changeset) do
    if unique_policy_arn_error?(changeset) do
      {:error, :already_exists}
    else
      {:error, changeset}
    end
  end

  defp unique_policy_arn_error?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {:policy_arn, {_message, opts}} ->
        Keyword.get(opts, :constraint) == :unique

      _other ->
        false
    end)
  end

  defp role_attachment_error(%Ecto.Changeset{} = changeset) do
    cond do
      foreign_key_error?(changeset, :role_arn) -> {:error, :role_not_found}
      foreign_key_error?(changeset, :policy_arn) -> {:error, :policy_not_found}
      true -> {:error, changeset}
    end
  end

  defp foreign_key_error?(%Ecto.Changeset{errors: errors}, field) do
    Enum.any?(errors, fn
      {^field, {_message, opts}} ->
        Keyword.get(opts, :constraint) == :foreign

      _other ->
        false
    end)
  end
end
