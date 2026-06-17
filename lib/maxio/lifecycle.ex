defmodule Maxio.Lifecycle do
  @moduledoc """
  Deterministic S3 lifecycle executor.

  This module executes the lifecycle actions that maxio can perform without guessing hidden
  AWS state: current-version Expiration, current-version Transition,
  ExpiredObjectDeleteMarker cleanup, NoncurrentVersionExpiration,
  NoncurrentVersionTransition, and AbortIncompleteMultipartUpload. Transition updates the
  S3-visible storage class metadata; maxio does not yet move bytes to a distinct tier backend.

  MFA Delete buckets are handled conservatively: lifecycle actions that would permanently delete
  object versions are skipped and counted instead of bypassing the HTTP `x-amz-mfa` verifier.
  """

  import Ecto.Query

  alias Maxio.Buckets
  alias Maxio.Buckets.Bucket
  alias Maxio.BucketConfigs
  alias Maxio.Cluster.Placement
  alias Maxio.Multipart
  alias Maxio.Multipart.Upload
  alias Maxio.ObjectStorageClassSidecar
  alias Maxio.Objects
  alias Maxio.Objects.Object
  alias Maxio.Repo
  alias Maxio.S3.ObjectLock
  alias Maxio.S3.Log
  alias Maxio.S3.StorageClass
  alias Maxio.Storage
  alias Maxio.Versioning.VersionId

  @type summary :: %{
          buckets_scanned: non_neg_integer(),
          objects_expired: non_neg_integer(),
          objects_transitioned: non_neg_integer(),
          noncurrent_versions_expired: non_neg_integer(),
          noncurrent_versions_transitioned: non_neg_integer(),
          delete_markers_removed: non_neg_integer(),
          multipart_uploads_aborted: non_neg_integer(),
          unsupported_rules: non_neg_integer(),
          mfa_delete_protected_actions_skipped: non_neg_integer(),
          object_lock_protected_actions_skipped: non_neg_integer(),
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
      objects_transitioned: 0,
      noncurrent_versions_expired: 0,
      noncurrent_versions_transitioned: 0,
      delete_markers_removed: 0,
      multipart_uploads_aborted: 0,
      unsupported_rules: 0,
      mfa_delete_protected_actions_skipped: 0,
      object_lock_protected_actions_skipped: 0,
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
        |> run_multipart_abort_actions(bucket, rules, now, dry_run?, opts)

      :none ->
        incr(summary, :buckets_scanned)
    end
  end

  defp count_unsupported(summary, rules) do
    unsupported =
      Enum.count(rules, fn rule ->
        unsupported_transition_rule?(rule)
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
            if mfa_delete_enabled?(bucket) do
              skip_mfa_delete_protected_action(acc, object, :expired_delete_marker)
            else
              apply_action(acc, :delete_markers_removed, object, dry_run?, fn ->
                delete_expired_delete_marker(bucket.name, object, opts)
              end)
            end
          else
            acc
          end

        not object.is_delete_marker and current_expired?(object, rules, now) and
            current_expiration_deletes_version?(bucket) ->
          cond do
            mfa_delete_enabled?(bucket) ->
              skip_mfa_delete_protected_action(acc, object, :current_expiration)

            stale_current_lifecycle_candidate?(object, rules, now, opts) ->
              acc

            current_expiration_object_lock_protected?(bucket, object, now, opts) ->
              skip_object_lock_protected_action(acc, object, :current_expiration)

            true ->
              apply_action(acc, :objects_expired, object, dry_run?, fn ->
                expire_current_object(bucket, object, rules, now, opts)
              end)
          end

        not object.is_delete_marker ->
          case current_transition_target(object, rules, now) do
            nil ->
              if current_expired?(object, rules, now) do
                cond do
                  stale_current_lifecycle_candidate?(object, rules, now, opts) ->
                    acc

                  current_expiration_object_lock_protected?(bucket, object, now, opts) ->
                    skip_object_lock_protected_action(acc, object, :current_expiration)

                  true ->
                    apply_action(acc, :objects_expired, object, dry_run?, fn ->
                      expire_current_object(bucket, object, rules, now, opts)
                    end)
                end
              else
                acc
              end

            storage_class ->
              apply_action(acc, :objects_transitioned, object, dry_run?, fn ->
                transition_current_object(bucket, object, storage_class, rules, now, opts)
              end)
          end

        true ->
          acc
      end
    end)
  end

  defp run_noncurrent_version_actions(summary, %Bucket{} = bucket, rules, now, dry_run?, opts) do
    bucket.name
    |> noncurrent_versions()
    |> Enum.reduce(summary, fn candidate, acc ->
      cond do
        noncurrent_expired?(candidate, rules, now) ->
          object = candidate.object

          cond do
            mfa_delete_enabled?(bucket) ->
              skip_mfa_delete_protected_action(acc, object, :noncurrent_version_expiration)

            object_lock_protected_for_lifecycle?(object, now, opts) ->
              skip_object_lock_protected_action(acc, object, :noncurrent_version_expiration)

            true ->
              apply_action(acc, :noncurrent_versions_expired, object, dry_run?, fn ->
                delete_version(bucket.name, object.key, object.version_id, now, opts)
              end)
          end

        (storage_class = noncurrent_transition_target(candidate, rules, now)) != nil ->
          object = candidate.object

          if object_lock_protected_for_lifecycle?(object, now, opts) do
            skip_object_lock_protected_action(acc, object, :noncurrent_version_transition)
          else
            apply_action(acc, :noncurrent_versions_transitioned, object, dry_run?, fn ->
              transition_noncurrent_version(bucket, candidate, storage_class, rules, now, opts)
            end)
          end

        true ->
          acc
      end
    end)
  end

  defp mfa_delete_enabled?(%Bucket{mfa_delete: "Enabled"}), do: true
  defp mfa_delete_enabled?(%Bucket{}), do: false

  defp current_expiration_deletes_version?(%Bucket{versioning: "Enabled"}), do: false
  defp current_expiration_deletes_version?(%Bucket{}), do: true

  defp current_expiration_object_lock_protected?(
         %Bucket{versioning: "Suspended"},
         %Object{} = object,
         now,
         opts
       ) do
    case locked_null_replacement?(object.bucket_name, object.key, now, opts) do
      {:ok, protected?} -> protected?
      {:error, _reason} -> true
    end
  end

  defp current_expiration_object_lock_protected?(
         %Bucket{} = bucket,
         %Object{} = object,
         now,
         opts
       ) do
    current_expiration_deletes_version?(bucket) and
      object_lock_protected_for_lifecycle?(object, now, opts)
  end

  defp object_lock_protected?(%Object{is_delete_marker: true}, _now), do: false

  defp object_lock_protected?(%Object{} = object, %DateTime{} = now) do
    ObjectLock.locked?(object, now: now, bypass_governance?: false)
  end

  defp object_lock_protected_for_lifecycle?(%Object{} = object, now, opts) do
    case object_lock_protected_authoritatively?(
           object.bucket_name,
           object.key,
           object.version_id,
           now,
           opts
         ) do
      {:ok, protected?} -> protected?
      {:error, _reason} -> true
    end
  end

  defp object_lock_protected_authoritatively?(bucket, key, version_id, now, opts) do
    case authoritative_object_version(bucket, key, version_id, opts) do
      {:ok, %Object{} = object} ->
        {:ok, object_lock_protected?(object, now)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp authoritative_object_version(bucket, key, version_id, opts) do
    case Maxio.ObjectMeta.authoritative_source(:write, opts) do
      :sidecar ->
        case Maxio.ObjectMeta.get(bucket, key, version_id, sidecar_read_opts(opts)) do
          %Object{} = object -> {:ok, object}
          {:error, reason} -> {:error, reason}
        end

      _pg ->
        Objects.get_version(bucket, key, version_id)
    end
  end

  defp authoritative_latest_object(bucket, key, opts) do
    case Maxio.ObjectMeta.authoritative_source(:write, opts) do
      :sidecar ->
        case Maxio.ObjectMeta.get(bucket, key, nil, sidecar_read_opts(opts)) do
          %Object{} = object -> {:ok, object}
          {:error, reason} -> {:error, reason}
        end

      _pg ->
        Objects.get_metadata(bucket, key)
    end
  end

  defp sidecar_read_opts(opts) do
    opts
    |> Keyword.put(:authoritative_source, read: :sidecar)
    |> Keyword.put(:read_prefer_index, false)
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

  defp current_transition_target(%Object{} = object, rules, now) do
    rules
    |> Enum.flat_map(fn rule ->
      if current_transition_rule_supported?(rule) and object_matches_rule?(object, rule) and
           transition_age_expired?(version_created_at(object), rule, now) do
        [transition_storage_class(rule, "transition_storage_class")]
      else
        []
      end
    end)
    |> transition_target_by_precedence()
    |> case do
      nil -> nil
      target -> if transitioned?(object, target), do: nil, else: target
    end
  end

  defp noncurrent_transition_target(%{object: %Object{} = object} = candidate, rules, now) do
    rules
    |> Enum.flat_map(fn rule ->
      if noncurrent_transition_rule_supported?(rule) and object_matches_rule?(object, rule) and
           noncurrent_transition_age_expired?(candidate, rule, now) and
           newer_noncurrent_transition_versions_exceeded?(candidate, rule) do
        [transition_storage_class(rule, "noncurrent_transition_storage_class")]
      else
        []
      end
    end)
    |> transition_target_by_precedence()
    |> case do
      nil -> nil
      target -> if transitioned?(object, target), do: nil, else: target
    end
  end

  defp transitioned?(%Object{} = object, storage_class),
    do: (object.storage_class || "STANDARD") == storage_class

  defp transition_target_by_precedence([]), do: nil

  defp transition_target_by_precedence(targets) do
    targets
    |> Enum.uniq()
    |> Enum.max_by(&transition_precedence_rank/1)
  end

  defp transition_precedence_rank("DEEP_ARCHIVE"), do: 6
  defp transition_precedence_rank("GLACIER"), do: 5
  defp transition_precedence_rank("GLACIER_IR"), do: 4
  defp transition_precedence_rank("ONEZONE_IA"), do: 3
  defp transition_precedence_rank("STANDARD_IA"), do: 2
  defp transition_precedence_rank("INTELLIGENT_TIERING"), do: 1
  defp transition_precedence_rank(_storage_class), do: 0

  defp unsupported_transition_rule?(rule) do
    (current_transition_configured?(rule) and not current_transition_rule_supported?(rule)) or
      (noncurrent_transition_configured?(rule) and
         not noncurrent_transition_rule_supported?(rule))
  end

  defp current_transition_rule_supported?(rule) do
    current_transition_configured?(rule) and not transition_days_and_date?(rule) and
      (valid_transition_days?(rule["transition_days"]) or
         rule["transition_date"] not in [nil, ""]) and
      valid_lifecycle_transition_storage_class?(rule["transition_storage_class"]) and
      current_transition_days_supported?(rule)
  end

  defp noncurrent_transition_rule_supported?(rule) do
    noncurrent_transition_configured?(rule) and
      valid_noncurrent_days?(rule["noncurrent_transition_days"]) and
      (rule["noncurrent_transition_newer_noncurrent_versions"] == nil or
         valid_newer_noncurrent_versions?(rule["noncurrent_transition_newer_noncurrent_versions"])) and
      valid_lifecycle_transition_storage_class?(rule["noncurrent_transition_storage_class"])
  end

  defp current_transition_configured?(rule) do
    rule["transition_days"] != nil or rule["transition_date"] not in [nil, ""] or
      rule["transition_storage_class"] not in [nil, ""]
  end

  defp noncurrent_transition_configured?(rule) do
    rule["noncurrent_transition_days"] != nil or
      rule["noncurrent_transition_newer_noncurrent_versions"] != nil or
      rule["noncurrent_transition_storage_class"] not in [nil, ""]
  end

  defp transition_days_and_date?(rule),
    do: rule["transition_days"] != nil and rule["transition_date"] not in [nil, ""]

  defp valid_transition_days?(value), do: is_integer(value) and value >= 0

  defp current_transition_days_supported?(%{"transition_days" => nil}), do: true

  defp current_transition_days_supported?(rule) do
    StorageClass.lifecycle_transition_days_valid?(
      rule["transition_storage_class"],
      rule["transition_days"]
    )
  end

  defp valid_lifecycle_transition_storage_class?(value),
    do: StorageClass.lifecycle_transition_valid?(value)

  defp transition_storage_class(rule, field) do
    rule[field]
    |> String.trim()
    |> String.upcase()
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

  defp transition_age_expired?(updated_at, %{"transition_days" => days}, now)
       when is_integer(days) and days >= 0 do
    threshold = lifecycle_days_threshold(updated_at, days)
    DateTime.compare(now, threshold) != :lt
  end

  defp transition_age_expired?(_updated_at, %{"transition_date" => date}, now)
       when is_binary(date) do
    case parse_expiration_datetime(date) do
      {:ok, transitions_at} -> DateTime.compare(now, transitions_at) != :lt
      :error -> false
    end
  end

  defp transition_age_expired?(_updated_at, _rule, _now), do: false

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

  defp noncurrent_transition_age_expired?(
         %{noncurrent_since: nil},
         %{"noncurrent_transition_days" => days},
         _now
       )
       when is_integer(days),
       do: false

  defp noncurrent_transition_age_expired?(
         %{noncurrent_since: noncurrent_since},
         %{"noncurrent_transition_days" => days},
         now
       )
       when is_integer(days) and days >= 1 do
    threshold = lifecycle_days_threshold(noncurrent_since, days)
    DateTime.compare(now, threshold) != :lt
  end

  defp noncurrent_transition_age_expired?(_candidate, _rule, _now), do: false

  defp newer_noncurrent_versions_exceeded?(
         %{newer_noncurrent_versions: count},
         %{"newer_noncurrent_versions" => retain}
       )
       when is_integer(retain) and retain in 1..100,
       do: count > retain

  defp newer_noncurrent_versions_exceeded?(_candidate, %{"newer_noncurrent_versions" => nil}),
    do: true

  defp newer_noncurrent_versions_exceeded?(_candidate, _rule), do: false

  defp newer_noncurrent_transition_versions_exceeded?(
         %{newer_noncurrent_versions: count},
         %{"noncurrent_transition_newer_noncurrent_versions" => retain}
       )
       when is_integer(retain) and retain in 1..100,
       do: count > retain

  defp newer_noncurrent_transition_versions_exceeded?(
         _candidate,
         %{"noncurrent_transition_newer_noncurrent_versions" => nil}
       ),
       do: true

  defp newer_noncurrent_transition_versions_exceeded?(_candidate, _rule), do: false

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

  defp only_version?(%Object{} = object, opts) do
    case Maxio.ObjectMeta.authoritative_source(:write, opts) do
      :sidecar -> false
      _pg -> only_version?(object)
    end
  end

  defp latest_candidate_still_eligible?(%Object{} = candidate, rules, now, opts) do
    case authoritative_latest_object(candidate.bucket_name, candidate.key, opts) do
      {:ok, %Object{is_delete_marker: false} = current} ->
        if same_version?(current, candidate) and current_expired?(current, rules, now) do
          :ok
        else
          {:error, :stale_candidate}
        end

      {:ok, %Object{}} ->
        {:error, :stale_candidate}

      {:error, :not_found} ->
        {:error, :stale_candidate}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp stale_current_lifecycle_candidate?(%Object{} = candidate, rules, now, opts) do
    match?(
      {:error, :stale_candidate},
      latest_candidate_still_eligible?(candidate, rules, now, opts)
    )
  end

  defp same_version?(%Object{} = left, %Object{} = right) do
    left.bucket_name == right.bucket_name and left.key == right.key and
      left.version_id == right.version_id
  end

  defp expire_current_object(
         %Bucket{versioning: versioning} = bucket,
         %Object{} = object,
         rules,
         now,
         opts
       ) do
    case versioning do
      "Enabled" ->
        put_delete_marker(bucket.name, object, VersionId.generate(), rules, now, opts)

      "Suspended" ->
        put_delete_marker(bucket.name, object, "null", rules, now, opts)

      _unversioned ->
        hard_delete_object(bucket, object, rules, now, opts)
    end
  end

  defp transition_current_object(
         %Bucket{} = bucket,
         %Object{} = object,
         storage_class,
         rules,
         now,
         opts
       ) do
    Maxio.Lock.with_object_lock({bucket.name, object.key}, fn ->
      with :ok <-
             current_transition_candidate_still_eligible?(object, storage_class, rules, now, opts) do
        update_storage_class_authoritative(
          bucket.name,
          object.key,
          object.version_id,
          storage_class,
          opts
        )
      else
        {:error, :stale_candidate} -> :skipped
        {:error, :not_found} -> :skipped
        {:error, reason} -> {:error, reason}
      end
    end)
    |> case do
      {:ok, result} -> result
      {:error, :locked} -> {:error, :locked}
    end
  end

  defp transition_noncurrent_version(
         %Bucket{} = bucket,
         %{object: %Object{} = object} = candidate,
         storage_class,
         rules,
         now,
         opts
       ) do
    Maxio.Lock.with_object_lock({bucket.name, object.key}, fn ->
      with :ok <-
             noncurrent_transition_candidate_still_eligible?(
               candidate,
               storage_class,
               rules,
               now,
               opts
             ) do
        update_storage_class_authoritative(
          bucket.name,
          object.key,
          object.version_id,
          storage_class,
          opts
        )
      else
        {:error, :stale_candidate} -> :skipped
        {:error, :not_found} -> :skipped
        {:error, reason} -> {:error, reason}
      end
    end)
    |> case do
      {:ok, result} -> result
      {:error, :locked} -> {:error, :locked}
    end
  end

  defp current_transition_candidate_still_eligible?(
         %Object{} = candidate,
         storage_class,
         rules,
         now,
         opts
       ) do
    case authoritative_latest_object(candidate.bucket_name, candidate.key, opts) do
      {:ok, %Object{is_delete_marker: false} = current} ->
        if same_version?(current, candidate) and
             current_transition_target(current, rules, now) == storage_class do
          :ok
        else
          {:error, :stale_candidate}
        end

      {:ok, %Object{}} ->
        {:error, :stale_candidate}

      {:error, :not_found} ->
        {:error, :stale_candidate}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp noncurrent_transition_candidate_still_eligible?(
         %{object: %Object{} = candidate_object} = candidate,
         storage_class,
         rules,
         now,
         opts
       ) do
    case Maxio.ObjectMeta.authoritative_source(:write, opts) do
      :sidecar ->
        with {:ok, %Object{is_delete_marker: false} = object} <-
               authoritative_object_version(
                 candidate_object.bucket_name,
                 candidate_object.key,
                 candidate_object.version_id,
                 opts
               ),
             :ok <- sidecar_version_still_noncurrent?(object, opts),
             {:ok, refreshed} <-
               refreshed_noncurrent_transition_candidate(candidate, object) do
          if noncurrent_transition_target(refreshed, rules, now) == storage_class do
            :ok
          else
            {:error, :stale_candidate}
          end
        else
          {:ok, %Object{}} -> {:error, :stale_candidate}
          {:error, :stale_candidate} -> {:error, :stale_candidate}
          {:error, :not_found} -> {:error, :stale_candidate}
          {:error, reason} -> {:error, reason}
        end

      _pg ->
        case refreshed_noncurrent_candidate(
               candidate_object.bucket_name,
               candidate_object.key,
               candidate_object.version_id
             ) do
          nil ->
            {:error, :stale_candidate}

          refreshed ->
            if noncurrent_transition_target(refreshed, rules, now) == storage_class do
              :ok
            else
              {:error, :stale_candidate}
            end
        end
    end
  end

  defp sidecar_version_still_noncurrent?(%Object{} = object, opts) do
    case authoritative_latest_object(object.bucket_name, object.key, opts) do
      {:ok, %Object{} = current} ->
        if same_version?(current, object), do: {:error, :stale_candidate}, else: :ok

      {:error, :not_found} ->
        {:error, :stale_candidate}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp refreshed_noncurrent_transition_candidate(
         %{object: %Object{} = original_candidate},
         %Object{} = authoritative_object
       ) do
    case refreshed_noncurrent_candidate(
           original_candidate.bucket_name,
           original_candidate.key,
           original_candidate.version_id
         ) do
      nil -> {:error, :not_found}
      refreshed -> {:ok, %{refreshed | object: authoritative_object}}
    end
  end

  defp refreshed_noncurrent_candidate(bucket, key, version_id) do
    bucket
    |> noncurrent_versions()
    |> Enum.find(fn %{object: object} ->
      object.key == key and object.version_id == version_id
    end)
  end

  defp update_storage_class_authoritative(bucket, key, version_id, storage_class, opts) do
    case Maxio.ObjectMeta.authoritative_source(:write, opts) do
      :sidecar ->
        update_storage_class_sidecar(bucket, key, version_id, storage_class, opts)

      _pg ->
        update_storage_class_pg(bucket, key, version_id, storage_class, opts)
    end
  end

  defp update_storage_class_sidecar(bucket, key, version_id, storage_class, opts) do
    case ObjectStorageClassSidecar.update(bucket, key, version_id, storage_class, opts) do
      {:ok, generation} ->
        best_effort_storage_class_index_update(bucket, key, version_id, storage_class, generation)
        :ok

      {:error, :not_found} ->
        :skipped

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp update_storage_class_pg(bucket, key, version_id, storage_class, opts) do
    case Objects.put_storage_class(bucket, key, version_id, storage_class) do
      {:ok, _object} ->
        mirror_storage_class_sidecar(bucket, key, version_id, storage_class, opts)
        :ok

      {:error, :not_found} ->
        :skipped
    end
  end

  defp best_effort_storage_class_index_update(bucket, key, version_id, storage_class, generation) do
    case Objects.put_storage_class(bucket, key, version_id, storage_class, generation) do
      {:ok, _object} ->
        :ok

      {:error, reason} ->
        Log.error("pg lifecycle storage-class index update failed",
          action: :lifecycle,
          bucket: bucket,
          key: key,
          version_id: version_id,
          storage_class: storage_class,
          reason: inspect(reason)
        )
    end
  end

  defp mirror_storage_class_sidecar(bucket, key, version_id, storage_class, opts) do
    case ObjectStorageClassSidecar.update(bucket, key, version_id, storage_class, opts) do
      {:ok, generation} ->
        case Objects.put_storage_class(bucket, key, version_id, storage_class, generation) do
          {:ok, _object} ->
            :ok

          {:error, reason} ->
            Log.warn("pg lifecycle storage-class generation sync failed after sidecar mirror",
              action: :lifecycle,
              bucket: bucket,
              key: key,
              version_id: version_id,
              storage_class: storage_class,
              reason: inspect(reason)
            )
        end

      {:error, reason} ->
        Log.warn("sidecar lifecycle storage-class mirror failed (PG remains authoritative)",
          action: :lifecycle,
          bucket: bucket,
          key: key,
          version_id: version_id,
          storage_class: storage_class,
          reason: inspect(reason)
        )
    end
  rescue
    e ->
      Log.warn("sidecar lifecycle storage-class mirror raised (PG remains authoritative)",
        action: :lifecycle,
        bucket: bucket,
        key: key,
        version_id: version_id,
        storage_class: storage_class,
        reason: inspect(e)
      )
  catch
    kind, reason ->
      Log.warn("sidecar lifecycle storage-class mirror caught (PG remains authoritative)",
        action: :lifecycle,
        bucket: bucket,
        key: key,
        version_id: version_id,
        storage_class: storage_class,
        reason: inspect({kind, reason})
      )
  end

  defp hard_delete_object(%Bucket{} = bucket, %Object{} = object, rules, now, opts) do
    case Maxio.Lock.with_object_lock({bucket.name, object.key}, fn ->
           with :ok <- latest_candidate_still_eligible?(object, rules, now, opts),
                {:ok, false} <-
                  object_lock_protected_authoritatively?(
                    bucket.name,
                    object.key,
                    object.version_id,
                    now,
                    opts
                  ) do
             delete_version_authoritative(bucket.name, object.key, object.version_id, opts)
           else
             {:ok, true} -> {:error, :object_lock_protected}
             {:error, :not_found} -> :skipped
             {:error, :stale_candidate} -> :skipped
             {:error, reason} -> {:error, reason}
           end
         end) do
      {:ok, :ok} -> :ok
      {:ok, :skipped} -> :skipped
      {:ok, {:error, :object_lock_protected}} -> {:error, :object_lock_protected}
      {:error, :locked} -> {:error, :locked}
    end
  end

  defp put_delete_marker(bucket, %Object{} = object, version_id, rules, now, opts) do
    case Maxio.Lock.with_object_lock({bucket, object.key}, fn ->
           with :ok <- latest_candidate_still_eligible?(object, rules, now, opts),
                :ok <- reject_locked_null_replacement(bucket, object.key, version_id, now, opts) do
             put_delete_marker_authoritative(bucket, object.key, version_id, opts)
           else
             {:error, :stale_candidate} -> :skipped
             {:error, reason} -> {:error, reason}
           end
         end) do
      {:ok, result} -> result
      {:error, :locked} -> {:error, :locked}
    end
  end

  defp put_delete_marker_authoritative(bucket, key, version_id, opts) do
    case Maxio.ObjectMeta.authoritative_source(:write, opts) do
      :sidecar -> put_delete_marker_sidecar(bucket, key, version_id, opts)
      _pg -> put_delete_marker_pg(bucket, key, version_id, opts)
    end
  end

  defp reject_locked_null_replacement(_bucket, _key, version_id, _now, _opts)
       when version_id != "null",
       do: :ok

  defp reject_locked_null_replacement(bucket, key, "null", now, opts) do
    case locked_null_replacement?(bucket, key, now, opts) do
      {:ok, true} -> {:error, :object_lock_protected}
      {:ok, false} -> :ok
      {:error, :not_found} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp locked_null_replacement?(bucket, key, now, opts) do
    case Maxio.ObjectMeta.authoritative_source(:write, opts) do
      :sidecar ->
        object_lock_protected_authoritatively?(bucket, key, "null", now, opts)

      _pg ->
        case Objects.get_version(bucket, key, "null") do
          {:ok, %Object{} = object} ->
            object_lock_protected_authoritatively?(bucket, key, object.version_id, now, opts)

          {:error, :not_found} ->
            {:ok, false}
        end
    end
  end

  defp put_delete_marker_sidecar(bucket, key, version_id, opts) do
    with {:ok, placement} <- Placement.resolve_write(bucket, key, opts),
         :ok <-
           Storage.put_delete_marker(
             bucket,
             key,
             version_id,
             [],
             Keyword.merge(opts, Placement.storage_opts(placement))
           ) do
      placement_attrs = Placement.attrs_from_result(placement)

      case Objects.insert_delete_marker_index(bucket, key, version_id, placement_attrs) do
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

  defp put_delete_marker_pg(bucket, key, version_id, opts) do
    old_null_opts = storage_opts_for_version(bucket, key, "null", opts)
    {:ok, placement} = Placement.resolve_write(bucket, key, opts)
    placement_storage_opts = Keyword.merge(opts, Placement.storage_opts(placement))
    placement_attrs = Placement.attrs_from_result(placement)

    {:ok, _} = Objects.insert_delete_marker_with_id(bucket, key, version_id, placement_attrs)
    if version_id == "null", do: _ = Storage.delete(bucket, key, "null", old_null_opts)
    _ = Storage.put_delete_marker(bucket, key, version_id, [], placement_storage_opts)
    :ok
  end

  defp delete_version(bucket, key, version_id, now, opts) do
    case Maxio.Lock.with_object_lock({bucket, key}, fn ->
           case reject_locked_version_delete(bucket, key, version_id, now, opts) do
             :ok -> delete_version_authoritative(bucket, key, version_id, opts)
             {:error, reason} -> {:error, reason}
           end
         end) do
      {:ok, result} -> result
      {:error, :locked} -> {:error, :locked}
    end
  end

  defp delete_expired_delete_marker(bucket, %Object{} = object, opts) do
    case Maxio.Lock.with_object_lock({bucket, object.key}, fn ->
           with {:ok, %Object{is_delete_marker: true} = marker} <-
                  authoritative_object_version(bucket, object.key, object.version_id, opts),
                true <- only_version?(marker, opts) do
             delete_version_authoritative(bucket, object.key, object.version_id, opts)
           else
             _other -> :skipped
           end
         end) do
      {:ok, result} -> result
      {:error, :locked} -> {:error, :locked}
    end
  end

  defp reject_locked_version_delete(bucket, key, version_id, now, opts) do
    case object_lock_protected_authoritatively?(bucket, key, version_id, now, opts) do
      {:ok, true} -> {:error, :object_lock_protected}
      {:ok, false} -> :ok
      {:error, :not_found} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp delete_version_authoritative(bucket, key, version_id, opts) do
    case Maxio.ObjectMeta.authoritative_source(:write, opts) do
      :sidecar -> delete_version_sidecar(bucket, key, version_id, opts)
      _pg -> delete_version_pg(bucket, key, version_id, opts)
    end
  end

  defp delete_version_sidecar(bucket, key, version_id, opts) do
    with :ok <-
           Storage.delete_version(
             bucket,
             key,
             version_id,
             storage_opts_for_version(bucket, key, version_id, opts)
           ) do
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

  defp delete_version_pg(bucket, key, version_id, opts) do
    storage_opts = storage_opts_for_version(bucket, key, version_id, opts)

    case Objects.delete_version(bucket, key, version_id) do
      {:ok, _} ->
        _ = Storage.delete(bucket, key, version_id, storage_opts)
        :ok

      {:error, :not_found} ->
        :ok
    end
  end

  defp storage_opts_for_version(bucket, key, version_id, opts) do
    case Objects.get_version(bucket, key, version_id) do
      {:ok, object} -> Keyword.merge(opts, Placement.storage_opts(object))
      {:error, :not_found} -> opts
    end
  end

  defp run_multipart_abort_actions(summary, %Bucket{} = bucket, rules, now, dry_run?, opts) do
    bucket.name
    |> pending_uploads()
    |> Enum.reduce(summary, fn upload, acc ->
      if Enum.any?(rules, &abort_upload_expired?(upload, &1, now)) do
        apply_upload_action(acc, upload, dry_run?, opts)
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

  defp apply_upload_action(summary, %Upload{} = upload, true = _dry_run?, _opts) do
    Log.info("lifecycle would abort multipart upload",
      action: :lifecycle,
      bucket: upload.bucket_name,
      key: upload.key
    )

    incr(summary, :multipart_uploads_aborted)
  end

  defp apply_upload_action(summary, %Upload{} = upload, false = _dry_run?, opts) do
    :ok = Multipart.abort(upload, opts)

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

      :skipped ->
        Log.info("lifecycle skipped stale object action",
          action: :lifecycle,
          bucket: object.bucket_name,
          key: object.key,
          version_id: object.version_id,
          field: field
        )

        summary

      {:error, :object_lock_protected} ->
        skip_object_lock_protected_action(summary, object, field)

      {:error, reason} ->
        add_error(summary, object.bucket_name, object.key, inspect(reason))
    end
  rescue
    err ->
      add_error(summary, object.bucket_name, object.key, Exception.message(err))
  end

  defp skip_mfa_delete_protected_action(summary, %Object{} = object, reason) do
    Log.warn("lifecycle skipped MFA Delete protected action",
      action: :lifecycle,
      bucket: object.bucket_name,
      key: object.key,
      version_id: object.version_id,
      reason: reason
    )

    incr(summary, :mfa_delete_protected_actions_skipped)
  end

  defp skip_object_lock_protected_action(summary, %Object{} = object, reason) do
    Log.warn("lifecycle skipped Object Lock protected action",
      action: :lifecycle,
      bucket: object.bucket_name,
      key: object.key,
      version_id: object.version_id,
      reason: reason
    )

    incr(summary, :object_lock_protected_actions_skipped)
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
