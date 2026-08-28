defmodule Maxio.IAM.AdminGroupLifecycle do
  @moduledoc """
  Atomic MinIO admin group lifecycle coordinator.

  Optimistic reads select compatibility errors and capture immutable identity
  generations. Every writer then revalidates under the common lock order:
  group identity, stable case-folded user identities, membership rows.
  """

  import Ecto.Query
  require Logger

  alias Maxio.Cluster.Notify

  alias Maxio.IAM.{
    AccessKey,
    Group,
    GroupIdentity,
    GroupManagedPolicyAttachment,
    GroupMembership,
    STSSession,
    User,
    UserIdentity
  }

  alias Maxio.Policy.PrincipalPolicy
  alias Maxio.Repo

  @membership_event [:maxio, :iam, :group_membership, :before_mutation]
  @projection_event [:maxio, :iam, :admin_group_projection, :phase]
  @policy_prefix "arn:aws:iam:::policy/"

  @spec list_names() :: {:ok, [String.t()]} | {:error, term()}
  def list_names do
    sql = """
    /* maxio_admin_group_names */
    SELECT group_name
    FROM iam_groups
    ORDER BY group_name COLLATE "C"
    """

    case Ecto.Adapters.SQL.query(Repo, sql, []) do
      {:ok, %{rows: rows}} -> {:ok, Enum.map(rows, &hd/1)}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec describe(String.t()) :: {:ok, map()} | {:error, term()}
  def describe(name_or_arn) when is_binary(name_or_arn) do
    group_name = identity_group_name(name_or_arn)

    :telemetry.execute(
      @projection_event,
      %{system_time: System.system_time()},
      %{isolation: "single statement", phase: :before_read, group_name: group_name}
    )

    result = Ecto.Adapters.SQL.query(Repo, description_sql(), [String.downcase(group_name)])

    :telemetry.execute(
      @projection_event,
      %{system_time: System.system_time()},
      %{isolation: "single statement", phase: :after_read, group_name: group_name}
    )

    case result do
      {:ok,
       %{
         rows: [
           [
             canonical_name,
             status,
             updated_at,
             member_names,
             managed_policy_names,
             inline_policy_names,
             non_root_managed_policy_names
           ]
         ]
       }} ->
        {:ok,
         %{
           group_name: canonical_name,
           status: status,
           updated_at: normalize_utc_datetime(updated_at),
           member_names: member_names || [],
           managed_policy_names: managed_policy_names || [],
           inline_policy_names: inline_policy_names || [],
           non_root_managed_policy_names: non_root_managed_policy_names || [],
           evidence: %{
             snapshot: "single statement",
             member_order: "maxio-sorted-unique-members"
           }
         }}

      {:ok, %{rows: []}} ->
        {:error, :group_not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def describe(_name_or_arn), do: {:error, :invalid_argument}

  @spec update_members(String.t(), [String.t()], boolean(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def update_members(group_name, member_names, remove?, group_status)
      when is_binary(group_name) and is_list(member_names) and is_boolean(remove?) and
             is_binary(group_status) do
    with :ok <- validate_member_types(member_names),
         :ok <- validate_wire_member_names(member_names),
         :ok <- precheck_forbidden_members(member_names) do
      cond do
        remove? and group_name == "" ->
          {:error, :invalid_argument}

        remove? and member_names == [] ->
          delete_empty(group_name, group_status)

        remove? ->
          with {:ok, users} <- preflight_users(member_names) do
            mutate_existing_group(group_name, users, :remove_members, group_status)
          end

        true ->
          create_or_add(group_name, member_names, group_status)
      end
    end
  end

  def update_members(_group_name, _member_names, _remove?, _group_status),
    do: {:error, :invalid_argument}

  @spec set_status(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def set_status(group_name, status)
      when is_binary(group_name) and status in ["active", "inactive"] do
    snapshot = GroupIdentity.snapshot(Repo, group_name)

    Repo.transaction(fn ->
      with {:ok, %Group{} = group} <- GroupIdentity.lock_snapshot(Repo, group_name, snapshot) do
        affected_member_arns = membership_arns(group.group_arn)
        updated_at = fresh_timestamp(group.updated_at)

        case update_group(group, %{status: status}, updated_at) do
          {:ok, updated} ->
            %{
              group: public_group(updated),
              affected_member_arns: affected_member_arns,
              updated_at: updated_at
            }

          {:error, reason} ->
            Repo.rollback({:error, reason})
        end
      else
        {:ok, :missing} -> Repo.rollback({:error, :group_not_found})
        {:error, :identity_changed} -> Repo.rollback({:error, :identity_changed})
      end
    end)
    |> transaction_result()
    |> notify_status_result()
  end

  def set_status(_group_name, _status), do: {:error, :invalid_argument}

  @doc false
  @spec add_member(String.t(), String.t()) :: :ok | {:error, term()}
  def add_member(user_name_or_arn, group_name_or_arn),
    do: mutate_single_member(user_name_or_arn, group_name_or_arn, :add, true)

  @doc false
  @spec remove_member(String.t(), String.t(), boolean()) :: :ok | {:error, term()}
  def remove_member(user_name_or_arn, group_name_or_arn, strict?),
    do: mutate_single_member(user_name_or_arn, group_name_or_arn, :remove, strict?)

  defp create_or_add(group_name, member_names, group_status) do
    group_snapshot = GroupIdentity.snapshot(Repo, group_name)

    with :ok <- validate_new_group_name_if_missing(group_name, group_snapshot),
         {:ok, users} <- preflight_users(member_names) do
      Repo.transaction(fn ->
        with {:ok, locked_group} <- GroupIdentity.lock_snapshot(Repo, group_name, group_snapshot),
             {:ok, locked_users} <- lock_users(users),
             {:ok, group} <- ensure_group(locked_group, group_name),
             {:ok, result} <- mutate_members(group, locked_users, :create_or_add, group_status) do
          result
        else
          {:error, reason} -> Repo.rollback({:error, reason})
        end
      end)
      |> transaction_result()
      |> notify_members_result()
    end
  end

  defp mutate_single_member(user_name_or_arn, group_name_or_arn, operation, strict?) do
    with %User{} = user <- fetch_user(user_name_or_arn),
         %Group{} = group <- fetch_group(group_name_or_arn) do
      user_snapshot = {:existing, user.id}
      group_snapshot = {:existing, group.id}

      Repo.transaction(fn ->
        with {:ok, %Group{} = locked_group} <-
               GroupIdentity.lock_snapshot(Repo, group.group_name, group_snapshot),
             {:ok, %User{} = locked_user} <-
               UserIdentity.lock_snapshot(Repo, user.user_name, user_snapshot) do
          :telemetry.execute(
            @membership_event,
            %{system_time: System.system_time()},
            %{
              group_arn: locked_group.group_arn,
              operation: operation,
              user_arns: [locked_user.user_arn]
            }
          )

          mutate_single_membership(locked_user, locked_group, operation, strict?)
        else
          {:error, _identity_reason} -> Repo.rollback({:error, :not_found})
        end
      end)
      |> case do
        {:ok, user_arn} ->
          _invalidation = notify_after_commit([{:principal_policy_changed, user_arn}])
          :ok

        {:error, {:error, reason}} ->
          {:error, reason}

        {:error, reason} ->
          {:error, reason}
      end
    else
      nil when operation == :remove and not strict? -> :ok
      nil -> {:error, :not_found}
    end
  end

  defp mutate_single_membership(user, group, :add, _strict?) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Repo.insert_all(
      GroupMembership,
      [
        %{
          id: Ecto.UUID.generate(),
          user_arn: user.user_arn,
          group_arn: group.group_arn,
          inserted_at: now,
          updated_at: now
        }
      ],
      on_conflict: :nothing,
      conflict_target: [:user_arn, :group_arn]
    )

    user.user_arn
  end

  defp mutate_single_membership(user, group, :remove, strict?) do
    {count, _rows} =
      Repo.delete_all(
        from(m in GroupMembership,
          where: m.user_arn == ^user.user_arn and m.group_arn == ^group.group_arn
        )
      )

    if strict? and count == 0 do
      Repo.rollback({:error, :not_found})
    else
      user.user_arn
    end
  end

  defp mutate_existing_group(group_name, users, operation, group_status) do
    group_snapshot = GroupIdentity.snapshot(Repo, group_name)

    Repo.transaction(fn ->
      with {:ok, %Group{} = group} <-
             GroupIdentity.lock_snapshot(Repo, group_name, group_snapshot),
           {:ok, locked_users} <- lock_users(users),
           {:ok, result} <- mutate_members(group, locked_users, operation, group_status) do
        result
      else
        {:ok, :missing} -> Repo.rollback({:error, :group_not_found})
        {:error, reason} -> Repo.rollback({:error, reason})
      end
    end)
    |> transaction_result()
    |> notify_members_result()
  end

  defp delete_empty(group_name, group_status) do
    snapshot = GroupIdentity.snapshot(Repo, group_name)

    Repo.transaction(fn ->
      with {:ok, %Group{} = group} <- GroupIdentity.lock_snapshot(Repo, group_name, snapshot) do
        if Repo.exists?(from(m in GroupMembership, where: m.group_arn == ^group.group_arn)) do
          Repo.rollback({:error, :group_not_empty})
        else
          updated_at = fresh_timestamp(group.updated_at)

          :telemetry.execute(
            @membership_event,
            %{system_time: System.system_time()},
            %{group_arn: group.group_arn, operation: :delete_empty, user_arns: []}
          )

          {inline_count, _} =
            Repo.delete_all(
              from(p in PrincipalPolicy, where: p.principal_arn == ^group.group_arn)
            )

          {attachment_count, _} =
            Repo.delete_all(
              from(a in GroupManagedPolicyAttachment, where: a.group_arn == ^group.group_arn)
            )

          Repo.delete!(group)

          %{
            group: nil,
            group_arn: group.group_arn,
            operation: :delete_empty,
            changed_member_arns: [],
            affected_member_arns: [],
            affected: %{
              memberships_changed: 0,
              inline_policies_deleted: inline_count,
              managed_policy_attachments_deleted: attachment_count
            },
            updated_at: updated_at,
            group_status_ignored?: group_status != ""
          }
        end
      else
        {:ok, :missing} -> Repo.rollback({:error, :group_not_found})
        {:error, :identity_changed} -> Repo.rollback({:error, :identity_changed})
      end
    end)
    |> transaction_result()
    |> notify_members_result()
  end

  defp mutate_members(%Group{} = group, users, operation, group_status) do
    user_arns = users |> Enum.map(& &1.user_arn) |> Enum.uniq() |> Enum.sort()

    existing =
      Repo.all(
        from(m in GroupMembership,
          where: m.group_arn == ^group.group_arn and m.user_arn in ^user_arns,
          select: m.user_arn
        )
      )
      |> MapSet.new()

    changed_member_arns =
      case operation do
        :create_or_add -> Enum.reject(user_arns, &MapSet.member?(existing, &1))
        :remove_members -> Enum.filter(user_arns, &MapSet.member?(existing, &1))
      end

    :telemetry.execute(
      @membership_event,
      %{system_time: System.system_time()},
      %{group_arn: group.group_arn, operation: operation, user_arns: user_arns}
    )

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    case operation do
      :create_or_add ->
        rows =
          Enum.map(changed_member_arns, fn user_arn ->
            %{
              id: Ecto.UUID.generate(),
              user_arn: user_arn,
              group_arn: group.group_arn,
              inserted_at: now,
              updated_at: now
            }
          end)

        Repo.insert_all(GroupMembership, rows,
          on_conflict: :nothing,
          conflict_target: [:user_arn, :group_arn]
        )

      :remove_members ->
        Repo.delete_all(
          from(m in GroupMembership,
            where: m.group_arn == ^group.group_arn and m.user_arn in ^user_arns
          )
        )
    end

    updated_at = fresh_timestamp(group.updated_at)

    case update_group(group, %{}, updated_at) do
      {:ok, updated_group} ->
        {:ok,
         %{
           group: public_group(updated_group),
           group_arn: updated_group.group_arn,
           operation: operation,
           changed_member_arns: changed_member_arns,
           affected_member_arns: user_arns,
           affected: %{memberships_changed: length(changed_member_arns)},
           updated_at: updated_at,
           group_status_ignored?: group_status != ""
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp lock_users(users) do
    snapshots = Enum.map(users, &{&1.user_name, {:existing, &1.id}})

    case UserIdentity.lock_snapshots(Repo, snapshots) do
      {:ok, locked} ->
        if Enum.all?(locked, &match?(%User{}, &1)),
          do: {:ok, Enum.uniq_by(locked, & &1.id)},
          else: {:error, :user_not_found}

      {:error, :user_not_found} ->
        {:error, :user_not_found}

      {:error, :identity_changed} ->
        {:error, :user_not_found}
    end
  end

  defp ensure_group(:missing, group_name) do
    %Group{}
    |> Group.changeset(%{
      group_name: group_name,
      group_arn: group_arn(group_name),
      status: "active",
      tags: %{}
    })
    |> Repo.insert()
    |> case do
      {:ok, group} -> {:ok, group}
      {:error, _changeset} -> {:error, :invalid_group_name}
    end
  end

  defp ensure_group(%Group{} = group, _group_name), do: {:ok, group}

  defp preflight_users(member_names) do
    Enum.reduce_while(member_names, {:ok, []}, fn member_name, {:ok, users} ->
      case fetch_user(member_name) do
        %User{} = user ->
          {:cont, {:ok, users ++ [user]}}

        nil ->
          reason =
            if service_account?(member_name), do: :minio_action_not_allowed, else: :user_not_found

          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, users} -> {:ok, Enum.uniq_by(users, & &1.id)}
      error -> error
    end
  end

  defp precheck_forbidden_members(member_names) do
    root_access_key = Application.fetch_env!(:maxio, :s3) |> Keyword.fetch!(:root_user)

    case Enum.find(member_names, fn member_name ->
           member_name == root_access_key or
             Repo.exists?(from(s in STSSession, where: s.access_key_id == ^member_name))
         end) do
      nil -> :ok
      _forbidden -> {:error, :minio_action_not_allowed}
    end
  end

  defp validate_member_types(member_names) do
    if Enum.all?(member_names, &is_binary/1), do: :ok, else: {:error, :invalid_argument}
  end

  defp validate_wire_member_names(member_names) do
    if Enum.any?(member_names, &String.starts_with?(&1, "arn:aws:iam:::user/")),
      do: {:error, :user_not_found},
      else: :ok
  end

  defp validate_new_group_name_if_missing(_group_name, {:existing, _id}), do: :ok

  defp validate_new_group_name_if_missing(group_name, :missing) do
    cond do
      String.trim(group_name) != group_name ->
        {:error, :invalid_resource_name}

      group_name == "" or String.contains?(group_name, [",", "="]) ->
        {:error, :invalid_group_name}

      true ->
        :ok
    end
  end

  defp service_account?(member_name) do
    case Repo.get_by(AccessKey, access_key_id: member_name) do
      %AccessKey{principal_arn: principal_arn} -> principal_arn != user_arn(member_name)
      nil -> false
    end
  end

  defp fetch_user("arn:aws:iam:::user/" <> name), do: fetch_user(name)

  defp fetch_user(name) do
    Repo.one(
      from(u in User,
        where: fragment("lower(?)", u.user_name) == ^String.downcase(name),
        order_by: [asc: u.inserted_at],
        limit: 1
      )
    )
  end

  defp fetch_group("arn:aws:iam:::group/" <> name), do: fetch_group(name)

  defp fetch_group(name) do
    Repo.one(
      from(g in Group,
        where: fragment("lower(?)", g.group_name) == ^String.downcase(name),
        order_by: [asc: g.inserted_at],
        limit: 1
      )
    )
  end

  defp membership_arns(group_arn) do
    Repo.all(
      from(m in GroupMembership,
        where: m.group_arn == ^group_arn,
        select: m.user_arn,
        order_by: [asc: m.user_arn]
      )
    )
  end

  defp update_group(group, attrs, updated_at) do
    group
    |> Ecto.Changeset.change(attrs)
    |> Ecto.Changeset.force_change(:updated_at, updated_at)
    |> Repo.update()
  end

  defp fresh_timestamp(nil), do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  defp fresh_timestamp(previous) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    if DateTime.compare(now, previous) == :gt,
      do: now,
      else: DateTime.add(previous, 1, :microsecond)
  end

  defp transaction_result({:ok, result}), do: {:ok, result}
  defp transaction_result({:error, {:error, reason}}), do: {:error, reason}
  defp transaction_result({:error, reason}), do: {:error, reason}

  defp notify_members_result({:ok, result}) do
    events =
      Enum.map(result.affected_member_arns, &{:principal_policy_changed, &1}) ++
        [{:iam_changed, result.group_arn}]

    {:ok, Map.put(result, :invalidation, notify_after_commit(events))}
  end

  defp notify_members_result(error), do: error

  defp notify_status_result({:ok, result}) do
    events =
      Enum.map(result.affected_member_arns, &{:principal_policy_changed, &1}) ++
        [{:iam_changed, result.group.group_arn}]

    {:ok, Map.put(result, :invalidation, notify_after_commit(events))}
  end

  defp notify_status_result(error), do: error

  defp notify_after_commit(events) do
    events = Enum.uniq(events)

    failures =
      Enum.flat_map(events, fn event ->
        case Notify.broadcast_checked(event) do
          :ok -> []
          {:error, reason} -> [{event, reason}]
        end
      end)

    if failures != [] do
      Logger.warning("admin_group_invalidation_partial",
        event_count: length(events),
        failure_count: length(failures)
      )
    end

    %{attempted: length(events), failures: failures}
  end

  defp public_group(group) do
    %{
      id: group.id,
      group_name: group.group_name,
      group_arn: group.group_arn,
      status: group.status,
      tags: group.tags || %{},
      inserted_at: group.inserted_at,
      updated_at: group.updated_at
    }
  end

  defp group_arn(group_name), do: "arn:aws:iam:::group/#{group_name}"
  defp user_arn(user_name), do: "arn:aws:iam:::user/#{user_name}"

  defp identity_group_name("arn:aws:iam:::group/" <> name), do: name
  defp identity_group_name(name), do: name

  defp normalize_utc_datetime(%DateTime{} = value), do: value

  defp normalize_utc_datetime(%NaiveDateTime{} = value),
    do: DateTime.from_naive!(value, "Etc/UTC")

  defp description_sql do
    """
    /* maxio_admin_group_description */
    WITH target AS (
      SELECT group_name, group_arn, status, updated_at
      FROM iam_groups
      WHERE lower(group_name) = $1
      ORDER BY inserted_at
      LIMIT 1
    )
    SELECT
      target.group_name,
      target.status,
      target.updated_at,
      COALESCE((
        SELECT jsonb_agg(member_name ORDER BY member_name COLLATE "C")
        FROM (
          SELECT DISTINCT users.user_name AS member_name
          FROM iam_group_memberships AS memberships
          JOIN iam_users AS users ON users.user_arn = memberships.user_arn
          WHERE memberships.group_arn = target.group_arn
        ) AS members
      ), '[]'::jsonb) AS member_names,
      COALESCE((
        SELECT jsonb_agg(policy_name ORDER BY policy_name COLLATE "C")
        FROM (
          SELECT DISTINCT substring(attachments.policy_arn FROM char_length('#{@policy_prefix}') + 1) AS policy_name
          FROM iam_group_managed_policy_attachments AS attachments
          WHERE attachments.group_arn = target.group_arn
            AND attachments.policy_arn LIKE '#{@policy_prefix}%'
            AND substring(attachments.policy_arn FROM char_length('#{@policy_prefix}') + 1) NOT LIKE '%/%'
        ) AS root_policies
      ), '[]'::jsonb) AS managed_policy_names,
      COALESCE((
        SELECT jsonb_agg(policy_name ORDER BY policy_name COLLATE "C")
        FROM (
          SELECT DISTINCT policies.policy_name
          FROM principal_policies AS policies
          WHERE policies.principal_arn = target.group_arn
        ) AS inline_policies
      ), '[]'::jsonb) AS inline_policy_names,
      COALESCE((
        SELECT jsonb_agg(policy_name ORDER BY policy_name COLLATE "C")
        FROM (
          SELECT DISTINCT substring(attachments.policy_arn FROM char_length('#{@policy_prefix}') + 1) AS policy_name
          FROM iam_group_managed_policy_attachments AS attachments
          WHERE attachments.group_arn = target.group_arn
            AND attachments.policy_arn LIKE '#{@policy_prefix}%'
            AND substring(attachments.policy_arn FROM char_length('#{@policy_prefix}') + 1) LIKE '%/%'
        ) AS non_root_policies
      ), '[]'::jsonb) AS non_root_managed_policy_names
    FROM target
    """
  end
end
