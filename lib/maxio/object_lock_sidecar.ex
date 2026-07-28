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
    |> maybe_put_or_delete(attrs, :object_lock_mode, "object_lock_mode", & &1)
    |> maybe_put_or_delete(
      attrs,
      :object_lock_retain_until,
      "object_lock_retain_until",
      &datetime_to_iso8601/1
    )
    |> maybe_put_or_delete(attrs, :object_lock_legal_hold, "object_lock_legal_hold", & &1)
  end

  defp maybe_put_or_delete(entry, attrs, attr_key, sidecar_key, normalize) do
    case fetch_attr(attrs, attr_key) do
      {:ok, value} -> put_or_delete(entry, sidecar_key, normalize.(value))
      :error -> entry
    end
  end

  defp fetch_attr(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(attrs, Atom.to_string(key))
    end
  end

  defp put_or_delete(entry, key, nil), do: Map.delete(entry, key)
  defp put_or_delete(entry, key, value), do: Map.put(entry, key, value)

  defp datetime_to_iso8601(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp datetime_to_iso8601(value), do: value
end
