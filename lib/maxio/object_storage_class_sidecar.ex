defmodule Maxio.ObjectStorageClassSidecar do
  @moduledoc """
  Metadata-only object storage-class sidecar mutation.

  Lifecycle transitions change S3-visible metadata, so sidecar write authority
  must observe the same storage class as the PG index.
  """

  @type update_result ::
          {:ok, non_neg_integer()}
          | {:error, :not_found | :read_quorum | :write_quorum | :invalid_key | :no_topology}

  @spec update(String.t(), String.t(), String.t(), String.t(), keyword()) :: update_result()
  def update(bucket, key, version_id, storage_class, opts \\ [])
      when is_binary(storage_class) do
    Maxio.ObjectMetadataSidecar.update(
      bucket,
      key,
      version_id,
      fn entry -> Map.put(entry, "storage_class", storage_class) end,
      opts
    )
  end
end
