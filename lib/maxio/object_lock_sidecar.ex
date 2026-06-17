defmodule Maxio.ObjectLockSidecar do
  @moduledoc """
  Metadata-only Object Lock sidecar mutation.

  Object retention and legal hold updates must reach the sidecar authority, or
  delete enforcement under read=:sidecar could observe stale unlocked metadata.
  """

  @type update_result ::
          {:ok, non_neg_integer()}
          | {:error, :not_found | :read_quorum | :write_quorum | :invalid_key | :no_topology}

  @spec update(String.t(), String.t(), String.t(), map(), keyword()) :: update_result()
  def update(bucket, key, version_id, attrs, opts \\ []) do
    Maxio.ObjectMetadataSidecar.update(
      bucket,
      key,
      version_id,
      fn entry -> merge_object_lock_attrs(entry, attrs) end,
      opts
    )
  end

  defp merge_object_lock_attrs(entry, attrs) do
    entry
    |> put_or_delete("object_lock_mode", Map.get(attrs, :object_lock_mode))
    |> put_or_delete(
      "object_lock_retain_until",
      datetime_to_iso8601(Map.get(attrs, :object_lock_retain_until))
    )
    |> put_or_delete("object_lock_legal_hold", Map.get(attrs, :object_lock_legal_hold))
  end

  defp put_or_delete(entry, key, nil), do: Map.delete(entry, key)
  defp put_or_delete(entry, key, value), do: Map.put(entry, key, value)

  defp datetime_to_iso8601(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp datetime_to_iso8601(value), do: value
end
