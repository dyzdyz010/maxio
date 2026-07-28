defmodule Maxio.ObjectRestoreSidecar do
  @moduledoc """
  Metadata-only object restore-state sidecar mutation.

  RestoreObject changes S3-visible metadata only in the current maxio tiering
  model. The bytes remain in place; sidecar write authority must still observe
  the restore status that HEAD/GET expose.
  """

  @type update_result ::
          {:ok, non_neg_integer()}
          | {:error, :not_found | :read_quorum | :write_quorum | :invalid_key | :no_topology}

  @spec update(String.t(), String.t(), String.t(), map(), keyword()) :: update_result()
  def update(bucket, key, version_id, attrs, opts \\ []) when is_map(attrs) do
    notification_outbox = Keyword.get(opts, :notification_outbox, [])

    Maxio.ObjectMetadataSidecar.update(
      bucket,
      key,
      version_id,
      fn entry ->
        entry
        |> Map.put("restore_status", Map.get(attrs, :restore_status))
        |> Map.put("restore_expiry", datetime_to_iso8601(Map.get(attrs, :restore_expiry)))
        |> append_notification_outbox(notification_outbox)
      end,
      opts
    )
  end

  defp append_notification_outbox(entry, []), do: entry

  defp append_notification_outbox(entry, notification_outbox) when is_list(notification_outbox) do
    Map.update(entry, "notification_outbox", notification_outbox, fn
      existing when is_list(existing) -> existing ++ notification_outbox
      _other -> notification_outbox
    end)
  end

  defp datetime_to_iso8601(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp datetime_to_iso8601(nil), do: nil
end
