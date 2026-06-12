defmodule Maxio.Cluster.IOPressure do
  @moduledoc """
  Pressure signal facade for background maintenance throttles.

  This keeps scrubber/fresh-drive pacing independent from the concrete counters
  used underneath. The value is a best-effort load unit, not an admission-control
  decision.
  """

  @type local_source :: :s3_in_flight | :storage_ops | :combined
  @type source ::
          local_source()
          | :cluster_s3_in_flight
          | :cluster_storage_ops
          | :cluster_combined

  @doc "Return the current pressure count for `source`."
  @spec count(source() | String.t() | nil, keyword()) :: non_neg_integer()
  def count(source, opts \\ []) do
    case normalize_source(source) do
      source when source in [:s3_in_flight, :storage_ops, :combined] ->
        local_count(source)

      :cluster_s3_in_flight ->
        Maxio.Cluster.PressureAggregator.count(:s3_in_flight, opts)

      :cluster_storage_ops ->
        Maxio.Cluster.PressureAggregator.count(:storage_ops, opts)

      :cluster_combined ->
        Maxio.Cluster.PressureAggregator.count(:combined, opts)
    end
  end

  @doc "Return the current node-local pressure count for `source`."
  @spec local_count(local_source() | String.t() | nil) :: non_neg_integer()
  def local_count(source) do
    case normalize_local_source(source) do
      :s3_in_flight -> Maxio.S3.InFlight.count()
      :storage_ops -> Maxio.Cluster.DriveIO.active_count()
      :combined -> Maxio.S3.InFlight.count() + Maxio.Cluster.DriveIO.active_count()
    end
  end

  @doc "Return a node-local pressure snapshot suitable for peer aggregation."
  @spec local_snapshot() :: %{local_source() => non_neg_integer()}
  def local_snapshot do
    s3_in_flight = local_count(:s3_in_flight)
    storage_ops = local_count(:storage_ops)

    %{
      s3_in_flight: s3_in_flight,
      storage_ops: storage_ops,
      combined: s3_in_flight + storage_ops
    }
  end

  @doc "Return the default combined S3 handler + storage operation pressure count."
  @spec combined_count() :: non_neg_integer()
  def combined_count, do: count(:combined)

  @doc "Return the default cluster combined pressure count."
  @spec cluster_combined_count() :: non_neg_integer()
  def cluster_combined_count, do: count(:cluster_combined)

  @doc "Normalize user/config source values."
  @spec normalize_source(source() | String.t() | nil) :: source()
  def normalize_source(:s3_in_flight), do: :s3_in_flight
  def normalize_source(:storage_ops), do: :storage_ops
  def normalize_source(:combined), do: :combined
  def normalize_source(:cluster_s3_in_flight), do: :cluster_s3_in_flight
  def normalize_source(:cluster_storage_ops), do: :cluster_storage_ops
  def normalize_source(:cluster_combined), do: :cluster_combined
  def normalize_source("s3-in-flight"), do: :s3_in_flight
  def normalize_source("s3_in_flight"), do: :s3_in_flight
  def normalize_source("storage-ops"), do: :storage_ops
  def normalize_source("storage_ops"), do: :storage_ops
  def normalize_source("combined"), do: :combined
  def normalize_source("cluster-s3-in-flight"), do: :cluster_s3_in_flight
  def normalize_source("cluster_s3_in_flight"), do: :cluster_s3_in_flight
  def normalize_source("cluster-storage-ops"), do: :cluster_storage_ops
  def normalize_source("cluster_storage_ops"), do: :cluster_storage_ops
  def normalize_source("cluster-combined"), do: :cluster_combined
  def normalize_source("cluster_combined"), do: :cluster_combined
  def normalize_source(_source), do: :combined

  @doc "Normalize any source to its node-local base source."
  @spec normalize_local_source(source() | String.t() | nil) :: local_source()
  def normalize_local_source(source) do
    case normalize_source(source) do
      :cluster_s3_in_flight -> :s3_in_flight
      :cluster_storage_ops -> :storage_ops
      :cluster_combined -> :combined
      source -> source
    end
  end
end
