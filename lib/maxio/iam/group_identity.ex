defmodule Maxio.IAM.GroupIdentity do
  @moduledoc """
  Transaction boundary for case-folded IAM group identity generations.

  Callers capture an immutable group id before their transaction, then acquire the stable
  case-folded advisory lock and validate that id while holding it. Delete plus same-name recreate
  therefore cannot redirect an in-flight mutation to the replacement group.
  """

  import Ecto.Query

  alias Maxio.IAM.Group

  @lock_namespace "maxio.iam.group_identity"
  @lock_wait_event [:maxio, :iam, :group_identity, :lock_wait]
  @group_arn_prefix "arn:aws:iam:::group/"

  @type snapshot :: {:existing, Ecto.UUID.t()} | :missing

  @spec snapshot(module(), String.t()) :: snapshot()
  def snapshot(repo, name_or_arn) when is_binary(name_or_arn) do
    name = identity_name(name_or_arn)

    case fetch_by_name(repo, name) do
      %Group{id: id} -> {:existing, id}
      nil -> :missing
    end
  end

  @spec lock_snapshot(module(), String.t(), snapshot()) ::
          {:ok, Group.t() | :missing} | {:error, :identity_changed}
  def lock_snapshot(repo, name_or_arn, snapshot) when is_binary(name_or_arn) do
    name = identity_name(name_or_arn)
    lock_names!(repo, [name])
    validate_snapshot(repo, name, snapshot)
  end

  @doc false
  @spec lock_snapshots(module(), [{String.t(), snapshot()}]) ::
          {:ok, [Group.t() | :missing]} | {:error, :identity_changed}
  def lock_snapshots(repo, named_snapshots) when is_list(named_snapshots) do
    normalized = Enum.map(named_snapshots, fn {name, state} -> {identity_name(name), state} end)
    lock_names!(repo, Enum.map(normalized, &elem(&1, 0)))

    Enum.reduce_while(normalized, {:ok, []}, fn {name, state}, {:ok, rows} ->
      case validate_snapshot(repo, name, state) do
        {:ok, row} -> {:cont, {:ok, [row | rows]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, rows} -> {:ok, Enum.reverse(rows)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_snapshot(repo, name, {:existing, id}) do
    case fetch_by_name(repo, name, "FOR UPDATE") do
      %Group{id: ^id} = group -> {:ok, group}
      %Group{} -> {:error, :identity_changed}
      nil -> {:error, :identity_changed}
    end
  end

  defp validate_snapshot(repo, name, :missing) do
    case fetch_by_name(repo, name, "FOR UPDATE") do
      nil -> {:ok, :missing}
      %Group{} -> {:error, :identity_changed}
    end
  end

  defp fetch_by_name(repo, name, nil), do: repo.one(group_name_query(name))

  defp fetch_by_name(repo, name, "FOR UPDATE") do
    repo.one(from(g in group_name_query(name), lock: "FOR UPDATE"))
  end

  defp fetch_by_name(repo, name), do: fetch_by_name(repo, name, nil)

  defp group_name_query(name) do
    from(g in Group,
      where: fragment("lower(?)", g.group_name) == ^String.downcase(name),
      order_by: [asc: g.inserted_at],
      limit: 1
    )
  end

  defp lock_names!(repo, names) do
    names
    |> Enum.map(&String.downcase/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.each(fn case_folded_name ->
      :telemetry.execute(
        @lock_wait_event,
        %{system_time: System.system_time()},
        %{case_folded_group_name: case_folded_name}
      )

      Ecto.Adapters.SQL.query!(
        repo,
        "SELECT pg_advisory_xact_lock(hashtext($1), hashtext($2))",
        [@lock_namespace, case_folded_name]
      )
    end)
  end

  defp identity_name(@group_arn_prefix <> name), do: name
  defp identity_name(name), do: name
end
