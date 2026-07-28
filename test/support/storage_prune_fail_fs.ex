defmodule Maxio.Test.StoragePruneFailFS do
  @moduledoc false

  @behaviour Maxio.Storage.Backend

  alias Maxio.Storage.FS

  defdelegate local_topology(opts \\ []), to: FS
  defdelegate put(bucket, key, version_id, chunks, opts), to: FS
  defdelegate get(bucket, key, version_id, range, opts), to: FS
  defdelegate stat(bucket, key, version_id, opts), to: FS
  defdelegate delete(bucket, key, version_id, opts), to: FS
  defdelegate put_bucket(bucket), to: FS
  defdelegate delete_bucket(bucket), to: FS
  defdelegate put_part(bucket, key, upload_id, part_number, chunks, opts), to: FS
  defdelegate get_part_stream(bucket, key, upload_id, part_number, opts), to: FS
  defdelegate assemble(bucket, key, upload_id, part_numbers, opts), to: FS
  defdelegate abort_upload(bucket, key, upload_id, opts), to: FS
  defdelegate put_delete_marker(bucket, key, version_id, entry_opts, opts), to: FS
  defdelegate delete_version(bucket, key, version_id, opts), to: FS
  defdelegate put_notification_ledgers(bucket, key, entries, opts), to: FS
  defdelegate list_notification_ledgers(bucket, key_filter, opts), to: FS
  defdelegate claim_epoch(target, token, operation, opts), to: FS
  defdelegate current_epoch(target, opts), to: FS
  defdelegate restore_if_current(ctx, opts), to: FS
  defdelegate finalize_if_current(ctx, opts), to: FS

  def delete_notification_ledgers(bucket, key, ids, opts) do
    case Application.get_env(:maxio, :notification_ledger_delete_mode) do
      :fail -> {:error, :injected_notification_ledger_prune_failure}
      _other -> FS.delete_notification_ledgers(bucket, key, ids, opts)
    end
  end
end
