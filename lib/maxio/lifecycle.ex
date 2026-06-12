defmodule Maxio.Lifecycle do
  @moduledoc """
  Deterministic S3 lifecycle executor.

  This module executes the lifecycle actions that maxio can perform without guessing hidden
  AWS state: current-version Expiration, ExpiredObjectDeleteMarker cleanup, and
  NoncurrentVersionExpiration, and AbortIncompleteMultipartUpload. Transition remains an explicit
  defer until maxio has tiering backends to move objects into.
  """

  import Ecto.Query

  alias Maxio.Buckets
  alias Maxio.Buckets.Bucket
  alias Maxio.BucketConfigs
  alias Maxio.Multipart
  alias Maxio.Multipart.Upload
  alias Maxio.Objects
  alias Maxio.Objects.Object
  alias Maxio.Repo
  alias Maxio.S3.Log
  alias Maxio.Storage
  alias Maxio.Versioning.VersionId

  @type summary :: %{
          buckets_scanned: non_neg_integer(),
          objects_expired: non_neg_integer(),
          noncurrent_versions_expired: non_neg_integer(),
          delete_markers_removed: non_neg_integer(),
          multipart_uploads_aborted: non_neg_integer(),
          unsupported_rules: non_neg_integer(),
          errors: [map()]
        }

  @doc """
  Run one lifecycle sweep.

  Options:

    * `:bucket` - limit the sweep to one bucket name.
    * `:now` - deterministic clock for tests; defaults to `DateTime.utc_now/0`.
    * `:dry_run` - count eligible actions without mutating storage or metadata.
    * `:authoritative_source` - test override passed to object delete helpers.
  """
  @spec run(keyword()) :: summary()
  def run(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    dry_run? = Keyword.get(opts, :dry_run, false)

    opts
    |> buckets()
    |> Enum.reduce(empty_summary(), fn bucket, summary ->
      run_bucket(bucket, summary, now, dry_run?, opts)
    end)
    |> Map.update!(:errors, &Enum.reverse/1)
  end

  defp buckets(opts) do
    case Keyword.get(opts, :bucket) do
      nil ->
        Buckets.list()

      bucket_name ->
        case Buckets.lookup(bucket_name) do
          {:ok, bucket} -> [bucket]
          {:error, :not_found} -> []
        end
    end
  end

  defp empty_summary do
    %{
      buckets_scanned: 0,
      objects_expired: 0,
      noncurrent_versions_expired: 0,
      delete_markers_removed: 0,
      multipart_uploads_aborted: 0,
      unsupported_rules: 0,
      errors: []
    }
  end

  defp run_bucket(%Bucket{} = bucket, summary, now, dry_run?, opts) do
    case BucketConfigs.get(bucket.name, :lifecycle) do
      {:ok, rules} ->
        rules = Enum.filter(rules, &(&1["status"] == "Enabled"))

        summary
        |> incr(:buckets_scanned)
        |> count_unsupported(rules)
        |> run_object_actions(bucket, rules, now, dry_run?, opts)
        |> run_multipart_abort_actions(bucket, rules, now, dry_run?)

      :none ->
        incr(summary, :buckets_scanned)
    end
  end

  defp count_unsupported(summary, rules) do
    unsupported =
      Enum.count(rules, fn rule ->
        rule["transition_days"] != nil or rule["transition_storage_class"] != nil or
          rule["transition_date"] != nil or rule["noncurrent_transition_days"] != nil or
          rule["noncurrent_transition_newer_noncurrent_versions"] != nil or
          rule["noncurrent_transition_storage_class"] != nil
      end)

    update_in(summary.unsupported_rules, &(&1 + unsupported))
  end

  defp run_object_actions(summary, %Bucket{} = bucket, rules, now, dry_run?, opts) do
    summary
    |> run_current_object_actions(bucket, rules, now, dry_run?, opts)
    |> run_noncurrent_version_actions(bucket, rules, now, dry_run?, opts)
  end

  defp run_current_object_actions(summary, %Bucket{} = bucket, rules, now, dry_run?, opts) do
    bucket.name
    |> latest_objects()
    |> Enum.reduce(summary, fn object, acc ->
      cond do
        object.is_delete_marker and expired_delete_marker?(object, rules, now) ->
          if only_version?(object) do
            apply_action(acc, :delete_markers_removed, object, dry_run?, fn ->
              delete_version(bucket.name, object.key, object.version_id, opts)
            end)
          else
            acc
          end

        not object.is_delete_marker and current_expired?(object, rules, now) ->
          apply_action(acc, :objects_expired, object, dry_run?, fn ->
            expire_current_object(bucket, object, opts)
          end)

        true ->
          acc
      end
    end)
  end

  defp run_noncurrent_version_actions(summary, %Bucket{} = bucket, rules, now, dry_run?, opts) do
    bucket.name
    |> noncurrent_versions()
    |> Enum.reduce(summary, fn candidate, acc ->
      if noncurrent_expired?(candidate, rules, now) do
        object = candidate.object

        apply_action(acc, :noncurrent_versions_expired, object, dry_run?, fn ->
          delete_version(bucket.name, object.key, object.version_id, opts)
        end)
      else
        acc
      end
    end)
  end

  defp latest_objects(bucket_name) do
    from(o in Object,
      where: o.bucket_name == ^bucket_name and o.is_latest == true,
      order_by: [asc: o.key]
    )
    |> Repo.all()
  end

  defp noncurrent_versions(bucket_name) do
    from(o in Object,
      where: o.bucket_name == ^bucket_name,
      order_by: [asc: o.key, desc: o.is_latest, desc: o.inserted_at, desc: o.version_id]
    )
    |> Repo.all()
    |> Enum.chunk_by(& &1.key)
    |> Enum.flat_map(&annotate_noncurrent_versions/1)
  end

  defp annotate_noncurrent_versions(versions) do
    {candidates, _newer_version, _newer_noncurrent_count} =
      Enum.reduce(versions, {[], nil, 0}, fn object,
                                             {candidates, newer_version, newer_noncurrent_count} ->
        if object.is_latest do
          {candidates, object, newer_noncurrent_count}
        else
          candidate = %{
            object: object,
            noncurrent_since: if(newer_version, do: version_created_at(newer_version)),
            newer_noncurrent_versions: newer_noncurrent_count
          }

          {[candidate | candidates], object, newer_noncurrent_count + 1}
        end
      end)

    Enum.reverse(candidates)
  end

  defp current_expired?(%Object{} = object, rules, now) do
    Enum.any?(rules, fn rule ->
      current_expiration_action?(rule) and object_matches_rule?(object, rule) and
        age_expired?(version_created_at(object), rule, now)
    end)
  end

  defp expired_delete_marker?(%Object{} = object, rules, now) do
    Enum.any?(rules, fn rule ->
      object_matches_rule?(object, rule) and
        (rule["expired_object_delete_marker"] == true or
           (current_expiration_action?(rule) and
              age_expired?(version_created_at(object), rule, now)))
    end)
  end

  defp noncurrent_expired?(%{object: %Object{} = object} = candidate, rules, now) do
    Enum.any?(rules, fn rule ->
      noncurrent_expiration_action?(rule) and object_matches_rule?(object, rule) and
        noncurrent_age_expired?(candidate, rule, now) and
        newer_noncurrent_versions_exceeded?(candidate, rule)
    end)
  end

  defp current_expiration_action?(rule),
    do: rule["expiration_days"] != nil or rule["expiration_date"] not in [nil, ""]

  defp noncurrent_expiration_action?(rule) do
    valid_noncurrent_days?(rule["noncurrent_days"]) or
      valid_newer_noncurrent_versions?(rule["newer_noncurrent_versions"])
  end

  defp valid_noncurrent_days?(value), do: is_integer(value) and value >= 1

  defp valid_newer_noncurrent_versions?(nil), do: false
  defp valid_newer_noncurrent_versions?(value), do: is_integer(value) and value in 1..100

  defp object_matches_rule?(%Object{} = object, rule) do
    rule_safe?(rule) and prefix_matches?(object.key, rule) and
      size_matches?(object.size || 0, rule) and
      tags_match?(object.tags || %{}, rule)
  end

  defp rule_safe?(rule), do: (rule["parse_errors"] || []) == []

  defp prefix_matches?(key, rule) do
    prefix = rule["filter_prefix"] || rule["prefix"] || ""
    String.starts_with?(key, prefix)
  end

  defp size_matches?(size, rule) do
    gt = rule["filter_size_gt"]
    lt = rule["filter_size_lt"]

    cond do
      gt != nil and not is_integer(gt) -> false
      lt != nil and not is_integer(lt) -> false
      gt != nil and gt < 0 -> false
      lt != nil and lt < 1 -> false
      true -> (gt == nil or size > gt) and (lt == nil or size < lt)
    end
  end

  defp tags_match?(tags, rule) do
    case rule["filter_tags"] || [] do
      filter_tags when is_list(filter_tags) ->
        Enum.all?(filter_tags, fn
          %{"key" => key, "value" => value} when is_binary(key) ->
            Map.get(tags, key) == (value || "")

          %{"Key" => key, "Value" => value} when is_binary(key) ->
            Map.get(tags, key) == (value || "")

          _other ->
            false
        end)

      _other ->
        false
    end
  end

  defp age_expired?(updated_at, %{"expiration_days" => days}, now)
       when is_integer(days) and days >= 1 do
    threshold = lifecycle_days_threshold(updated_at, days)
    DateTime.compare(now, threshold) != :lt
  end

  defp age_expired?(_updated_at, %{"expiration_date" => date}, now) when is_binary(date) do
    case parse_expiration_datetime(date) do
      {:ok, expires_at} -> DateTime.compare(now, expires_at) != :lt
      :error -> false
    end
  end

  defp age_expired?(_updated_at, _rule, _now), do: false

  defp noncurrent_age_expired?(%{noncurrent_since: nil}, %{"noncurrent_days" => days}, _now)
       when is_integer(days),
       do: false

  defp noncurrent_age_expired?(
         %{noncurrent_since: noncurrent_since},
         %{"noncurrent_days" => days},
         now
       )
       when is_integer(days) and days >= 1 do
    threshold = lifecycle_days_threshold(noncurrent_since, days)
    DateTime.compare(now, threshold) != :lt
  end

  defp noncurrent_age_expired?(_candidate, %{"noncurrent_days" => nil}, _now), do: true
  defp noncurrent_age_expired?(_candidate, _rule, _now), do: false

  defp newer_noncurrent_versions_exceeded?(
         %{newer_noncurrent_versions: count},
         %{"newer_noncurrent_versions" => retain}
       )
       when is_integer(retain) and retain in 1..100,
       do: count > retain

  defp newer_noncurrent_versions_exceeded?(_candidate, %{"newer_noncurrent_versions" => nil}),
    do: true

  defp newer_noncurrent_versions_exceeded?(_candidate, _rule), do: false

  defp version_created_at(%Object{} = object), do: object.inserted_at || object.updated_at

  defp lifecycle_days_threshold(%DateTime{} = from, days) do
    from
    |> DateTime.add(days * 86_400, :second)
    |> ceil_to_midnight_utc()
  end

  defp ceil_to_midnight_utc(%DateTime{} = dt) do
    dt = DateTime.shift_zone!(dt, "Etc/UTC")
    midnight = DateTime.new!(DateTime.to_date(dt), ~T[00:00:00], "Etc/UTC")

    if DateTime.compare(dt, midnight) == :eq do
      midnight
    else
      dt
      |> DateTime.to_date()
      |> Date.add(1)
      |> DateTime.new!(~T[00:00:00], "Etc/UTC")
    end
  end

  defp parse_expiration_datetime(date) do
    case DateTime.from_iso8601(date) do
      {:ok, dt, _offset} ->
        {:ok, dt}

      _ ->
        with <<ymd::binary-size(10), _rest::binary>> <- date,
             {:ok, d} <- Date.from_iso8601(ymd),
             {:ok, dt} <- DateTime.new(d, ~T[00:00:00], "Etc/UTC") do
          {:ok, dt}
        else
          _ -> :error
        end
    end
  end

  defp only_version?(%Object{} = object) do
    count =
      from(o in Object, where: o.bucket_name == ^object.bucket_name and o.key == ^object.key)
      |> Repo.aggregate(:count, :id)

    count == 1
  end

  defp expire_current_object(%Bucket{versioning: versioning} = bucket, %Object{} = object, opts) do
    case versioning do
      "Enabled" ->
        put_delete_marker(bucket.name, object.key, VersionId.generate(), opts)

      "Suspended" ->
        put_delete_marker(bucket.name, object.key, "null", opts)

      _unversioned ->
        hard_delete_object(bucket.name, object.key)
    end
  end

  defp hard_delete_object(bucket, key) do
    case Maxio.Lock.with_object_lock({bucket, key}, fn ->
           :ok = Objects.delete_metadata(bucket, key)
           _ = Storage.delete(bucket, key, "null")
           :ok
         end) do
      {:ok, :ok} -> :ok
      {:error, :locked} -> {:error, :locked}
    end
  end

  defp put_delete_marker(bucket, key, version_id, opts) do
    case Maxio.Lock.with_object_lock({bucket, key}, fn ->
           case Maxio.ObjectMeta.authoritative_source(:write, opts) do
             :sidecar -> put_delete_marker_sidecar(bucket, key, version_id)
             _pg -> put_delete_marker_pg(bucket, key, version_id)
           end
         end) do
      {:ok, result} -> result
      {:error, :locked} -> {:error, :locked}
    end
  end

  defp put_delete_marker_sidecar(bucket, key, version_id) do
    with :ok <- Storage.put_delete_marker(bucket, key, version_id) do
      case Objects.insert_delete_marker_index(bucket, key, version_id) do
        :ok ->
          :ok

        {:error, reason} ->
          Log.error("pg lifecycle delete-marker index update failed",
            action: :lifecycle,
            bucket: bucket,
            key: key,
            reason: inspect(reason)
          )

          {:error, {:pg_index_update_failed, reason}}
      end
    end
  end

  defp put_delete_marker_pg(bucket, key, version_id) do
    {:ok, _} = Objects.insert_delete_marker_with_id(bucket, key, version_id)
    if version_id == "null", do: _ = Storage.delete(bucket, key, "null")
    _ = Storage.put_delete_marker(bucket, key, version_id)
    :ok
  end

  defp delete_version(bucket, key, version_id, opts) do
    case Maxio.Lock.with_object_lock({bucket, key}, fn ->
           case Maxio.ObjectMeta.authoritative_source(:write, opts) do
             :sidecar -> delete_version_sidecar(bucket, key, version_id)
             _pg -> delete_version_pg(bucket, key, version_id)
           end
         end) do
      {:ok, result} -> result
      {:error, :locked} -> {:error, :locked}
    end
  end

  defp delete_version_sidecar(bucket, key, version_id) do
    with :ok <- Storage.delete_version(bucket, key, version_id) do
      case Objects.delete_version_index(bucket, key, version_id) do
        :ok ->
          :ok

        {:error, reason} ->
          Log.error("pg lifecycle version-delete index update failed",
            action: :lifecycle,
            bucket: bucket,
            key: key,
            reason: inspect(reason)
          )

          {:error, {:pg_index_delete_failed, reason}}
      end
    end
  end

  defp delete_version_pg(bucket, key, version_id) do
    case Objects.delete_version(bucket, key, version_id) do
      {:ok, _} ->
        _ = Storage.delete(bucket, key, version_id)
        :ok

      {:error, :not_found} ->
        :ok
    end
  end

  defp run_multipart_abort_actions(summary, %Bucket{} = bucket, rules, now, dry_run?) do
    bucket.name
    |> pending_uploads()
    |> Enum.reduce(summary, fn upload, acc ->
      if Enum.any?(rules, &abort_upload_expired?(upload, &1, now)) do
        apply_upload_action(acc, upload, dry_run?)
      else
        acc
      end
    end)
  end

  defp pending_uploads(bucket_name) do
    from(u in Upload, where: u.bucket_name == ^bucket_name, order_by: [asc: u.key])
    |> Repo.all()
  end

  defp abort_upload_expired?(%Upload{} = upload, rule, now) do
    days = rule["abort_days_after_initiation"]

    is_integer(days) and days >= 1 and mpu_rule_safe?(rule) and prefix_matches?(upload.key, rule) and
      DateTime.compare(now, DateTime.add(upload.inserted_at, days * 86_400, :second)) != :lt
  end

  defp mpu_rule_safe?(rule) do
    rule_safe?(rule) and (rule["filter_tags"] || []) == [] and rule["filter_size_gt"] == nil and
      rule["filter_size_lt"] == nil
  end

  defp apply_upload_action(summary, %Upload{} = upload, true = _dry_run?) do
    Log.info("lifecycle would abort multipart upload",
      action: :lifecycle,
      bucket: upload.bucket_name,
      key: upload.key
    )

    incr(summary, :multipart_uploads_aborted)
  end

  defp apply_upload_action(summary, %Upload{} = upload, false = _dry_run?) do
    :ok = Multipart.abort(upload)

    Log.info("lifecycle aborted multipart upload",
      action: :lifecycle,
      bucket: upload.bucket_name,
      key: upload.key
    )

    incr(summary, :multipart_uploads_aborted)
  rescue
    err -> add_error(summary, upload.bucket_name, upload.key, Exception.message(err))
  end

  defp apply_action(summary, field, %Object{} = object, true = _dry_run?, _fun) do
    Log.info("lifecycle would mutate object",
      action: :lifecycle,
      bucket: object.bucket_name,
      key: object.key
    )

    incr(summary, field)
  end

  defp apply_action(summary, field, %Object{} = object, false = _dry_run?, fun) do
    case fun.() do
      :ok ->
        Log.info("lifecycle mutated object",
          action: :lifecycle,
          bucket: object.bucket_name,
          key: object.key
        )

        incr(summary, field)

      {:error, reason} ->
        add_error(summary, object.bucket_name, object.key, inspect(reason))
    end
  rescue
    err ->
      add_error(summary, object.bucket_name, object.key, Exception.message(err))
  end

  defp incr(summary, field), do: Map.update!(summary, field, &(&1 + 1))

  defp add_error(summary, bucket, key, reason) do
    Log.error("lifecycle action failed",
      action: :lifecycle,
      bucket: bucket,
      key: key,
      reason: reason
    )

    update_in(summary.errors, &[%{bucket: bucket, key: key, reason: reason} | &1])
  end
end
