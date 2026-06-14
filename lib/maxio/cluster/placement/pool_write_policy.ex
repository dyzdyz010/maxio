defmodule Maxio.Cluster.Placement.PoolWritePolicy do
  @moduledoc """
  Pool-level write placement for expanded distributed deployments.

  MinIO writes new objects to available server pools with probability weighted
  by pool free space. This module implements that policy as an opt-in placement
  helper. It only chooses a pool and then hashes the object within that pool's
  stable set list; it does not migrate existing objects, mutate topology, or
  bypass explicit placement overrides used by rebalance/decommission tools.
  """

  alias Maxio.Cluster.{DriveStats, Topology}

  @type candidate :: %{
          pool_id: Topology.pool_id(),
          set_ids: [Topology.set_id()],
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
          pool_id: Topology.pool_id(),
          set_id: Topology.set_id(),
          source: :pool_free_space,
          drive_free_bytes: non_neg_integer(),
          candidates: [candidate()]
        }

  @doc """
  Select a write pool and set for a new object.

  Returns `:skip` when the policy is disabled. When enabled, telemetry must
  include every endpoint in every non-excluded candidate pool; missing or
  errored samples make that pool ineligible.
  """
  @spec select(String.t(), String.t(), Topology.t(), keyword()) ::
          :skip | {:ok, selection()} | {:error, term()}
  def select(bucket, key, topology, opts \\ []) do
    if enabled?(opts) do
      do_select(bucket, key, topology, opts)
    else
      :skip
    end
  end

  defp do_select(bucket, key, topology, opts) do
    pool_ids = Topology.pool_ids_from(topology)
    excluded_pool_ids = excluded_pool_ids(opts)
    excluded_set_ids = excluded_set_ids(opts)

    with {:ok, drive_stats} <- sample_drive_stats(opts),
         :ok <- ensure_drive_stats_available(drive_stats),
         candidates <-
           candidates(topology, pool_ids, excluded_pool_ids, excluded_set_ids, drive_stats, opts),
         {:ok, pool} <- choose_pool(bucket, key, candidates),
         {:ok, set_id} <- choose_set(bucket, key, pool) do
      {:ok,
       %{
         pool_id: pool.pool_id,
         set_id: set_id,
         source: :pool_free_space,
         drive_free_bytes: pool.drive_free_bytes,
         candidates: candidates
       }}
    end
  end

  defp enabled?(opts) do
    case option(opts, :pool_write_policy, :mode, :hash) do
      :weighted_free_space -> true
      "weighted_free_space" -> true
      _other -> false
    end
  end

  defp sample_drive_stats(opts) do
    case Keyword.fetch(opts, :drive_stats) do
      {:ok, stats} ->
        {:ok, stats}

      :error ->
        drive_stats_fun = Keyword.get(opts, :drive_stats_fun, &DriveStats.sample_topology/1)

        result =
          drive_stats_fun.(
            opts
            |> Keyword.take([:topology, :transport, :provider, :now_ms, :now_fun])
            |> Keyword.reject(fn {_key, value} -> is_nil(value) end)
          )

        {:ok, result}
    end
  rescue
    e -> {:error, {:drive_stats_crashed, Exception.message(e)}}
  catch
    kind, reason -> {:error, {:drive_stats_caught, kind, reason}}
  end

  defp ensure_drive_stats_available(%{status: :no_topology}), do: {:error, :no_topology}
  defp ensure_drive_stats_available(%{samples: samples}) when is_list(samples), do: :ok
  defp ensure_drive_stats_available(other), do: {:error, {:invalid_drive_stats, other}}

  defp candidates(
         topology,
         pool_ids,
         excluded_pool_ids,
         excluded_set_ids,
         %{samples: samples},
         opts
       ) do
    by_set = Enum.group_by(samples, & &1.set_id)
    excluded_set_ids = MapSet.new(excluded_set_ids)

    max_used_percent_x100 =
      option(opts, :pool_write_max_used_percent_x100, :max_used_percent_x100, 9_900)

    bytes_required = non_negative_int(Keyword.get(opts, :bytes_required, 0))

    pool_ids
    |> Enum.reject(&(&1 in excluded_pool_ids))
    |> Enum.flat_map(fn pool_id ->
      set_ids =
        topology
        |> Topology.set_ids_for_pool_from(pool_id)
        |> Enum.reject(&MapSet.member?(excluded_set_ids, &1))

      expected = endpoint_count(topology, set_ids)

      set_samples =
        set_ids
        |> Enum.flat_map(fn set_id -> Map.get(by_set, set_id, []) end)

      ok_samples = Enum.filter(set_samples, &match?(%{status: :ok}, &1))
      errors = length(set_samples) - length(ok_samples)
      missing = max(expected - length(set_samples), 0)
      free_bytes = sum(ok_samples, :free_bytes)
      min_free_bytes = min_field(ok_samples, :free_bytes)

      eligible? =
        expected > 0 and length(set_samples) == expected and missing == 0 and errors == 0 and
          length(ok_samples) == expected and free_bytes > 0 and
          Enum.all?(ok_samples, &under_high_water?(&1, max_used_percent_x100, bytes_required))

      if set_ids == [] do
        []
      else
        [
          %{
            pool_id: pool_id,
            set_ids: set_ids,
            drive_expected: expected,
            drive_endpoints: length(set_samples),
            drive_missing: missing,
            drive_ok: length(ok_samples),
            drive_errors: errors,
            drive_free_bytes: free_bytes,
            drive_min_free_bytes: min_free_bytes,
            eligible?: eligible?
          }
        ]
      end
    end)
  end

  defp choose_pool(_bucket, _key, []), do: {:error, {:no_eligible_pool, []}}

  defp choose_pool(bucket, key, candidates) do
    eligible = Enum.filter(candidates, & &1.eligible?)

    cond do
      Enum.any?(candidates, &telemetry_incomplete?/1) ->
        {:error, {:pool_telemetry_incomplete, public_candidates(candidates)}}

      true ->
        choose_eligible_pool(bucket, key, eligible, candidates)
    end
  end

  defp choose_eligible_pool(_bucket, _key, [], candidates),
    do: {:error, {:no_eligible_pool, public_candidates(candidates)}}

  defp choose_eligible_pool(bucket, key, eligible, _candidates) do
    total_weight = sum(eligible, :drive_free_bytes)
    slot = weighted_slot(bucket, key, total_weight)
    {:ok, pick_weighted(eligible, slot)}
  end

  defp choose_set(bucket, key, pool) do
    case pool.set_ids do
      [] ->
        {:error, {:empty_pool, pool.pool_id}}

      set_ids ->
        idx = :erlang.phash2(bucket <> "/" <> key, length(set_ids))
        {:ok, Enum.at(set_ids, idx)}
    end
  end

  defp pick_weighted(candidates, slot) do
    candidates
    |> Enum.reduce_while(slot, fn candidate, remaining ->
      weight = candidate.drive_free_bytes

      if remaining < weight do
        {:halt, candidate}
      else
        {:cont, remaining - weight}
      end
    end)
  end

  defp weighted_slot(_bucket, _key, total_weight) when total_weight <= 1, do: 0

  defp weighted_slot(bucket, key, total_weight) do
    <<n::unsigned-128, _rest::binary>> = :crypto.hash(:sha256, bucket <> "/" <> key)
    rem(n, total_weight)
  end

  defp endpoint_count(topology, set_ids) do
    Enum.reduce(set_ids, 0, fn set_id, acc ->
      acc + length(Topology.endpoints_from(topology, set_id))
    end)
  end

  defp telemetry_incomplete?(candidate) do
    candidate.drive_expected <= 0 or candidate.drive_missing > 0 or candidate.drive_errors > 0 or
      candidate.drive_endpoints != candidate.drive_expected or
      candidate.drive_ok != candidate.drive_expected
  end

  defp under_high_water?(
         %{free_bytes: free_bytes, capacity_bytes: capacity_bytes} = sample,
         max_used,
         bytes_required
       )
       when is_integer(capacity_bytes) and capacity_bytes > 0 and is_integer(free_bytes) do
    remaining_free = free_bytes - bytes_required
    remaining_free > 0 and used_percent_x100(sample, remaining_free) < max_used
  end

  defp under_high_water?(sample, max_used, _bytes_required) do
    case Map.get(sample, :used_percent_x100) do
      used when is_integer(used) -> used < max_used
      _other -> true
    end
  end

  defp used_percent_x100(%{capacity_bytes: capacity}, remaining_free) do
    used = max(capacity - remaining_free, 0)
    div(used * 10_000, capacity)
  end

  defp excluded_pool_ids(opts) do
    opts
    |> option(:pool_write_exclude_pool_ids, :exclude_pool_ids, [])
    |> List.wrap()
    |> Enum.flat_map(fn
      pool_id when is_integer(pool_id) -> [pool_id]
      pool_id when is_binary(pool_id) -> parse_int(pool_id)
      _other -> []
    end)
    |> Enum.uniq()
  end

  defp excluded_set_ids(opts) do
    opts
    |> Keyword.get(:pool_write_exclude_set_ids, [])
    |> List.wrap()
    |> Enum.flat_map(fn
      set_id when is_integer(set_id) -> [set_id]
      set_id when is_binary(set_id) -> parse_int(set_id)
      _other -> []
    end)
    |> Enum.uniq()
  end

  defp public_candidates(candidates) do
    Enum.map(candidates, fn candidate ->
      Map.take(candidate, [
        :pool_id,
        :set_ids,
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

  defp option(opts, direct_key, config_key, default) do
    case Keyword.fetch(opts, direct_key) do
      {:ok, value} ->
        value

      :error ->
        :maxio
        |> Application.get_env(:pool_write_policy, [])
        |> Keyword.get(config_key, default)
    end
  end

  defp parse_int(value) do
    case Integer.parse(value) do
      {int, ""} -> [int]
      _other -> []
    end
  end

  defp sum(samples, key),
    do: Enum.reduce(samples, 0, fn sample, acc -> acc + Map.fetch!(sample, key) end)

  defp min_field([], _key), do: 0
  defp min_field(samples, key), do: samples |> Enum.map(&Map.fetch!(&1, key)) |> Enum.min()

  defp non_negative_int(value) when is_integer(value) and value >= 0, do: value
  defp non_negative_int(_value), do: 0
end
