defmodule Maxio.Cluster.Rebalance.Destination do
  @moduledoc """
  Free-space based destination selection for decommission copy-pass.

  This is a bounded placement helper: it chooses one non-target erasure set from
  current drive capacity telemetry. It does not mutate topology, distribute one
  object across multiple destinations, or implement full MinIO pool rebalance.
  """

  alias Maxio.Cluster.{DriveStats, Topology}

  @type candidate :: %{
          set_id: non_neg_integer(),
          drive_expected: non_neg_integer(),
          drive_endpoints: non_neg_integer(),
          drive_missing: non_neg_integer(),
          drive_ok: non_neg_integer(),
          drive_errors: non_neg_integer(),
          drive_free_bytes: non_neg_integer(),
          drive_min_free_bytes: non_neg_integer(),
          eligible?: boolean()
        }

  @type selection :: %{
          set_id: non_neg_integer(),
          source: :free_space,
          bytes_required: non_neg_integer(),
          drive_stats_status: atom(),
          drive_free_bytes: non_neg_integer(),
          drive_min_free_bytes: non_neg_integer(),
          candidates: [candidate()]
        }

  @doc """
  Select a non-target destination set with enough observed free space.

  Options:

    * `:bytes_required` - logical bytes to migrate; defaults to `0`.
    * `:topology` / `:transport` / `:provider` - forwarded to DriveStats.
    * `:drive_stats_fun` - test seam, called as `fun.(opts)`.
  """
  @spec select_decommission_destination(non_neg_integer(), keyword()) ::
          {:ok, selection()} | {:error, term()}
  def select_decommission_destination(target_set_id, opts \\ [])

  def select_decommission_destination(target_set_id, opts)
      when is_integer(target_set_id) do
    with {:ok, set_ids} <- set_ids(opts),
         :ok <- validate_target(target_set_id, set_ids),
         bytes_required <- non_negative_int(Keyword.get(opts, :bytes_required, 0)),
         endpoint_counts <- endpoint_counts(opts, set_ids),
         drive_stats <- sample_drive_stats(opts),
         :ok <- ensure_drive_stats_available(drive_stats),
         candidates <-
           candidates(drive_stats, set_ids, target_set_id, bytes_required, endpoint_counts),
         {:ok, chosen} <- choose_candidate(candidates, target_set_id, bytes_required) do
      {:ok,
       %{
         set_id: chosen.set_id,
         source: :free_space,
         bytes_required: bytes_required,
         drive_stats_status: drive_stats.status,
         drive_free_bytes: chosen.drive_free_bytes,
         drive_min_free_bytes: chosen.drive_min_free_bytes,
         candidates: candidates
       }}
    end
  end

  def select_decommission_destination(target_set_id, _opts),
    do: {:error, {:invalid_target_set_id, target_set_id}}

  defp sample_drive_stats(opts) do
    drive_stats_fun = Keyword.get(opts, :drive_stats_fun, &DriveStats.sample_topology/1)

    drive_stats_fun.(
      opts
      |> Keyword.take([:topology, :transport, :provider, :now_ms, :now_fun])
      |> Keyword.reject(fn {_key, value} -> is_nil(value) end)
    )
  end

  defp ensure_drive_stats_available(%{status: :no_topology}), do: {:error, :no_topology}
  defp ensure_drive_stats_available(%{samples: samples}) when is_list(samples), do: :ok
  defp ensure_drive_stats_available(other), do: {:error, {:invalid_drive_stats, other}}

  defp candidates(%{samples: samples}, set_ids, target_set_id, bytes_required, endpoint_counts) do
    by_set = Enum.group_by(samples, & &1.set_id)

    set_ids
    |> Enum.reject(&(&1 == target_set_id))
    |> Enum.map(fn set_id ->
      set_samples = Map.get(by_set, set_id, [])
      expected = Map.get(endpoint_counts, set_id, 0)
      missing = max(expected - length(set_samples), 0)
      ok_samples = Enum.filter(set_samples, &match?(%{status: :ok}, &1))
      errors = length(set_samples) - length(ok_samples)
      free_bytes = sum(ok_samples, :free_bytes)
      min_free_bytes = min_field(ok_samples, :free_bytes)

      %{
        set_id: set_id,
        drive_expected: expected,
        drive_endpoints: length(set_samples),
        drive_missing: missing,
        drive_ok: length(ok_samples),
        drive_errors: errors,
        drive_free_bytes: free_bytes,
        drive_min_free_bytes: min_free_bytes,
        eligible?:
          expected > 0 and length(set_samples) == expected and missing == 0 and errors == 0 and
            length(ok_samples) == length(set_samples) and free_bytes >= bytes_required and
            min_free_bytes >= bytes_required
      }
    end)
  end

  defp choose_candidate([], target_set_id, _bytes_required),
    do: {:error, {:no_destination_set, target_set_id}}

  defp choose_candidate(candidates, target_set_id, bytes_required) do
    candidates
    |> Enum.filter(& &1.eligible?)
    |> case do
      [] ->
        healthy =
          Enum.filter(candidates, fn candidate ->
            candidate.drive_expected > 0 and candidate.drive_missing == 0 and
              candidate.drive_endpoints == candidate.drive_expected and
              candidate.drive_errors == 0 and
              candidate.drive_ok == candidate.drive_endpoints
          end)

        reason =
          if healthy == [] do
            :no_healthy_destination_set
          else
            :insufficient_destination_free_space
          end

        {:error, {reason, target_set_id, bytes_required, public_candidates(candidates)}}

      eligible ->
        {:ok,
         Enum.max_by(eligible, fn candidate ->
           {candidate.drive_free_bytes, candidate.drive_min_free_bytes, -candidate.set_id}
         end)}
    end
  end

  defp public_candidates(candidates) do
    Enum.map(candidates, fn candidate ->
      Map.take(candidate, [
        :set_id,
        :drive_expected,
        :drive_endpoints,
        :drive_missing,
        :drive_ok,
        :drive_errors,
        :drive_free_bytes,
        :drive_min_free_bytes,
        :eligible?
      ])
    end)
  end

  defp set_ids(opts) do
    case Keyword.fetch(opts, :topology) do
      {:ok, nil} ->
        {:error, :no_topology}

      {:ok, topology} ->
        {:ok, Topology.all_set_ids_from(topology)}

      :error ->
        if Topology.configured?(), do: {:ok, Topology.all_set_ids()}, else: {:error, :no_topology}
    end
  end

  defp endpoint_counts(opts, set_ids) do
    case Keyword.fetch(opts, :topology) do
      {:ok, topology} when not is_nil(topology) ->
        Map.new(set_ids, fn set_id ->
          {set_id, length(Topology.endpoints_from(topology, set_id))}
        end)

      _other ->
        if Topology.configured?() do
          Map.new(set_ids, fn set_id -> {set_id, length(Topology.endpoints(set_id))} end)
        else
          Map.new(set_ids, &{&1, 0})
        end
    end
  end

  defp validate_target(target_set_id, set_ids) do
    cond do
      target_set_id not in set_ids -> {:error, {:unknown_target_set_id, target_set_id, set_ids}}
      length(set_ids) < 2 -> {:error, {:no_destination_set, target_set_id}}
      true -> :ok
    end
  end

  defp sum(samples, key),
    do: Enum.reduce(samples, 0, fn sample, acc -> acc + Map.fetch!(sample, key) end)

  defp min_field([], _key), do: 0
  defp min_field(samples, key), do: samples |> Enum.map(&Map.fetch!(&1, key)) |> Enum.min()

  defp non_negative_int(value) when is_integer(value) and value >= 0, do: value
  defp non_negative_int(_value), do: 0
end
