defmodule Maxio.Policy.Store.EctoStore do
  @moduledoc """
  Postgres 策略后端（实现 Maxio.Policy.Store behaviour）。document 存 jsonb（解析后的 map），
  get 时 Jason.encode! 回放为 JSON 字节（round-trip 语义等价）。principal_policies/1 读取绑定到
  principal ARN 的 identity policy，并与 bucket policy / ACL 一起交给统一 Evaluator。
  """
  @behaviour Maxio.Policy.Store

  import Ecto.Query

  alias Maxio.Repo

  alias Maxio.IAM.{
    Group,
    GroupManagedPolicyAttachment,
    GroupMembership,
    Role,
    RoleManagedPolicyAttachment,
    User,
    UserManagedPolicyAttachment
  }

  alias Maxio.Policy.{
    BucketPolicy,
    ManagedPolicy,
    ManagedPolicyVersion,
    PrincipalPolicy,
    Statement
  }

  alias Maxio.Tags

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

  def principal_policies(%{arn: "arn:aws:iam:::group/" <> _}), do: []

  def principal_policies(%{arn: principal_arn}) when is_binary(principal_arn) do
    if inactive_explicit_user?(principal_arn) do
      []
    else
      inline_principal_policies(principal_arn) ++
        attached_user_managed_policy_statements(principal_arn) ++
        inherited_group_policy_statements(principal_arn) ++
        inherited_group_managed_policy_statements(principal_arn) ++
        attached_role_managed_policy_statements(principal_arn)
    end
  end

  def principal_policies(_principal), do: []

  @impl true
  def principal_permissions_boundary(:anonymous), do: :none

  def principal_permissions_boundary(%{arn: principal_arn}) when is_binary(principal_arn) do
    with {:ok, policy_arn} <- principal_permissions_boundary_policy_arn(principal_arn) do
      policy_arn
      |> boundary_policy_document()
      |> boundary_policy_statements(principal_arn, policy_arn)
    end
  end

  def principal_permissions_boundary(_principal), do: :none

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
  def get_principal_policy(principal_arn, name)
      when is_binary(principal_arn) and is_binary(name) do
    case Repo.get_by(PrincipalPolicy, principal_arn: principal_arn, policy_name: name) do
      %PrincipalPolicy{} = policy ->
        {:ok,
         %{
           principal_arn: policy.principal_arn,
           policy_name: policy.policy_name,
           document: policy.document
         }}

      nil ->
        {:error, :not_found}
    end
  end

  def get_principal_policy(_principal_arn, _name), do: {:error, :malformed}

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
      Repo.transaction(fn ->
        with {:ok, policy} <- upsert_managed_policy_row(policy_arn, doc, %{}),
             :ok <- reset_managed_policy_versions(policy, doc) do
          :ok
        else
          {:error, reason} -> Repo.rollback({:error, reason})
        end
      end)
      |> case do
        {:ok, :ok} -> :ok
        {:error, {:error, reason}} -> {:error, reason}
        {:error, reason} -> {:error, reason}
      end
    else
      _ -> {:error, :malformed}
    end
  end

  def put_managed_session_policy(_policy_arn, _json), do: {:error, :malformed}

  @impl true
  def create_managed_session_policy(policy_arn, json),
    do: create_managed_session_policy(policy_arn, json, %{})

  @impl true
  def create_managed_session_policy(policy_arn, json, attrs)
      when is_binary(policy_arn) and is_binary(json) and is_map(attrs) do
    with {:ok, doc} <- decode_managed_session_policy(json) do
      Repo.transaction(fn ->
        with {:ok, policy} <- insert_managed_policy_row(policy_arn, doc, attrs),
             {:ok, _version} <- insert_managed_policy_version(policy, "v1", doc, true) do
          :ok
        else
          {:error, reason} -> Repo.rollback({:error, reason})
        end
      end)
      |> case do
        {:ok, :ok} ->
          :ok

        {:error, {:error, %Ecto.Changeset{} = changeset}} ->
          managed_policy_insert_error(changeset)

        {:error, {:error, reason}} ->
          {:error, reason}

        {:error, reason} ->
          {:error, reason}
      end
    else
      _ -> {:error, :malformed}
    end
  end

  def create_managed_session_policy(_policy_arn, _json, _attrs), do: {:error, :malformed}

  @impl true
  def managed_session_policy(policy_arn) when is_binary(policy_arn) do
    case Repo.get_by(ManagedPolicy, policy_arn: policy_arn) do
      %ManagedPolicy{} = policy ->
        {:ok, Jason.encode!(default_managed_policy_document(policy))}

      nil ->
        {:error, :not_found}
    end
  end

  def managed_session_policy(_policy_arn), do: {:error, :not_found}

  @impl true
  def delete_managed_session_policy(policy_arn) when is_binary(policy_arn) do
    Repo.transaction(fn ->
      case Repo.one(
             from p in ManagedPolicy, where: p.policy_arn == ^policy_arn, lock: "FOR UPDATE"
           ) do
        %ManagedPolicy{} = policy ->
          cond do
            managed_session_policy_attached?(policy_arn) ->
              Repo.rollback({:error, :policy_attached})

            managed_policy_non_default_version_count(policy) > 0 ->
              Repo.rollback({:error, :policy_has_non_default_versions})

            true ->
              case Repo.delete(policy) do
                {:ok, _policy} -> :ok
                {:error, %Ecto.Changeset{} = changeset} -> Repo.rollback({:error, changeset})
              end
          end

        nil ->
          :ok
      end
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
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
        document: default_managed_policy_document(policy),
        default_version_id: default_managed_policy_version_id(policy),
        description: policy.description || "",
        tags: policy.tags || %{},
        inserted_at: policy.inserted_at,
        updated_at: policy.updated_at
      }
    end)
  end

  @impl true
  def create_managed_session_policy_version(policy_arn, json, set_as_default)
      when is_binary(policy_arn) and is_binary(json) and is_boolean(set_as_default) do
    with {:ok, doc} <- decode_managed_session_policy(json) do
      Repo.transaction(fn ->
        with %ManagedPolicy{} = policy <- locked_managed_policy(policy_arn),
             :ok <- ensure_managed_policy_versions(policy),
             :ok <- ensure_managed_policy_version_capacity(policy),
             version_id <- next_managed_policy_version_id(policy),
             {:ok, version} <- insert_managed_policy_version(policy, version_id, doc, false),
             {:ok, policy} <-
               increment_managed_policy_version_counter(policy, doc, set_as_default),
             :ok <- maybe_set_default_managed_policy_version(policy, version, set_as_default) do
          version = if set_as_default, do: %{version | is_default: true}, else: version
          managed_policy_version_map(policy, version)
        else
          nil -> Repo.rollback({:error, :not_found})
          {:error, reason} -> Repo.rollback({:error, reason})
        end
      end)
      |> case do
        {:ok, version} -> {:ok, version}
        {:error, {:error, reason}} -> {:error, reason}
        {:error, reason} -> {:error, reason}
      end
    else
      _ -> {:error, :malformed}
    end
  end

  def create_managed_session_policy_version(_policy_arn, _json, _set_as_default),
    do: {:error, :malformed}

  @impl true
  def get_managed_session_policy_version(policy_arn, version_id)
      when is_binary(policy_arn) and is_binary(version_id) do
    with %ManagedPolicy{} = policy <- Repo.get_by(ManagedPolicy, policy_arn: policy_arn),
         %ManagedPolicyVersion{} = version <-
           Repo.get_by(ManagedPolicyVersion,
             managed_policy_id: policy.id,
             version_id: version_id
           ) do
      {:ok, managed_policy_version_map(policy, version)}
    else
      nil -> {:error, :not_found}
    end
  end

  def get_managed_session_policy_version(_policy_arn, _version_id), do: {:error, :not_found}

  @impl true
  def list_managed_session_policy_versions(policy_arn) when is_binary(policy_arn) do
    case Repo.get_by(ManagedPolicy, policy_arn: policy_arn) do
      %ManagedPolicy{} = policy ->
        versions =
          from(v in ManagedPolicyVersion,
            where: v.managed_policy_id == ^policy.id
          )
          |> Repo.all()
          |> Enum.sort_by(&managed_policy_version_sort_key/1)
          |> Enum.map(&managed_policy_version_map(policy, &1))

        {:ok, versions}

      nil ->
        {:error, :not_found}
    end
  end

  def list_managed_session_policy_versions(_policy_arn), do: {:error, :not_found}

  @impl true
  def set_default_managed_session_policy_version(policy_arn, version_id)
      when is_binary(policy_arn) and is_binary(version_id) do
    Repo.transaction(fn ->
      with %ManagedPolicy{} = policy <- locked_managed_policy(policy_arn),
           :ok <- ensure_managed_policy_versions(policy),
           %ManagedPolicyVersion{} = version <-
             Repo.get_by(ManagedPolicyVersion,
               managed_policy_id: policy.id,
               version_id: version_id
             ),
           :ok <- set_default_managed_policy_version_rows(policy, version) do
        :ok
      else
        nil -> Repo.rollback({:error, :not_found})
        {:error, reason} -> Repo.rollback({:error, reason})
      end
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  def set_default_managed_session_policy_version(_policy_arn, _version_id),
    do: {:error, :not_found}

  @impl true
  def delete_managed_session_policy_version(policy_arn, version_id)
      when is_binary(policy_arn) and is_binary(version_id) do
    Repo.transaction(fn ->
      with %ManagedPolicy{} = policy <- locked_managed_policy(policy_arn),
           :ok <- ensure_managed_policy_versions(policy),
           %ManagedPolicyVersion{} = version <-
             Repo.get_by(ManagedPolicyVersion,
               managed_policy_id: policy.id,
               version_id: version_id
             ),
           false <- version.is_default,
           {:ok, _version} <- Repo.delete(version) do
        :ok
      else
        nil -> Repo.rollback({:error, :not_found})
        true -> Repo.rollback({:error, :default_policy_version})
        {:error, reason} -> Repo.rollback({:error, reason})
      end
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  def delete_managed_session_policy_version(_policy_arn, _version_id),
    do: {:error, :not_found}

  @impl true
  def tag_managed_session_policy(policy_arn, tags)
      when is_binary(policy_arn) and is_map(tags) do
    tags = normalize_tags(tags)

    with :ok <- Tags.validate(Tags.map_to_list(tags), :bucket) do
      update_managed_session_policy_tags(policy_arn, fn existing_tags ->
        Map.merge(existing_tags, tags)
      end)
    end
  end

  def tag_managed_session_policy(_policy_arn, _tags), do: {:error, :invalid_tag}

  @impl true
  def untag_managed_session_policy(policy_arn, tag_keys)
      when is_binary(policy_arn) and is_list(tag_keys) do
    drop_keys = tag_keys |> Enum.map(&to_string/1) |> MapSet.new()

    update_managed_session_policy_tags(policy_arn, fn existing_tags ->
      existing_tags
      |> Enum.reject(fn {key, _value} -> MapSet.member?(drop_keys, key) end)
      |> Map.new()
    end)
  end

  def untag_managed_session_policy(_policy_arn, _tag_keys), do: {:error, :invalid_tag}

  @impl true
  def list_managed_session_policy_entities(policy_arn) when is_binary(policy_arn) do
    %{
      users: managed_policy_users(policy_arn),
      groups: managed_policy_groups(policy_arn),
      roles: managed_policy_roles(policy_arn)
    }
  end

  def list_managed_session_policy_entities(_policy_arn), do: %{users: [], groups: [], roles: []}

  @impl true
  def list_managed_session_policy_permissions_boundary_entities(policy_arn)
      when is_binary(policy_arn) do
    %{
      users: managed_policy_boundary_users(policy_arn),
      groups: [],
      roles: managed_policy_boundary_roles(policy_arn)
    }
  end

  def list_managed_session_policy_permissions_boundary_entities(_policy_arn),
    do: %{users: [], groups: [], roles: []}

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
    Repo.exists?(from a in RoleManagedPolicyAttachment, where: a.policy_arn == ^policy_arn) or
      Repo.exists?(from a in UserManagedPolicyAttachment, where: a.policy_arn == ^policy_arn) or
      Repo.exists?(from a in GroupManagedPolicyAttachment, where: a.policy_arn == ^policy_arn) or
      managed_session_policy_permissions_boundary_count(policy_arn) > 0
  end

  def managed_session_policy_attached?(_policy_arn), do: false

  @impl true
  def managed_session_policy_attachment_count(policy_arn) when is_binary(policy_arn) do
    role_count =
      Repo.aggregate(
        from(a in RoleManagedPolicyAttachment, where: a.policy_arn == ^policy_arn),
        :count
      )

    user_count =
      Repo.aggregate(
        from(a in UserManagedPolicyAttachment, where: a.policy_arn == ^policy_arn),
        :count
      )

    group_count =
      Repo.aggregate(
        from(a in GroupManagedPolicyAttachment, where: a.policy_arn == ^policy_arn),
        :count
      )

    role_count + user_count + group_count
  end

  def managed_session_policy_attachment_count(_policy_arn), do: 0

  @impl true
  def managed_session_policy_permissions_boundary_count(policy_arn) when is_binary(policy_arn) do
    user_count =
      Repo.aggregate(
        from(u in User, where: u.permissions_boundary_policy_arn == ^policy_arn),
        :count
      )

    role_count =
      Repo.aggregate(
        from(r in Role, where: r.permissions_boundary_policy_arn == ^policy_arn),
        :count
      )

    user_count + role_count
  end

  def managed_session_policy_permissions_boundary_count(_policy_arn), do: 0

  @impl true
  def attach_user_managed_policy(user_arn, policy_arn)
      when is_binary(user_arn) and is_binary(policy_arn) do
    %UserManagedPolicyAttachment{}
    |> UserManagedPolicyAttachment.changeset(%{user_arn: user_arn, policy_arn: policy_arn})
    |> Repo.insert(
      on_conflict: :nothing,
      conflict_target: [:user_arn, :policy_arn]
    )
    |> case do
      {:ok, _attachment} -> :ok
      {:error, %Ecto.Changeset{} = changeset} -> user_attachment_error(changeset)
    end
  end

  def attach_user_managed_policy(_user_arn, _policy_arn), do: {:error, :malformed}

  @impl true
  def detach_user_managed_policy(user_arn, policy_arn)
      when is_binary(user_arn) and is_binary(policy_arn) do
    Repo.delete_all(
      from a in UserManagedPolicyAttachment,
        where: a.user_arn == ^user_arn and a.policy_arn == ^policy_arn
    )

    :ok
  end

  def detach_user_managed_policy(_user_arn, _policy_arn), do: :ok

  @impl true
  def list_attached_user_managed_policies(user_arn) when is_binary(user_arn) do
    from(a in UserManagedPolicyAttachment,
      join: p in ManagedPolicy,
      on: p.policy_arn == a.policy_arn,
      where: a.user_arn == ^user_arn,
      order_by: [asc: p.policy_arn],
      select: %{
        user_arn: a.user_arn,
        policy_arn: p.policy_arn,
        document: p.document,
        inserted_at: a.inserted_at,
        updated_at: a.updated_at
      }
    )
    |> Repo.all()
  end

  def list_attached_user_managed_policies(_user_arn), do: []

  @impl true
  def attach_group_managed_policy(group_arn, policy_arn)
      when is_binary(group_arn) and is_binary(policy_arn) do
    %GroupManagedPolicyAttachment{}
    |> GroupManagedPolicyAttachment.changeset(%{group_arn: group_arn, policy_arn: policy_arn})
    |> Repo.insert(
      on_conflict: :nothing,
      conflict_target: [:group_arn, :policy_arn]
    )
    |> case do
      {:ok, _attachment} -> :ok
      {:error, %Ecto.Changeset{} = changeset} -> group_attachment_error(changeset)
    end
  end

  def attach_group_managed_policy(_group_arn, _policy_arn), do: {:error, :malformed}

  @impl true
  def detach_group_managed_policy(group_arn, policy_arn)
      when is_binary(group_arn) and is_binary(policy_arn) do
    Repo.delete_all(
      from a in GroupManagedPolicyAttachment,
        where: a.group_arn == ^group_arn and a.policy_arn == ^policy_arn
    )

    :ok
  end

  def detach_group_managed_policy(_group_arn, _policy_arn), do: :ok

  @impl true
  def list_attached_group_managed_policies(group_arn) when is_binary(group_arn) do
    from(a in GroupManagedPolicyAttachment,
      join: p in ManagedPolicy,
      on: p.policy_arn == a.policy_arn,
      where: a.group_arn == ^group_arn,
      order_by: [asc: p.policy_arn],
      select: %{
        group_arn: a.group_arn,
        policy_arn: p.policy_arn,
        document: p.document,
        inserted_at: a.inserted_at,
        updated_at: a.updated_at
      }
    )
    |> Repo.all()
  end

  def list_attached_group_managed_policies(_group_arn), do: []

  defp insert_managed_policy_row(policy_arn, doc, attrs) do
    %ManagedPolicy{}
    |> ManagedPolicy.changeset(
      Map.merge(attrs, %{
        policy_arn: policy_arn,
        document: doc,
        next_version_number: 2
      })
    )
    |> Repo.insert()
  end

  defp upsert_managed_policy_row(policy_arn, doc, attrs) do
    %ManagedPolicy{}
    |> ManagedPolicy.changeset(
      Map.merge(attrs, %{
        policy_arn: policy_arn,
        document: doc,
        next_version_number: 2
      })
    )
    |> Repo.insert(
      on_conflict: {:replace, [:document, :next_version_number, :updated_at]},
      conflict_target: :policy_arn,
      returning: true
    )
  end

  defp reset_managed_policy_versions(%ManagedPolicy{} = policy, doc) do
    Repo.delete_all(
      from v in ManagedPolicyVersion,
        where: v.managed_policy_id == ^policy.id
    )

    case insert_managed_policy_version(policy, "v1", doc, true) do
      {:ok, _version} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp insert_managed_policy_version(%ManagedPolicy{} = policy, version_id, doc, is_default) do
    %ManagedPolicyVersion{}
    |> ManagedPolicyVersion.changeset(%{
      managed_policy_id: policy.id,
      version_id: version_id,
      document: doc,
      is_default: is_default
    })
    |> Repo.insert()
  end

  defp locked_managed_policy(policy_arn) do
    Repo.one(
      from p in ManagedPolicy,
        where: p.policy_arn == ^policy_arn,
        lock: "FOR UPDATE"
    )
  end

  defp ensure_managed_policy_versions(%ManagedPolicy{} = policy) do
    if Repo.exists?(from v in ManagedPolicyVersion, where: v.managed_policy_id == ^policy.id) do
      :ok
    else
      case insert_managed_policy_version(policy, "v1", policy.document, true) do
        {:ok, _version} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp ensure_managed_policy_version_capacity(%ManagedPolicy{} = policy) do
    if managed_policy_version_count(policy) < 5 do
      :ok
    else
      {:error, :policy_version_limit_exceeded}
    end
  end

  defp managed_policy_version_count(%ManagedPolicy{} = policy) do
    Repo.aggregate(
      from(v in ManagedPolicyVersion, where: v.managed_policy_id == ^policy.id),
      :count
    )
  end

  defp managed_policy_non_default_version_count(%ManagedPolicy{} = policy) do
    Repo.aggregate(
      from(v in ManagedPolicyVersion,
        where: v.managed_policy_id == ^policy.id and not v.is_default
      ),
      :count
    )
  end

  defp default_managed_policy_document(%ManagedPolicy{} = policy) do
    case default_managed_policy_version(policy) do
      %ManagedPolicyVersion{document: document} -> document
      nil -> policy.document
    end
  end

  defp default_managed_policy_version_id(%ManagedPolicy{} = policy) do
    case default_managed_policy_version(policy) do
      %ManagedPolicyVersion{version_id: version_id} -> version_id
      nil -> "v1"
    end
  end

  defp default_managed_policy_version(%ManagedPolicy{} = policy) do
    Repo.one(
      from v in ManagedPolicyVersion,
        where: v.managed_policy_id == ^policy.id and v.is_default,
        limit: 1
    )
  end

  defp next_managed_policy_version_id(%ManagedPolicy{next_version_number: next_version_number})
       when is_integer(next_version_number) and next_version_number >= 2 do
    "v#{next_version_number}"
  end

  defp next_managed_policy_version_id(%ManagedPolicy{} = policy) do
    next =
      from(v in ManagedPolicyVersion,
        where: v.managed_policy_id == ^policy.id,
        select: v.version_id
      )
      |> Repo.all()
      |> Enum.map(fn "v" <> number -> String.to_integer(number) end)
      |> Enum.max(fn -> 1 end)
      |> Kernel.+(1)

    "v#{next}"
  end

  defp increment_managed_policy_version_counter(
         %ManagedPolicy{} = policy,
         doc,
         set_as_default
       ) do
    next_version_number =
      policy
      |> Map.get(:next_version_number, 2)
      |> max(2)
      |> Kernel.+(1)

    attrs = %{next_version_number: next_version_number}
    attrs = if set_as_default, do: Map.put(attrs, :document, doc), else: attrs

    policy
    |> ManagedPolicy.changeset(attrs)
    |> Repo.update()
  end

  defp maybe_set_default_managed_policy_version(_policy, _version, false), do: :ok

  defp maybe_set_default_managed_policy_version(policy, version, true),
    do: set_default_managed_policy_version_rows(policy, version)

  defp set_default_managed_policy_version_rows(policy, version) do
    Repo.update_all(
      from(v in ManagedPolicyVersion, where: v.managed_policy_id == ^policy.id),
      set: [is_default: false]
    )

    case Repo.update_all(
           from(v in ManagedPolicyVersion, where: v.id == ^version.id),
           set: [is_default: true]
         ) do
      {1, _rows} ->
        with {:ok, _policy} <-
               policy |> ManagedPolicy.changeset(%{document: version.document}) |> Repo.update() do
          :ok
        end

      _other ->
        {:error, :not_found}
    end
  end

  defp managed_policy_version_map(policy, version) do
    %{
      policy_arn: policy.policy_arn,
      version_id: version.version_id,
      is_default_version: version.is_default,
      document: version.document,
      inserted_at: version.inserted_at,
      updated_at: version.updated_at
    }
  end

  defp managed_policy_version_sort_key(%ManagedPolicyVersion{version_id: "v" <> number}) do
    case Integer.parse(number) do
      {parsed, ""} -> parsed
      _other -> 0
    end
  end

  defp update_managed_session_policy_tags(policy_arn, update_fun) do
    Repo.transaction(fn ->
      case Repo.one(
             from p in ManagedPolicy, where: p.policy_arn == ^policy_arn, lock: "FOR UPDATE"
           ) do
        %ManagedPolicy{} = policy ->
          updated_tags =
            policy.tags
            |> normalize_tags()
            |> update_fun.()

          with :ok <- Tags.validate(Tags.map_to_list(updated_tags), :bucket),
               {:ok, _policy} <-
                 policy
                 |> Ecto.Changeset.change(tags: updated_tags)
                 |> Repo.update() do
            :ok
          else
            {:error, :invalid_tag} -> Repo.rollback({:error, :invalid_tag})
            {:error, %Ecto.Changeset{} = changeset} -> Repo.rollback({:error, changeset})
          end

        nil ->
          Repo.rollback({:error, :not_found})
      end
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp managed_policy_users(policy_arn) do
    from(a in UserManagedPolicyAttachment,
      join: u in User,
      on: u.user_arn == a.user_arn,
      where: a.policy_arn == ^policy_arn,
      order_by: [asc: u.user_name],
      select: %{
        id: u.id,
        user_name: u.user_name,
        user_arn: u.user_arn,
        status: u.status,
        inserted_at: u.inserted_at,
        updated_at: u.updated_at
      }
    )
    |> Repo.all()
  end

  defp managed_policy_boundary_users(policy_arn) do
    from(u in User,
      where: u.permissions_boundary_policy_arn == ^policy_arn,
      order_by: [asc: u.user_name],
      select: %{
        id: u.id,
        user_name: u.user_name,
        user_arn: u.user_arn,
        status: u.status,
        tags: u.tags,
        permissions_boundary_policy_arn: u.permissions_boundary_policy_arn,
        inserted_at: u.inserted_at,
        updated_at: u.updated_at
      }
    )
    |> Repo.all()
  end

  defp managed_policy_groups(policy_arn) do
    from(a in GroupManagedPolicyAttachment,
      join: g in Group,
      on: g.group_arn == a.group_arn,
      where: a.policy_arn == ^policy_arn,
      order_by: [asc: g.group_name],
      select: %{
        id: g.id,
        group_name: g.group_name,
        group_arn: g.group_arn,
        status: g.status,
        inserted_at: g.inserted_at,
        updated_at: g.updated_at
      }
    )
    |> Repo.all()
  end

  defp managed_policy_roles(policy_arn) do
    from(a in RoleManagedPolicyAttachment,
      join: r in Role,
      on: r.role_arn == a.role_arn,
      where: a.policy_arn == ^policy_arn,
      order_by: [asc: r.role_name],
      select: %{
        id: r.id,
        role_name: r.role_name,
        role_arn: r.role_arn,
        inserted_at: r.inserted_at,
        updated_at: r.updated_at
      }
    )
    |> Repo.all()
  end

  defp managed_policy_boundary_roles(policy_arn) do
    from(r in Role,
      where: r.permissions_boundary_policy_arn == ^policy_arn,
      order_by: [asc: r.role_name],
      select: %{
        id: r.id,
        role_name: r.role_name,
        role_arn: r.role_arn,
        description: r.description,
        trust_policy: r.trust_policy,
        max_session_duration_seconds: r.max_session_duration_seconds,
        tags: r.tags,
        permissions_boundary_policy_arn: r.permissions_boundary_policy_arn,
        inserted_at: r.inserted_at,
        updated_at: r.updated_at
      }
    )
    |> Repo.all()
  end

  defp normalize_tags(tags) when is_map(tags) do
    Map.new(tags, fn {key, value} -> {to_string(key), tag_value(value)} end)
  end

  defp normalize_tags(_tags), do: %{}

  defp tag_value(nil), do: ""
  defp tag_value(value), do: to_string(value)

  defp inline_principal_policies(principal_arn, source \\ "principal_policy") do
    from(p in PrincipalPolicy,
      where: p.principal_arn == ^principal_arn,
      order_by: [asc: p.policy_name]
    )
    |> Repo.all()
    |> Enum.flat_map(fn %PrincipalPolicy{document: doc, policy_name: name} ->
      parse_stored_identity_policy(doc,
        principal_arn: principal_arn,
        policy_name: name,
        source: source
      )
    end)
  end

  defp inherited_group_policy_statements(user_arn) do
    from(m in GroupMembership,
      join: u in User,
      on: u.user_arn == m.user_arn,
      join: g in Group,
      on: g.group_arn == m.group_arn,
      join: p in PrincipalPolicy,
      on: p.principal_arn == g.group_arn,
      where: m.user_arn == ^user_arn and u.status == "active" and g.status == "active",
      order_by: [asc: g.group_name, asc: p.policy_name],
      select: {g.group_arn, p.policy_name, p.document}
    )
    |> Repo.all()
    |> Enum.flat_map(fn {group_arn, policy_name, doc} ->
      parse_stored_identity_policy(doc,
        principal_arn: group_arn,
        policy_name: policy_name,
        source: "group_policy"
      )
    end)
  end

  defp attached_user_managed_policy_statements(user_arn) do
    from(a in UserManagedPolicyAttachment,
      join: p in ManagedPolicy,
      on: p.policy_arn == a.policy_arn,
      where: a.user_arn == ^user_arn,
      order_by: [asc: p.policy_arn],
      select: {p.policy_arn, p.document}
    )
    |> Repo.all()
    |> Enum.flat_map(fn {policy_arn, doc} ->
      parse_stored_identity_policy(doc,
        principal_arn: user_arn,
        policy_name: policy_arn,
        source: "user_managed_policy"
      )
    end)
  end

  defp inherited_group_managed_policy_statements(user_arn) do
    from(m in GroupMembership,
      join: u in User,
      on: u.user_arn == m.user_arn,
      join: g in Group,
      on: g.group_arn == m.group_arn,
      join: a in GroupManagedPolicyAttachment,
      on: a.group_arn == g.group_arn,
      join: p in ManagedPolicy,
      on: p.policy_arn == a.policy_arn,
      where: m.user_arn == ^user_arn and u.status == "active" and g.status == "active",
      order_by: [asc: g.group_name, asc: p.policy_arn],
      select: {g.group_arn, p.policy_arn, p.document}
    )
    |> Repo.all()
    |> Enum.flat_map(fn {group_arn, policy_arn, doc} ->
      parse_stored_identity_policy(doc,
        principal_arn: group_arn,
        policy_name: policy_arn,
        source: "group_managed_policy"
      )
    end)
  end

  defp inactive_explicit_user?("arn:aws:iam:::user/" <> _ = user_arn) do
    case Repo.get_by(User, user_arn: user_arn) do
      %User{status: "inactive"} -> true
      %User{} -> false
      nil -> false
    end
  end

  defp inactive_explicit_user?(_principal_arn), do: false

  defp principal_permissions_boundary_policy_arn("arn:aws:iam:::user/" <> _ = user_arn) do
    case Repo.get_by(User, user_arn: user_arn, status: "active") do
      %User{permissions_boundary_policy_arn: policy_arn}
      when is_binary(policy_arn) and policy_arn != "" ->
        {:ok, policy_arn}

      %User{} ->
        :none

      nil ->
        :none
    end
  end

  defp principal_permissions_boundary_policy_arn("arn:aws:iam:::role/" <> _ = role_arn) do
    case Repo.get_by(Role, role_arn: role_arn) do
      %Role{permissions_boundary_policy_arn: policy_arn}
      when is_binary(policy_arn) and policy_arn != "" ->
        {:ok, policy_arn}

      %Role{} ->
        :none

      nil ->
        :none
    end
  end

  defp principal_permissions_boundary_policy_arn(_principal_arn), do: :none

  defp boundary_policy_document(policy_arn) do
    case Repo.get_by(ManagedPolicy, policy_arn: policy_arn) do
      %ManagedPolicy{} = policy -> {:ok, default_managed_policy_document(policy)}
      nil -> :invalid
    end
  end

  defp boundary_policy_statements({:ok, document}, principal_arn, policy_arn) do
    case document |> Jason.encode!() |> Statement.parse_identity_policy() do
      {:ok, statements} when statements != [] ->
        {:ok, statements}

      _other ->
        require Logger

        Logger.warning("stored permissions boundary policy failed to parse",
          principal_arn: principal_arn,
          policy_arn: policy_arn
        )

        :invalid
    end
  end

  defp boundary_policy_statements(:invalid, _principal_arn, _policy_arn), do: :invalid

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

  defp user_attachment_error(%Ecto.Changeset{} = changeset) do
    cond do
      foreign_key_error?(changeset, :user_arn) -> {:error, :user_not_found}
      foreign_key_error?(changeset, :policy_arn) -> {:error, :policy_not_found}
      true -> {:error, changeset}
    end
  end

  defp group_attachment_error(%Ecto.Changeset{} = changeset) do
    cond do
      foreign_key_error?(changeset, :group_arn) -> {:error, :group_not_found}
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
