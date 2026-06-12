defmodule Maxio.Cluster.Scrubber.Usage do
  @moduledoc """
  Lightweight bucket usage snapshot cache maintained by the operational scrubber.

  The cache is intentionally best-effort: request paths keep using the authoritative
  metadata/storage contracts, while operators can inspect the latest scan-derived
  object count and byte total.
  """

  @key {__MODULE__, :buckets}

  @type snapshot :: %{
          object_count: non_neg_integer(),
          total_size: non_neg_integer(),
          scanned_at: DateTime.t()
        }

  @spec put(String.t(), snapshot()) :: :ok
  def put(bucket, snapshot) when is_binary(bucket) and is_map(snapshot) do
    buckets =
      @key
      |> :persistent_term.get(%{})
      |> Map.put(bucket, snapshot)

    :persistent_term.put(@key, buckets)
    :ok
  end

  @spec get(String.t()) :: snapshot() | nil
  def get(bucket) when is_binary(bucket) do
    @key
    |> :persistent_term.get(%{})
    |> Map.get(bucket)
  end

  @spec all() :: %{optional(String.t()) => snapshot()}
  def all, do: :persistent_term.get(@key, %{})

  @spec delete(String.t()) :: :ok
  def delete(bucket) when is_binary(bucket) do
    buckets =
      @key
      |> :persistent_term.get(%{})
      |> Map.delete(bucket)

    :persistent_term.put(@key, buckets)
    :ok
  end

  @spec clear() :: :ok
  def clear do
    :persistent_term.erase(@key)
    :ok
  end
end
