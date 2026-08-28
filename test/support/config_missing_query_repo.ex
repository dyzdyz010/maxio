defmodule Maxio.Test.ConfigMissingQueryRepo do
  @moduledoc false

  alias Maxio.Config.RuntimeConfig
  alias Maxio.Repo

  # Intentionally no query!/2 or query!/3: the coordinator must reject this dependency before
  # issuing any runtime_configs read or write. Every other operation delegates to the real Repo so
  # a bypass is observable as real PostgreSQL state, not as behavior of a mock.
  def transaction(fun), do: Repo.transaction(fun)
  def transaction(fun, opts), do: Repo.transaction(fun, opts)
  def rollback(reason), do: Repo.rollback(reason)
  def all(queryable, opts \\ []), do: Repo.all(queryable, opts)
  def insert_or_update(changeset, opts \\ []), do: Repo.insert_or_update(changeset, opts)
  def insert!(changeset, opts \\ []), do: Repo.insert!(changeset, opts)
  def delete!(%RuntimeConfig{} = row, opts \\ []), do: Repo.delete!(row, opts)
end
