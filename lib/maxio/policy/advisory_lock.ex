defmodule Maxio.Policy.AdvisoryLock do
  @moduledoc """
  Stable PostgreSQL advisory-lock boundary for policy attachment mutations.

  Every singular and batch attachment writer takes the principal quota lock first and managed
  policy locks second, in lexical ARN order. Centralising both namespaces prevents independently
  correct quota checks from racing across entrypoints.
  """

  @principal_quota_namespace "maxio.principal_policy_quota"
  @managed_policy_namespace "maxio.managed_policy"

  @spec principal_quota!(module(), String.t()) :: :ok
  def principal_quota!(repo, principal_arn) when is_binary(principal_arn) do
    emit([:maxio, :policy, :principal_quota, :lock_wait], %{principal_arn: principal_arn})
    lock!(repo, @principal_quota_namespace, principal_arn)
    emit([:maxio, :policy, :principal_quota, :locked], %{principal_arn: principal_arn})
  end

  @spec managed_policy!(module(), String.t()) :: :ok
  def managed_policy!(repo, policy_arn) when is_binary(policy_arn) do
    emit([:maxio, :policy, :managed_policy, :lock_wait], %{policy_arn: policy_arn})
    lock!(repo, @managed_policy_namespace, policy_arn)
    emit([:maxio, :policy, :managed_policy, :locked], %{policy_arn: policy_arn})
  end

  @spec managed_policies!(module(), [String.t()]) :: :ok
  def managed_policies!(repo, policy_arns) when is_list(policy_arns) do
    policy_arns
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.each(&managed_policy!(repo, &1))
  end

  defp lock!(repo, namespace, key) do
    Ecto.Adapters.SQL.query!(
      repo,
      "SELECT pg_advisory_xact_lock(hashtext($1), hashtext($2))",
      [namespace, key]
    )

    :ok
  end

  defp emit(event, metadata) do
    :telemetry.execute(event, %{system_time: System.system_time()}, metadata)
    :ok
  end
end
