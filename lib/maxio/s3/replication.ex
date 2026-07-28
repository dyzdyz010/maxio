defmodule Maxio.S3.Replication do
  @moduledoc """
  Bucket Replication configuration helpers.

  This module stores, normalizes, and matches S3 replication control-plane
  configuration. Data-plane delivery is handled by `Maxio.S3.ReplicationDelivery`
  through the durable replication outbox.
  """

  alias Maxio.BucketConfigs
  alias Maxio.S3.Error
  alias Maxio.Tags

  @max_rules 1_000
  @id_pattern ~r/\A[\p{L}\p{N}\p{Zs}_.:-]{1,255}\z/u
  @valid_statuses ~w(Enabled Disabled)
  @valid_storage_classes ~w(
    STANDARD REDUCED_REDUNDANCY STANDARD_IA ONEZONE_IA INTELLIGENT_TIERING
    GLACIER DEEP_ARCHIVE OUTPOSTS GLACIER_IR SNOW EXPRESS_ONEZONE FSX_ONTAP
  )

  @spec max_rules() :: pos_integer()
  def max_rules, do: @max_rules

  @spec valid_id?(term()) :: boolean()
  def valid_id?(id), do: is_binary(id) and Regex.match?(@id_pattern, id)

  @spec validate_client_config(map()) :: {:ok, map()} | {:error, :malformed_xml}
  def validate_client_config(config) when is_map(config) do
    {:ok, normalize_config(config)}
  rescue
    _err in Error -> {:error, :malformed_xml}
  end

  @spec get_config(String.t()) :: {:ok, map()} | :none
  def get_config(bucket) when is_binary(bucket) do
    case BucketConfigs.get(bucket, :replication) do
      {:ok, stored} -> {:ok, normalize_config(stored)}
      :none -> :none
    end
  end

  @spec put_config(String.t(), map()) :: :ok
  def put_config(bucket, config) when is_binary(bucket) and is_map(config) do
    :ok = BucketConfigs.put(bucket, :replication, normalize_config(config))
  end

  @spec delete_config(String.t()) :: :ok
  def delete_config(bucket) when is_binary(bucket), do: BucketConfigs.delete(bucket, :replication)

  @doc """
  Return enabled replication targets for one committed data-plane event.

  The input `attrs` uses the same event shape as notification attrs:
  `:bucket`, `:key`, `:version_id`, optional `:tags`, `:etag`, and `:size`.
  Matching follows the stored ReplicationConfiguration and collapses overlapping
  rules per destination bucket by the highest rule priority.
  """
  @spec matching_tasks(String.t(), map()) :: [map()]
  def matching_tasks(event_name, attrs) when is_binary(event_name) and is_map(attrs) do
    bucket = Map.fetch!(attrs, :bucket)
    key = Map.fetch!(attrs, :key)

    with {:ok, config} <- get_config(bucket) do
      config
      |> Map.get("Rules", [])
      |> Enum.filter(&rule_matches?(&1, event_name, key, Map.get(attrs, :tags) || %{}))
      |> collapse_overlapping_rules()
      |> Enum.map(&task_from_rule(&1, event_name, attrs))
    else
      :none -> []
    end
  end

  @spec normalize_config(map()) :: map()
  def normalize_config(config) when is_map(config) do
    role = value(config, ["Role", "role"])
    rules = value(config, ["Rules", "Rule", "rules", "rule"], [])

    rules =
      rules
      |> normalize_rules()
      |> validate_rule_count!()
      |> validate_unique_ids!()
      |> validate_unique_priorities!()

    %{
      "Role" => normalize_non_empty_string(role),
      "Rules" => rules
    }
  end

  def normalize_config(_config), do: invalid_stored!()

  defp normalize_rules(rules) when is_list(rules), do: Enum.map(rules, &normalize_rule/1)
  defp normalize_rules(rule) when is_map(rule), do: [normalize_rule(rule)]
  defp normalize_rules(_rules), do: invalid_stored!()

  defp normalize_rule(rule) when is_map(rule) do
    id = value(rule, ["ID", "Id", "id"])
    status = value(rule, ["Status", "status"])
    priority = value(rule, ["Priority", "priority"])
    filter = value(rule, ["Filter", "filter"])
    prefix = value(rule, ["Prefix", "prefix"])
    destination = value(rule, ["Destination", "destination"])

    delete_marker_replication =
      value(rule, ["DeleteMarkerReplication", "delete_marker_replication"])

    delete_replication =
      value(rule, ["DeleteReplication", "delete_replication"])

    existing_object_replication =
      value(rule, ["ExistingObjectReplication", "existing_object_replication"])

    source_selection_criteria =
      value(rule, ["SourceSelectionCriteria", "source_selection_criteria"])

    %{
      "Status" => normalize_enum(status, @valid_statuses),
      "Destination" => normalize_destination(destination)
    }
    |> maybe_put_id(id)
    |> maybe_put_priority(priority)
    |> put_rule_filter(filter, prefix)
    |> maybe_put_delete_marker_replication(delete_marker_replication)
    |> maybe_put_delete_replication(delete_replication)
    |> maybe_put_existing_object_replication(existing_object_replication)
    |> maybe_put_source_selection_criteria(source_selection_criteria)
    |> validate_replication_rule_requirements!()
  end

  defp normalize_rule(_rule), do: invalid_stored!()

  defp maybe_put_id(rule, nil), do: rule
  defp maybe_put_id(rule, id), do: Map.put(rule, "ID", normalize_rule_id(id))

  defp normalize_rule_id(id) when is_binary(id) do
    if valid_id?(id), do: id, else: invalid_stored!()
  end

  defp normalize_rule_id(_id), do: invalid_stored!()

  defp maybe_put_priority(rule, nil), do: rule

  defp maybe_put_priority(rule, priority),
    do: Map.put(rule, "Priority", normalize_integer(priority))

  defp put_rule_filter(_rule, nil, nil), do: invalid_stored!()

  defp put_rule_filter(rule, nil, prefix) do
    Map.put(rule, "Prefix", normalize_string(prefix))
  end

  defp put_rule_filter(rule, filter, nil) do
    Map.put(rule, "Filter", normalize_filter(filter))
  end

  defp put_rule_filter(_rule, _filter, _prefix), do: invalid_stored!()

  defp normalize_filter(filter) when is_map(filter) do
    keys =
      [
        {"Prefix", value(filter, ["Prefix", "prefix"])},
        {"Tag", value(filter, ["Tag", "tag"])},
        {"And", value(filter, ["And", "and"])}
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    case keys do
      [] -> %{}
      [{"Prefix", prefix}] -> %{"Prefix" => normalize_string(prefix)}
      [{"Tag", tag}] -> %{"Tag" => normalize_tag(tag)}
      [{"And", and_operator}] -> %{"And" => normalize_and(and_operator)}
      _multiple -> invalid_stored!()
    end
  end

  defp normalize_filter(_filter), do: invalid_stored!()

  defp normalize_and(and_operator) when is_map(and_operator) do
    prefix = value(and_operator, ["Prefix", "prefix"])
    tags = value(and_operator, ["Tags", "Tag", "tags", "tag"], [])

    tags =
      tags
      |> normalize_tags()
      |> validate_tag_set!()

    fields =
      []
      |> maybe_count(prefix)
      |> Kernel.++(tags)

    if length(fields) < 2 do
      invalid_stored!()
    end

    %{}
    |> maybe_put_normalized_string("Prefix", prefix)
    |> Map.put("Tags", tags)
  end

  defp normalize_and(_and_operator), do: invalid_stored!()

  defp normalize_tags(nil), do: []
  defp normalize_tags([]), do: []
  defp normalize_tags(tags) when is_list(tags), do: Enum.map(tags, &normalize_tag/1)
  defp normalize_tags(tag) when is_map(tag), do: [normalize_tag(tag)]
  defp normalize_tags(_tags), do: invalid_stored!()

  defp normalize_tag(%{"Key" => key, "Value" => value}), do: validate_tag(key, value)
  defp normalize_tag(%{"key" => key, "value" => value}), do: validate_tag(key, value)
  defp normalize_tag(_tag), do: invalid_stored!()

  defp validate_tag(key, value) when is_binary(key) and is_binary(value) do
    case Tags.validate([{key, value}], :object) do
      :ok -> %{"Key" => key, "Value" => value}
      {:error, :invalid_tag} -> invalid_stored!()
    end
  end

  defp validate_tag(_key, _value), do: invalid_stored!()

  defp normalize_destination(destination) when is_map(destination) do
    bucket = value(destination, ["Bucket", "bucket"])
    account = value(destination, ["Account", "account"])
    storage_class = value(destination, ["StorageClass", "storage_class"])
    encryption = value(destination, ["EncryptionConfiguration", "encryption_configuration"])
    metrics = value(destination, ["Metrics", "metrics"])
    replication_time = value(destination, ["ReplicationTime", "replication_time"])

    access_control_translation =
      value(destination, ["AccessControlTranslation", "access_control_translation"])

    %{"Bucket" => normalize_bucket_arn(bucket)}
    |> maybe_put_non_empty_string("Account", account)
    |> maybe_put_storage_class(storage_class)
    |> maybe_put_encryption(encryption)
    |> maybe_put_metrics(metrics)
    |> maybe_put_replication_time(replication_time)
    |> maybe_put_access_control_translation(access_control_translation)
    |> validate_replication_time_metrics!()
    |> validate_access_control_translation_account!()
  end

  defp normalize_destination(_destination), do: invalid_stored!()

  defp normalize_bucket_arn("arn:aws:s3:::" <> rest = arn) when rest != "", do: arn
  defp normalize_bucket_arn(_bucket), do: invalid_stored!()

  defp maybe_put_storage_class(destination, nil), do: destination

  defp maybe_put_storage_class(destination, storage_class),
    do:
      Map.put(destination, "StorageClass", normalize_enum(storage_class, @valid_storage_classes))

  defp maybe_put_encryption(destination, nil), do: destination

  defp maybe_put_encryption(destination, encryption) when is_map(encryption) do
    replica_kms_key_id =
      value(encryption, [
        "ReplicaKmsKeyID",
        "ReplicaKmsKeyId",
        "replica_kms_key_id"
      ])

    Map.put(destination, "EncryptionConfiguration", %{
      "ReplicaKmsKeyID" => normalize_non_empty_string(replica_kms_key_id)
    })
  end

  defp maybe_put_encryption(_destination, _encryption), do: invalid_stored!()

  defp maybe_put_metrics(destination, nil), do: destination

  defp maybe_put_metrics(destination, metrics) when is_map(metrics) do
    status = value(metrics, ["Status", "status"])
    event_threshold = value(metrics, ["EventThreshold", "event_threshold"])

    normalized = %{"Status" => normalize_enum(status, @valid_statuses)}

    Map.put(
      destination,
      "Metrics",
      maybe_put_event_threshold(normalized, event_threshold)
    )
  end

  defp maybe_put_metrics(_destination, _metrics), do: invalid_stored!()

  defp maybe_put_replication_time(destination, nil), do: destination

  defp maybe_put_replication_time(destination, replication_time) when is_map(replication_time) do
    status = value(replication_time, ["Status", "status"])
    time = value(replication_time, ["Time", "time"])

    Map.put(destination, "ReplicationTime", %{
      "Status" => normalize_enum(status, @valid_statuses),
      "Time" => normalize_time(time)
    })
  end

  defp maybe_put_replication_time(_destination, _replication_time), do: invalid_stored!()

  defp maybe_put_event_threshold(metrics, nil), do: metrics

  defp maybe_put_event_threshold(metrics, event_threshold) when is_map(event_threshold) do
    Map.put(metrics, "EventThreshold", normalize_time(event_threshold))
  end

  defp maybe_put_event_threshold(_metrics, _event_threshold), do: invalid_stored!()

  defp normalize_time(time) when is_map(time) do
    minutes = value(time, ["Minutes", "minutes"])
    minutes = normalize_positive_integer(minutes)

    if minutes == 15 do
      %{"Minutes" => minutes}
    else
      invalid_stored!()
    end
  end

  defp normalize_time(_time), do: invalid_stored!()

  defp validate_replication_time_metrics!(%{"ReplicationTime" => _replication_time} = destination) do
    case destination do
      %{"Metrics" => %{"EventThreshold" => _event_threshold}} -> destination
      _missing_metrics_threshold -> invalid_stored!()
    end
  end

  defp validate_replication_time_metrics!(%{"Metrics" => %{"EventThreshold" => _threshold}}) do
    invalid_stored!()
  end

  defp validate_replication_time_metrics!(destination), do: destination

  defp validate_access_control_translation_account!(
         %{"AccessControlTranslation" => _translation} = destination
       ) do
    if Map.has_key?(destination, "Account") do
      destination
    else
      invalid_stored!()
    end
  end

  defp validate_access_control_translation_account!(destination), do: destination

  defp maybe_put_access_control_translation(destination, nil), do: destination

  defp maybe_put_access_control_translation(destination, translation) when is_map(translation) do
    owner = value(translation, ["Owner", "owner"])

    if owner == "Destination" do
      Map.put(destination, "AccessControlTranslation", %{"Owner" => owner})
    else
      invalid_stored!()
    end
  end

  defp maybe_put_access_control_translation(_destination, _translation), do: invalid_stored!()

  defp maybe_put_delete_marker_replication(rule, nil), do: rule

  defp maybe_put_delete_marker_replication(rule, delete_marker_replication)
       when is_map(delete_marker_replication) do
    status = value(delete_marker_replication, ["Status", "status"])

    Map.put(rule, "DeleteMarkerReplication", %{
      "Status" => normalize_enum(status, @valid_statuses)
    })
  end

  defp maybe_put_delete_marker_replication(_rule, _delete_marker_replication),
    do: invalid_stored!()

  defp maybe_put_delete_replication(rule, nil), do: rule

  defp maybe_put_delete_replication(rule, delete_replication)
       when is_map(delete_replication) do
    status = value(delete_replication, ["Status", "status"])

    Map.put(rule, "DeleteReplication", %{
      "Status" => normalize_enum(status, @valid_statuses)
    })
  end

  defp maybe_put_delete_replication(_rule, _delete_replication),
    do: invalid_stored!()

  defp maybe_put_existing_object_replication(rule, nil), do: rule

  defp maybe_put_existing_object_replication(rule, existing_object_replication)
       when is_map(existing_object_replication) do
    status = value(existing_object_replication, ["Status", "status"])

    Map.put(rule, "ExistingObjectReplication", %{
      "Status" => normalize_enum(status, @valid_statuses)
    })
  end

  defp maybe_put_existing_object_replication(_rule, _existing_object_replication),
    do: invalid_stored!()

  defp maybe_put_source_selection_criteria(rule, nil), do: rule

  defp maybe_put_source_selection_criteria(rule, criteria) when is_map(criteria) do
    sse_kms = value(criteria, ["SseKmsEncryptedObjects", "SSEKmsEncryptedObjects", "sse_kms"])
    replica_modifications = value(criteria, ["ReplicaModifications", "replica_modifications"])

    normalized =
      %{}
      |> maybe_put_status_block("SseKmsEncryptedObjects", sse_kms)
      |> maybe_put_status_block("ReplicaModifications", replica_modifications)

    if map_size(normalized) == 0 do
      invalid_stored!()
    end

    Map.put(rule, "SourceSelectionCriteria", normalized)
  end

  defp maybe_put_source_selection_criteria(_rule, _criteria), do: invalid_stored!()

  defp maybe_put_status_block(criteria, _key, nil), do: criteria

  defp maybe_put_status_block(criteria, key, block) when is_map(block) do
    status = value(block, ["Status", "status"])
    Map.put(criteria, key, %{"Status" => normalize_enum(status, @valid_statuses)})
  end

  defp maybe_put_status_block(_criteria, _key, _block), do: invalid_stored!()

  defp validate_rule_count!([]), do: invalid_stored!()

  defp validate_rule_count!(rules) when length(rules) <= @max_rules, do: rules
  defp validate_rule_count!(_rules), do: invalid_stored!()

  defp validate_unique_ids!(rules) do
    ids =
      rules
      |> Enum.map(&Map.get(&1, "ID"))
      |> Enum.reject(&is_nil/1)

    if Enum.uniq(ids) == ids do
      rules
    else
      invalid_stored!()
    end
  end

  defp validate_unique_priorities!(rules) do
    priorities =
      rules
      |> Enum.map(&Map.get(&1, "Priority"))
      |> Enum.reject(&is_nil/1)

    if Enum.uniq(priorities) == priorities do
      rules
    else
      invalid_stored!()
    end
  end

  defp validate_replication_rule_requirements!(rule) do
    rule
    |> validate_filter_rule_requirements!()
    |> validate_tag_delete_marker_replication!()
    |> validate_source_selection_criteria_requirements!()
  end

  defp validate_filter_rule_requirements!(%{"Filter" => _filter} = rule) do
    if Map.has_key?(rule, "Priority") and Map.has_key?(rule, "DeleteMarkerReplication") do
      rule
    else
      invalid_stored!()
    end
  end

  defp validate_filter_rule_requirements!(rule), do: rule

  defp validate_tag_delete_marker_replication!(
         %{"Filter" => filter, "DeleteMarkerReplication" => %{"Status" => "Enabled"}} = rule
       ) do
    if filter_has_tag?(filter), do: invalid_stored!(), else: rule
  end

  defp validate_tag_delete_marker_replication!(rule), do: rule

  defp validate_source_selection_criteria_requirements!(
         %{"SourceSelectionCriteria" => criteria} = rule
       ) do
    cond do
      not Map.has_key?(criteria, "SseKmsEncryptedObjects") ->
        invalid_stored!()

      Map.has_key?(criteria, "ReplicaModifications") and not Map.has_key?(rule, "Filter") ->
        invalid_stored!()

      is_nil(get_in(rule, ["Destination", "EncryptionConfiguration"])) ->
        invalid_stored!()

      true ->
        rule
    end
  end

  defp validate_source_selection_criteria_requirements!(rule), do: rule

  defp maybe_put_normalized_string(map, _key, nil), do: map

  defp maybe_put_normalized_string(map, key, value),
    do: Map.put(map, key, normalize_string(value))

  defp maybe_put_non_empty_string(map, _key, nil), do: map

  defp maybe_put_non_empty_string(map, key, value),
    do: Map.put(map, key, normalize_non_empty_string(value))

  defp maybe_count(acc, nil), do: acc
  defp maybe_count(acc, _value), do: [:present | acc]

  defp filter_has_tag?(%{"Tag" => _tag}), do: true
  defp filter_has_tag?(%{"And" => %{"Tags" => tags}}) when is_list(tags), do: tags != []
  defp filter_has_tag?(_filter), do: false

  defp normalize_string(value) when is_binary(value), do: value
  defp normalize_string(_value), do: invalid_stored!()

  defp normalize_non_empty_string(value) when is_binary(value) and value != "", do: value
  defp normalize_non_empty_string(_value), do: invalid_stored!()

  defp normalize_enum(value, allowed) when is_binary(value) do
    if value in allowed, do: value, else: invalid_stored!()
  end

  defp normalize_enum(_value, _allowed), do: invalid_stored!()

  defp normalize_integer(value) when is_integer(value), do: value

  defp normalize_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _other -> invalid_stored!()
    end
  end

  defp normalize_integer(_value), do: invalid_stored!()

  defp normalize_positive_integer(value) do
    integer = normalize_integer(value)

    if integer > 0, do: integer, else: invalid_stored!()
  end

  defp validate_tag_set!([]), do: []

  defp validate_tag_set!(tags) do
    tag_pairs = Enum.map(tags, &{&1["Key"], &1["Value"]})

    case Tags.validate(tag_pairs, :object) do
      :ok -> tags
      {:error, :invalid_tag} -> invalid_stored!()
    end
  end

  defp value(map, keys, default \\ nil) do
    Enum.reduce_while(keys, default, fn key, fallback ->
      case Map.fetch(map, key) do
        {:ok, value} -> {:halt, value}
        :error -> {:cont, fallback}
      end
    end)
  end

  defp invalid_stored!,
    do: raise(Error.new(:internal_error, message: "Invalid stored ReplicationConfiguration"))

  defp rule_matches?(%{"Status" => "Enabled"} = rule, event_name, key, tags) do
    event_matches?(rule, event_name) and prefix_matches?(rule, key) and
      tag_filter_matches?(rule, tags)
  end

  defp rule_matches?(_rule, _event_name, _key, _tags), do: false

  defp event_matches?(_rule, "s3:ObjectCreated:" <> _suffix), do: true

  defp event_matches?(rule, "s3:ObjectRemoved:DeleteMarkerCreated") do
    get_in(rule, ["DeleteMarkerReplication", "Status"]) == "Enabled"
  end

  defp event_matches?(rule, "s3:ObjectRemoved:Delete") do
    get_in(rule, ["DeleteReplication", "Status"]) == "Enabled"
  end

  defp event_matches?(_rule, _event_name), do: false

  defp prefix_matches?(rule, key) do
    prefix =
      cond do
        is_binary(Map.get(rule, "Prefix")) ->
          Map.get(rule, "Prefix")

        is_binary(get_in(rule, ["Filter", "Prefix"])) ->
          get_in(rule, ["Filter", "Prefix"])

        is_binary(get_in(rule, ["Filter", "And", "Prefix"])) ->
          get_in(rule, ["Filter", "And", "Prefix"])

        true ->
          ""
      end

    String.starts_with?(key, prefix)
  end

  defp tag_filter_matches?(rule, tags) when is_map(tags) do
    cond do
      tag = get_in(rule, ["Filter", "Tag"]) ->
        tag_matches?(tag, tags)

      tag_list = get_in(rule, ["Filter", "And", "Tags"]) ->
        Enum.all?(tag_list, &tag_matches?(&1, tags))

      true ->
        true
    end
  end

  defp tag_filter_matches?(_rule, _tags), do: false

  defp tag_matches?(%{"Key" => key, "Value" => value}, tags) do
    Map.get(tags, key) == value or Map.get(tags, to_string(key)) == value
  end

  defp tag_matches?(_tag, _tags), do: false

  defp collapse_overlapping_rules(rules) do
    rules
    |> Enum.group_by(&destination_bucket_name!/1)
    |> Enum.map(fn {_bucket, candidates} ->
      Enum.max_by(candidates, &rule_priority/1)
    end)
  end

  defp task_from_rule(rule, event_name, attrs) do
    destination_bucket = destination_bucket_name!(rule)
    destination = Map.fetch!(rule, "Destination")

    %{
      source_bucket: Map.fetch!(attrs, :bucket),
      source_key: Map.fetch!(attrs, :key),
      source_version_id: Map.fetch!(attrs, :version_id),
      event_name: event_name,
      destination_bucket: destination_bucket,
      rule_id: Map.get(rule, "ID"),
      destination_storage_class: Map.get(destination, "StorageClass"),
      source_etag: Map.get(attrs, :etag),
      source_size: Map.get(attrs, :size)
    }
  end

  defp destination_bucket_name!(%{"Destination" => %{"Bucket" => "arn:aws:s3:::" <> bucket}})
       when bucket != "",
       do: bucket

  defp rule_priority(rule) do
    case Map.get(rule, "Priority") do
      priority when is_integer(priority) -> priority
      nil -> 0
    end
  end
end
