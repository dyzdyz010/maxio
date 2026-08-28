defmodule Maxio.IAM.CredentialNamespace do
  @moduledoc """
  Serializes exact access-key IDs shared by long-term and STS credentials.

  Callers must acquire the lock, check availability, and persist the credential
  in the same database transaction. Persisted STS rows reserve their ID in
  every status, including revoked sessions.
  """

  import Ecto.Query

  alias Maxio.IAM.{AccessKey, STSSession}

  @lock_namespace "maxio.access_keys.exact"
  @lock_wait_event [:maxio, :iam, :credential_namespace, :lock_wait]

  @spec reserve_exact(module(), String.t()) :: :ok | {:error, :access_key_id_conflict}
  def reserve_exact(repo, access_key_id) when is_binary(access_key_id) do
    lock_exact(repo, access_key_id)

    if available?(repo, access_key_id) do
      :ok
    else
      {:error, :access_key_id_conflict}
    end
  end

  @doc false
  @spec lock_exact(module(), String.t()) :: :ok
  def lock_exact(repo, access_key_id) when is_binary(access_key_id) do
    :telemetry.execute(
      @lock_wait_event,
      %{system_time: System.system_time()},
      %{access_key_id: access_key_id}
    )

    Ecto.Adapters.SQL.query!(
      repo,
      "SELECT pg_advisory_xact_lock(hashtext($1), hashtext($2))",
      [@lock_namespace, access_key_id]
    )

    :ok
  end

  defp available?(repo, access_key_id) do
    not repo.exists?(from(a in AccessKey, where: a.access_key_id == ^access_key_id)) and
      not repo.exists?(from(s in STSSession, where: s.access_key_id == ^access_key_id))
  end
end
