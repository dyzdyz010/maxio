defmodule Maxio.ObjectAclSidecar do
  @moduledoc """
  Metadata-only object ACL sidecar mutation.

  Kept as the ACL-specific API while delegating quorum-safe sidecar updates to
  `Maxio.ObjectMetadataSidecar`.
  """

  @type update_result ::
          {:ok, non_neg_integer()}
          | {:error, :not_found | :read_quorum | :write_quorum | :invalid_key | :no_topology}

  @spec update(String.t(), String.t(), String.t(), String.t(), map(), keyword()) ::
          update_result()
  def update(bucket, key, version_id, canned, grants_doc, opts \\ []) do
    Maxio.ObjectMetadataSidecar.update(
      bucket,
      key,
      version_id,
      fn entry ->
        entry
        |> Map.put("acl_canned", canned)
        |> Map.put("acl_grants", grants_doc)
      end,
      opts
    )
  end
end
