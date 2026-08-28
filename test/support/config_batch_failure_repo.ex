defmodule Maxio.Test.ConfigBatchFailureRepo do
  @moduledoc false

  alias Maxio.Config.{RuntimeConfig, RuntimeConfigAudit}
  alias Maxio.Repo

  @failure_key {__MODULE__, :failure}

  def arm!(stage, key) when is_atom(stage) and is_atom(key) do
    Process.put(@failure_key, {stage, Atom.to_string(key)})
    :ok
  end

  def clear! do
    Process.delete(@failure_key)
    :ok
  end

  def transaction(fun), do: Repo.transaction(fun)
  def transaction(fun, opts), do: Repo.transaction(fun, opts)
  def rollback(reason), do: Repo.rollback(reason)

  def query!(sql, params \\ [], opts \\ []),
    do: Ecto.Adapters.SQL.query!(Repo, sql, params, opts)

  def one(queryable, opts \\ []), do: Repo.one(queryable, opts)
  def all(queryable, opts \\ []), do: Repo.all(queryable, opts)

  def insert(%Ecto.Changeset{} = changeset, opts \\ []) do
    maybe_fail_write!(changeset)
    Repo.insert(changeset, opts)
  end

  def insert!(%Ecto.Changeset{} = changeset, opts \\ []) do
    maybe_fail_write!(changeset)
    Repo.insert!(changeset, opts)
  end

  def update(%Ecto.Changeset{} = changeset, opts \\ []) do
    maybe_fail!(:runtime_update, key(changeset))
    Repo.update(changeset, opts)
  end

  def update!(%Ecto.Changeset{} = changeset, opts \\ []) do
    maybe_fail!(:runtime_update, key(changeset))
    Repo.update!(changeset, opts)
  end

  def insert_or_update(%Ecto.Changeset{} = changeset, opts \\ []) do
    maybe_fail_write!(changeset)
    Repo.insert_or_update(changeset, opts)
  end

  def insert_or_update!(%Ecto.Changeset{} = changeset, opts \\ []) do
    maybe_fail_write!(changeset)
    Repo.insert_or_update!(changeset, opts)
  end

  def delete(%RuntimeConfig{} = row, opts \\ []) do
    maybe_fail!(:runtime_delete, row.key)
    Repo.delete(row, opts)
  end

  def delete!(%RuntimeConfig{} = row, opts \\ []) do
    maybe_fail!(:runtime_delete, row.key)
    Repo.delete!(row, opts)
  end

  defp maybe_fail_write!(%Ecto.Changeset{data: %RuntimeConfigAudit{}} = changeset) do
    maybe_fail!(:audit_insert, key(changeset))
  end

  defp maybe_fail_write!(%Ecto.Changeset{data: %RuntimeConfig{id: nil}} = changeset) do
    maybe_fail!(:runtime_insert, key(changeset))
  end

  defp maybe_fail_write!(%Ecto.Changeset{data: %RuntimeConfig{}} = changeset) do
    maybe_fail!(:runtime_update, key(changeset))
  end

  defp key(changeset), do: Ecto.Changeset.get_field(changeset, :key)

  defp maybe_fail!(stage, key) do
    if Process.get(@failure_key) == {stage, key} do
      Repo.rollback({:forced_config_batch_failure, stage, key})
    end

    :ok
  end
end
