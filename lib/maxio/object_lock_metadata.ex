defmodule Maxio.ObjectLockMetadata do
  @moduledoc """
  Conn-free object-lock metadata mutation helpers.

  S3 handlers and Console LiveViews both use this module so retention/legal-hold
  updates share the same object lock, PG/sidecar authority, and best-effort
  mirror semantics.
  """

  alias Maxio.{ObjectLockSidecar, ObjectMeta, Objects}
  alias Maxio.Objects.Object
  alias Maxio.S3.{Log, ObjectLock}

  @object_lock_fields [
    :object_lock_mode,
    :object_lock_retain_until,
    :object_lock_legal_hold
  ]

  @type mutation_error ::
          :not_found
          | :no_such_version
          | :locked
          | :lock_timeout
          | :slow_down_read
          | :slow_down_write
          | :invalid_key

  @type mutation_result :: {:ok, Object.t()} | {:error, mutation_error()}

  @spec enabled_for_bucket?(map()) :: boolean()
  def enabled_for_bucket?(%{name: bucket, versioning: "Enabled"}) when is_binary(bucket),
    do: ObjectLock.bucket_enabled?(bucket)

  def enabled_for_bucket?(_bucket), do: false

  @spec put_retention(String.t(), String.t(), String.t() | nil, map(), keyword()) ::
          mutation_result()
  def put_retention(bucket, key, version_id, attrs, opts \\ [])
      when is_binary(bucket) and is_binary(key) and is_map(attrs) do
    mutate_object_lock(bucket, key, version_id, attrs, true, opts)
  end

  @spec put_legal_hold(String.t(), String.t(), String.t() | nil, map(), keyword()) ::
          mutation_result()
  def put_legal_hold(bucket, key, version_id, attrs, opts \\ [])
      when is_binary(bucket) and is_binary(key) and is_map(attrs) do
    mutate_object_lock(bucket, key, version_id, attrs, false, opts)
  end

  defp mutate_object_lock(bucket, key, version_id, attrs, reject_locked?, opts) do
    case Maxio.Lock.with_object_lock({bucket, key}, fn ->
           do_mutate_object_lock(bucket, key, version_id, attrs, reject_locked?, opts)
         end) do
      {:ok, result} -> result
      {:error, :locked} -> {:error, :lock_timeout}
    end
  end

  defp do_mutate_object_lock(bucket, key, version_id, attrs, reject_locked?, opts) do
    with {:ok, object} <- fetch_object(bucket, key, version_id, opts),
         complete_attrs = merge_object_lock_attrs(object, attrs),
         :ok <- maybe_reject_locked_change(object, complete_attrs, reject_locked?, opts),
         :ok <- commit_object_lock(bucket, key, object.version_id, complete_attrs, opts) do
      {:ok, struct(object, complete_attrs)}
    end
  end

  defp fetch_object(bucket, key, version_id, opts) do
    case ObjectMeta.get_for_write(bucket, key, version_id, opts) do
      %Object{is_delete_marker: true} ->
        {:error, :not_found}

      %Object{} = object ->
        {:ok, object}

      {:error, :not_found} when is_binary(version_id) ->
        {:error, :no_such_version}

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, :read_quorum} ->
        {:error, :slow_down_read}
    end
  end

  defp merge_object_lock_attrs(%Object{} = object, requested_attrs) do
    Enum.reduce(@object_lock_fields, %{}, fn field, merged ->
      value =
        case fetch_attr(requested_attrs, field) do
          {:ok, requested} -> requested
          :error -> Map.fetch!(object, field)
        end

      Map.put(merged, field, value)
    end)
  end

  defp maybe_reject_locked_change(_object, _attrs, false, _opts), do: :ok

  defp maybe_reject_locked_change(%Object{} = object, attrs, true, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    current_mode = object.object_lock_mode
    current_retain_until = object.object_lock_retain_until
    requested_mode = attr_value(attrs, :object_lock_mode)
    requested_retain_until = attr_value(attrs, :object_lock_retain_until)

    # VERIFY-AT-IMPL: keep the existing conservative behavior for equal dates and
    # GOVERNANCE -> COMPLIANCE until those AWS/MinIO transition edges are revalidated.
    # Equal dates are not extensions; an active GOVERNANCE transition still needs bypass.
    cond do
      not active_retention?(current_retain_until, now) ->
        :ok

      same_mode_extension?(
        current_mode,
        current_retain_until,
        requested_mode,
        requested_retain_until
      ) ->
        :ok

      current_mode == "COMPLIANCE" ->
        {:error, :locked}

      current_mode == "GOVERNANCE" and Keyword.get(opts, :bypass_governance?, false) ->
        :ok

      current_mode == "GOVERNANCE" ->
        {:error, :locked}

      true ->
        :ok
    end
  end

  defp same_mode_extension?(mode, %DateTime{} = current_until, mode, %DateTime{} = new_until)
       when mode in ["GOVERNANCE", "COMPLIANCE"],
       do: DateTime.compare(new_until, current_until) == :gt

  defp same_mode_extension?(_current_mode, _current_until, _new_mode, _new_until), do: false

  defp active_retention?(%DateTime{} = retain_until, %DateTime{} = now),
    do: DateTime.compare(retain_until, now) == :gt

  defp active_retention?(_retain_until, _now), do: false

  defp attr_value(attrs, key) do
    case fetch_attr(attrs, key) do
      {:ok, value} -> value
      :error -> nil
    end
  end

  defp fetch_attr(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(attrs, Atom.to_string(key))
    end
  end

  defp commit_object_lock(bucket, key, version_id, attrs, opts) do
    case ObjectMeta.authoritative_source(:write, opts) do
      :sidecar -> commit_object_lock_sidecar(bucket, key, version_id, attrs, opts)
      _pg -> commit_object_lock_pg(bucket, key, version_id, attrs)
    end
  end

  defp commit_object_lock_sidecar(bucket, key, version_id, attrs, opts) do
    case ObjectLockSidecar.update(bucket, key, version_id, attrs, sidecar_update_opts(opts)) do
      {:ok, generation} ->
        best_effort_object_lock_index_update(bucket, key, version_id, attrs, generation, opts)

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, :read_quorum} ->
        {:error, :slow_down_read}

      {:error, reason} when reason in [:write_quorum, :no_topology] ->
        {:error, :slow_down_write}

      {:error, :invalid_key} ->
        {:error, :invalid_key}
    end
  end

  defp sidecar_update_opts(opts) do
    Keyword.take(opts, [
      :topology,
      :transport,
      :fsync,
      :rename_fun,
      :drives,
      :data_shards,
      :parity_shards,
      :block_size
    ])
  end

  defp commit_object_lock_pg(bucket, key, version_id, attrs) do
    case Objects.put_object_lock(bucket, key, version_id, attrs) do
      {:ok, _object} ->
        mirror_object_lock_sidecar(bucket, key, version_id, attrs)
        :ok

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  defp best_effort_object_lock_index_update(
         bucket,
         key,
         version_id,
         attrs,
         generation,
         opts
       ) do
    updater =
      Keyword.get(opts, :object_lock_index_updater, fn bucket,
                                                       key,
                                                       version_id,
                                                       attrs,
                                                       generation ->
        Objects.put_object_lock(bucket, key, version_id, attrs, generation)
      end)

    case updater.(bucket, key, version_id, attrs, generation) do
      {:ok, _object} ->
        :ok

      {:error, reason} ->
        log_object_lock_index_failure(bucket, key, version_id, reason)
    end
  rescue
    exception ->
      log_object_lock_index_failure(bucket, key, version_id, exception)
  catch
    kind, reason ->
      log_object_lock_index_failure(bucket, key, version_id, {kind, reason})
  end

  defp log_object_lock_index_failure(bucket, key, version_id, reason) do
    Log.warn("pg index object lock update failed (object lock durably stored in sidecar)",
      action: :put_object_lock_metadata,
      bucket: bucket,
      key: key,
      version_id: version_id,
      reason: inspect(reason)
    )

    :ok
  end

  defp mirror_object_lock_sidecar(bucket, key, version_id, attrs) do
    try do
      case ObjectLockSidecar.update(bucket, key, version_id, attrs) do
        {:ok, generation} ->
          sync_object_lock_generation(bucket, key, version_id, attrs, generation)

        {:error, reason} ->
          Log.warn("sidecar object lock mirror failed (PG remains authoritative)",
            action: :put_object_lock_metadata,
            bucket: bucket,
            key: key,
            version_id: version_id,
            reason: inspect(reason)
          )
      end
    rescue
      e ->
        Log.warn("sidecar object lock mirror raised (PG remains authoritative)",
          action: :put_object_lock_metadata,
          bucket: bucket,
          key: key,
          version_id: version_id,
          reason: inspect(e)
        )
    catch
      kind, reason ->
        Log.warn("sidecar object lock mirror caught (PG remains authoritative)",
          action: :put_object_lock_metadata,
          bucket: bucket,
          key: key,
          version_id: version_id,
          reason: inspect({kind, reason})
        )
    end
  end

  defp sync_object_lock_generation(bucket, key, version_id, attrs, generation) do
    case Objects.put_object_lock(bucket, key, version_id, attrs, generation) do
      {:ok, _object} ->
        :ok

      {:error, reason} ->
        Log.warn("pg object lock generation sync failed after sidecar mirror",
          action: :put_object_lock_metadata,
          bucket: bucket,
          key: key,
          version_id: version_id,
          reason: inspect(reason)
        )
    end
  end
end
