defmodule Maxio.Cluster.Rebalance.WriteRouting do
  @moduledoc """
  Write-time placement exclusions derived from decommission jobs.

  A decommission target remains excluded after data movement completes and after
  runtime-local topology apply. The route retires only after deployment config
  has been verified against the proposed removal topology.
  """

  import Ecto.Query

  require Logger

  alias Maxio.Cluster.Rebalance.Job
  alias Maxio.Repo

  @movement_statuses ~w(moving paused complete)
  @cleanup_statuses ~w(not_started moving failed complete)
  @test_env Mix.env() == :test

  @type route_map :: %{optional(non_neg_integer()) => non_neg_integer()}

  @doc "Return active target-set to destination-set write-routing exclusions."
  @spec active_routes(keyword()) :: {:ok, route_map()} | {:error, term()}
  def active_routes(opts \\ []) do
    case Keyword.fetch(opts, :decommission_write_routes) do
      {:ok, routes} -> normalize_routes(routes)
      :error -> load_routes()
    end
  end

  @doc "Apply active decommission write-routing exclusions to a resolved set id."
  @spec reroute_set(non_neg_integer() | nil, keyword()) ::
          {:ok, non_neg_integer() | nil} | {:error, term()}
  def reroute_set(nil, _opts), do: {:ok, nil}

  def reroute_set(set_id, opts) when is_integer(set_id) do
    with {:ok, routes} <- active_routes(opts) do
      follow_route(set_id, routes, MapSet.new())
    end
  end

  defp load_routes do
    routes =
      Job
      |> where([j], j.kind == "decommission")
      |> where([j], not is_nil(j.target_set_id))
      |> where([j], not is_nil(j.destination_set_id))
      |> where([j], j.target_set_id != j.destination_set_id)
      |> where([j], j.status != "canceled")
      |> where([j], j.data_movement_status in ^@movement_statuses)
      |> where([j], j.source_cleanup_status in ^@cleanup_statuses)
      |> where([j], j.topology_removal_deployment_status != "verified")
      |> order_by([j], desc: j.updated_at)
      |> select([j], {j.target_set_id, j.destination_set_id})
      |> Repo.all()
      |> Enum.reduce(%{}, fn {target, destination}, acc ->
        Map.put_new(acc, target, destination)
      end)

    {:ok, routes}
  rescue
    error in [DBConnection.OwnershipError, Postgrex.Error] ->
      handle_load_error(error, __STACKTRACE__)
  catch
    :exit, reason ->
      handle_load_exit(reason, __STACKTRACE__)
  end

  defp handle_load_error(error, stacktrace) do
    if @test_env do
      Logger.debug("decommission write routing skipped in test without queryable repo",
        action: :decommission_write_routing,
        reason: Exception.message(error)
      )

      {:ok, %{}}
    else
      Logger.error("decommission write routing query failed",
        action: :decommission_write_routing,
        reason: Exception.format(:error, error, stacktrace)
      )

      {:error, {:write_routing_unavailable, error.__struct__}}
    end
  end

  defp handle_load_exit(reason, stacktrace) do
    if @test_env do
      Logger.debug("decommission write routing skipped in test without queryable repo",
        action: :decommission_write_routing,
        reason: inspect(reason)
      )

      {:ok, %{}}
    else
      Logger.error("decommission write routing query failed",
        action: :decommission_write_routing,
        reason: Exception.format(:exit, reason, stacktrace)
      )

      {:error, {:write_routing_unavailable, {:exit, reason}}}
    end
  end

  defp normalize_routes(routes) when is_map(routes) do
    routes
    |> Enum.reduce_while({:ok, %{}}, fn
      {target, destination}, {:ok, acc} when is_integer(target) and is_integer(destination) ->
        {:cont, {:ok, Map.put(acc, target, destination)}}

      route, _acc ->
        {:halt, {:error, {:invalid_decommission_write_route, route}}}
    end)
  end

  defp normalize_routes(routes) when is_list(routes),
    do: routes |> Map.new() |> normalize_routes()

  defp normalize_routes(routes), do: {:error, {:invalid_decommission_write_routes, routes}}

  defp follow_route(set_id, routes, seen) do
    case Map.fetch(routes, set_id) do
      :error ->
        {:ok, set_id}

      {:ok, destination} when is_integer(destination) ->
        if MapSet.member?(seen, destination) do
          {:error, {:decommission_write_route_cycle, set_id, destination}}
        else
          follow_route(destination, routes, MapSet.put(seen, set_id))
        end

      {:ok, destination} ->
        {:error, {:invalid_decommission_write_destination, set_id, destination}}
    end
  end
end
