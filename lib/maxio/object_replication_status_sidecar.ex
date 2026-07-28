defmodule Maxio.ObjectReplicationStatusSidecar do
  @moduledoc """
  Metadata-only replication-status sidecar mutation.

  PG remains the default write authority for the replication delivery v1 path,
  but source object terminal status must be mirrored to the object sidecar so
  scanner/reconcile cannot later replay a stale `PENDING` value.
  """

  @type update_result ::
          {:ok, non_neg_integer()}
          | {:error, :not_found | :read_quorum | :write_quorum | :invalid_key | :no_topology}

  @spec update(String.t(), String.t(), String.t(), String.t() | nil, keyword()) ::
          update_result()
  def update(bucket, key, version_id, status, opts \\ []) do
    Maxio.ObjectMetadataSidecar.update(
      bucket,
      key,
      version_id,
      fn entry -> Map.put(entry, "replication_status", status) end,
      opts
    )
  end
end
