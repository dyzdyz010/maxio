defmodule Maxio.Cluster.IOPressure do
  @moduledoc """
  Pressure signal facade for background maintenance throttles.

  This keeps scrubber/fresh-drive pacing independent from the concrete counters
  used underneath. The value is a best-effort load unit, not an admission-control
  decision.
  """

  @type source :: :s3_in_flight | :storage_ops | :combined

  @doc "Return the current pressure count for `source`."
  @spec count(source() | String.t() | nil) :: non_neg_integer()
  def count(source) do
    case normalize_source(source) do
      :s3_in_flight -> Maxio.S3.InFlight.count()
      :storage_ops -> Maxio.Cluster.DriveIO.active_count()
      :combined -> Maxio.S3.InFlight.count() + Maxio.Cluster.DriveIO.active_count()
    end
  end

  @doc "Return the default combined S3 handler + storage operation pressure count."
  @spec combined_count() :: non_neg_integer()
  def combined_count, do: count(:combined)

  @doc "Normalize user/config source values."
  @spec normalize_source(source() | String.t() | nil) :: source()
  def normalize_source(:s3_in_flight), do: :s3_in_flight
  def normalize_source(:storage_ops), do: :storage_ops
  def normalize_source(:combined), do: :combined
  def normalize_source("s3-in-flight"), do: :s3_in_flight
  def normalize_source("s3_in_flight"), do: :s3_in_flight
  def normalize_source("storage-ops"), do: :storage_ops
  def normalize_source("storage_ops"), do: :storage_ops
  def normalize_source("combined"), do: :combined
  def normalize_source(_source), do: :combined
end
