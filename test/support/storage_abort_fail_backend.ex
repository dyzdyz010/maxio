defmodule Maxio.Test.StorageAbortFailBackend do
  @moduledoc false
  @behaviour Maxio.Storage.Backend

  alias Maxio.Storage.FS

  @impl true
  def put(bucket, key, version_id, chunks, opts),
    do: FS.put(bucket, key, version_id, chunks, opts)

  @impl true
  def get(bucket, key, version_id, range, opts),
    do: FS.get(bucket, key, version_id, range, opts)

  @impl true
  def stat(bucket, key, version_id, opts),
    do: FS.stat(bucket, key, version_id, opts)

  @impl true
  def delete(bucket, key, version_id, opts),
    do: FS.delete(bucket, key, version_id, opts)

  @impl true
  def put_bucket(bucket), do: FS.put_bucket(bucket)

  @impl true
  def delete_bucket(bucket), do: FS.delete_bucket(bucket)

  @impl true
  def put_part(bucket, key, upload_id, part_number, chunks, opts),
    do: FS.put_part(bucket, key, upload_id, part_number, chunks, opts)

  @impl true
  def get_part_stream(bucket, key, upload_id, part_number, opts),
    do: FS.get_part_stream(bucket, key, upload_id, part_number, opts)

  @impl true
  def assemble(bucket, key, upload_id, part_numbers, opts),
    do: FS.assemble(bucket, key, upload_id, part_numbers, opts)

  @impl true
  def abort_upload(_bucket, _key, _upload_id, _opts), do: raise("abort failed")

  @impl true
  def put_delete_marker(bucket, key, version_id, entry_opts, opts),
    do: FS.put_delete_marker(bucket, key, version_id, entry_opts, opts)

  @impl true
  def delete_version(bucket, key, version_id, opts),
    do: FS.delete_version(bucket, key, version_id, opts)

  @impl true
  def put_notification_ledgers(bucket, key, entries, opts),
    do: FS.put_notification_ledgers(bucket, key, entries, opts)

  @impl true
  def list_notification_ledgers(bucket, key_filter, opts),
    do: FS.list_notification_ledgers(bucket, key_filter, opts)

  @impl true
  def delete_notification_ledgers(bucket, key, ids, opts),
    do: FS.delete_notification_ledgers(bucket, key, ids, opts)

  @impl true
  def claim_epoch(target, token, operation, opts),
    do: FS.claim_epoch(target, token, operation, opts)

  @impl true
  def current_epoch(target, opts), do: FS.current_epoch(target, opts)

  @impl true
  def restore_if_current(ctx, opts), do: FS.restore_if_current(ctx, opts)

  @impl true
  def finalize_if_current(ctx, opts), do: FS.finalize_if_current(ctx, opts)
end
