defmodule Maxio.IAM.CredentialInvalidation do
  @moduledoc """
  Best-effort, all-attempt post-commit invalidation for exact credential IDs.

  Database mutations are already committed when this module runs. Therefore a
  failed local cache invalidation or PubSub transport must remain observable but
  must never skip later exact IDs or be misreported as a database rollback.
  Failure evidence deliberately omits IDs, ARNs, secrets, tokens, and raw
  transport terms.
  """

  alias Maxio.Auth.CredentialStore
  alias Maxio.Cluster.Notify

  @type result :: %{
          attempted: %{
            local_ids: non_neg_integer(),
            typed_batches: non_neg_integer(),
            legacy_events: non_neg_integer()
          },
          failures: [map()]
        }

  @spec after_commit([binary()], [Notify.event()]) :: result()
  def after_commit(access_key_ids, legacy_events \\ [])
      when is_list(access_key_ids) and is_list(legacy_events) do
    ids =
      access_key_ids
      |> Enum.filter(&(is_binary(&1) and &1 != ""))
      |> Enum.uniq()

    {local_failures, local_attempts} =
      attempt_all(ids, :local_invalidation, fn access_key_id ->
        CredentialStore.invalidate({:access_key, access_key_id})
      end)

    {typed_failures, typed_attempts} =
      if ids == [] do
        {[], 0}
      else
        attempt_all(
          [{:iam_credentials_changed, ids}],
          :typed_broadcast,
          &Notify.broadcast_checked/1
        )
      end

    events = Enum.map(ids, &{:iam_changed, &1}) ++ legacy_events

    {legacy_failures, legacy_attempts} =
      attempt_all(events, :legacy_broadcast, &Notify.broadcast_checked/1)

    %{
      attempted: %{
        local_ids: local_attempts,
        typed_batches: typed_attempts,
        legacy_events: legacy_attempts
      },
      failures: local_failures ++ typed_failures ++ legacy_failures
    }
  end

  defp attempt_all(items, stage, fun) do
    failures =
      Enum.reduce(items, [], fn item, failures ->
        case safe_attempt(fun, item) do
          :ok -> failures
          {:error, category} -> [%{stage: stage, category: category} | failures]
        end
      end)
      |> Enum.reverse()

    {failures, length(items)}
  end

  defp safe_attempt(fun, item) do
    case fun.(item) do
      :ok -> :ok
      {:error, _reason} -> {:error, :returned_error}
      _other -> {:error, :unexpected_result}
    end
  rescue
    _error -> {:error, :exception}
  catch
    :exit, _reason -> {:error, :exit}
    _kind, _reason -> {:error, :throw}
  end
end
