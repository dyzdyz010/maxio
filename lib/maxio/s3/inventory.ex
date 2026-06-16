defmodule Maxio.S3.Inventory do
  @moduledoc """
  Bucket Inventory configuration helpers.

  This slice stores and returns the S3 inventory control-plane configuration.
  It does not generate inventory report objects.
  """

  alias Maxio.BucketConfigs
  alias Maxio.S3.Error

  @max_configs 1_000
  @page_size 100
  @id_pattern ~r/\A[A-Za-z0-9._-]{1,64}\z/
  @valid_formats ~w(CSV ORC Parquet)
  @valid_frequencies ~w(Daily Weekly)
  @valid_included_object_versions ~w(All Current)
  @valid_optional_fields ~w(
    Size LastModifiedDate StorageClass ETag IsMultipartUploaded ReplicationStatus
    EncryptionStatus ObjectLockRetainUntilDate ObjectLockMode ObjectLockLegalHoldStatus
    IntelligentTieringAccessTier BucketKeyStatus ChecksumAlgorithm ObjectAccessControlList
    ObjectOwner LifecycleExpirationDate
  )

  @spec max_configs() :: pos_integer()
  def max_configs, do: @max_configs

  @spec valid_id?(term()) :: boolean()
  def valid_id?(id), do: is_binary(id) and Regex.match?(@id_pattern, id)

  @spec valid_optional_field?(term()) :: boolean()
  def valid_optional_field?(field), do: is_binary(field) and field in @valid_optional_fields

  @spec validate_client_config(map(), String.t()) :: {:ok, map()} | {:error, :malformed_xml}
  def validate_client_config(config, id) when is_map(config) and is_binary(id) do
    normalized = normalize_config(config)

    if normalized["Id"] == id do
      {:ok, normalized}
    else
      {:error, :malformed_xml}
    end
  rescue
    _err in Error -> {:error, :malformed_xml}
  end

  @spec optional_fields(map()) :: [String.t()]
  def optional_fields(config) when is_map(config) do
    config
    |> normalize_config()
    |> Map.get("OptionalFields", [])
  end

  @spec get_config(String.t(), String.t()) :: {:ok, map()} | :none
  def get_config(bucket, id) when is_binary(bucket) and is_binary(id) do
    bucket
    |> all_configs()
    |> Enum.find(&(&1["Id"] == id))
    |> case do
      nil -> :none
      config -> {:ok, config}
    end
  end

  @spec put_config(String.t(), map()) :: :ok
  def put_config(bucket, config) when is_binary(bucket) and is_map(config) do
    config = normalize_config(config)
    existing = all_configs(bucket)
    replaced? = Enum.any?(existing, &(&1["Id"] == config["Id"]))

    if not replaced? and length(existing) >= @max_configs do
      raise Error.new(:too_many_configurations, resource: "/" <> bucket)
    end

    configs =
      existing
      |> Enum.reject(&(&1["Id"] == config["Id"]))
      |> Kernel.++([config])
      |> sort_configs()

    :ok = BucketConfigs.put(bucket, :inventory, %{"Configurations" => configs})
  end

  @spec delete_config(String.t(), String.t()) :: :ok
  def delete_config(bucket, id) when is_binary(bucket) and is_binary(id) do
    configs =
      bucket
      |> all_configs()
      |> Enum.reject(&(&1["Id"] == id))

    if configs == [] do
      BucketConfigs.delete(bucket, :inventory)
    else
      BucketConfigs.put(bucket, :inventory, %{"Configurations" => configs})
    end
  end

  @spec list_configs(String.t(), String.t() | nil) :: map()
  def list_configs(bucket, continuation_token) when is_binary(bucket) do
    configs = all_configs(bucket)

    start_index =
      case continuation_token do
        nil -> 0
        "" -> 0
        token when is_binary(token) -> token_index(configs, token)
      end

    page = configs |> Enum.drop(start_index) |> Enum.take(@page_size)
    next_config = Enum.at(configs, start_index + @page_size)

    %{
      configs: page,
      continuation_token: blank_to_nil(continuation_token),
      next_continuation_token: next_config && List.last(page)["Id"],
      is_truncated: not is_nil(next_config)
    }
  end

  @spec all_configs(String.t()) :: [map()]
  def all_configs(bucket) when is_binary(bucket) do
    case BucketConfigs.get(bucket, :inventory) do
      {:ok, stored} -> normalize_store(stored)
      :none -> []
    end
  end

  @spec normalize_store(map()) :: [map()]
  def normalize_store(%{"Configurations" => configs}) when is_list(configs) do
    configs
    |> Enum.map(&normalize_config/1)
    |> validate_unique_ids!()
    |> sort_configs()
  end

  def normalize_store(%{"configurations" => configs}) when is_list(configs) do
    normalize_store(%{"Configurations" => configs})
  end

  def normalize_store(configs) when is_map(configs) do
    configs
    |> Map.values()
    |> Enum.map(&normalize_config/1)
    |> validate_unique_ids!()
    |> sort_configs()
  end

  def normalize_store(_stored), do: invalid_stored!()

  @spec normalize_config(map()) :: map()
  def normalize_config(config) when is_map(config) do
    id = value(config, ["Id", "ID", "id"])
    destination = value(config, ["Destination", "destination"])
    enabled = value(config, ["IsEnabled", "is_enabled"])
    filter = value(config, ["Filter", "filter"])

    included_object_versions =
      value(config, ["IncludedObjectVersions", "included_object_versions"])

    optional_fields = value(config, ["OptionalFields", "optional_fields"], [])
    schedule = value(config, ["Schedule", "schedule"])

    if valid_id?(id) do
      %{
        "Id" => id,
        "Destination" => normalize_destination(destination),
        "IsEnabled" => normalize_boolean(enabled),
        "IncludedObjectVersions" =>
          normalize_enum(included_object_versions, @valid_included_object_versions),
        "Schedule" => normalize_schedule(schedule)
      }
      |> maybe_put_filter(normalize_filter(filter))
      |> maybe_put_optional_fields(normalize_optional_fields(optional_fields))
    else
      invalid_stored!()
    end
  end

  def normalize_config(_config), do: invalid_stored!()

  defp normalize_destination(destination) when is_map(destination) do
    bucket_destination = value(destination, ["S3BucketDestination", "s3_bucket_destination"])
    %{"S3BucketDestination" => normalize_s3_bucket_destination(bucket_destination)}
  end

  defp normalize_destination(_destination), do: invalid_stored!()

  defp normalize_s3_bucket_destination(destination) when is_map(destination) do
    account_id = value(destination, ["AccountId", "account_id"])
    bucket = value(destination, ["Bucket", "bucket"])
    format = value(destination, ["Format", "format"])
    prefix = value(destination, ["Prefix", "prefix"])
    encryption = value(destination, ["Encryption", "encryption"])

    %{
      "AccountId" => normalize_non_empty_string(account_id),
      "Bucket" => normalize_non_empty_string(bucket),
      "Format" => normalize_enum(format, @valid_formats)
    }
    |> maybe_put_normalized_string("Prefix", prefix)
    |> maybe_put_encryption(normalize_encryption(encryption))
  end

  defp normalize_s3_bucket_destination(_destination), do: invalid_stored!()

  defp normalize_encryption(nil), do: nil

  defp normalize_encryption(encryption) when is_map(encryption) do
    sse_s3 = value(encryption, ["SSE-S3", "SSES3", "sse_s3"])
    sse_kms = value(encryption, ["SSE-KMS", "SSEKMS", "sse_kms"])

    case {sse_s3, sse_kms} do
      {%{}, nil} -> %{"SSE-S3" => %{}}
      {nil, kms} when is_map(kms) -> %{"SSE-KMS" => normalize_sse_kms(kms)}
      _other -> invalid_stored!()
    end
  end

  defp normalize_encryption(_encryption), do: invalid_stored!()

  defp normalize_sse_kms(kms) when is_map(kms) do
    key_id = value(kms, ["KeyId", "key_id"])
    %{"KeyId" => normalize_non_empty_string(key_id)}
  end

  defp normalize_filter(nil), do: nil

  defp normalize_filter(filter) when is_map(filter) do
    prefix = value(filter, ["Prefix", "prefix"])
    %{"Prefix" => normalize_string(prefix)}
  end

  defp normalize_filter(_filter), do: invalid_stored!()

  defp normalize_schedule(schedule) when is_map(schedule) do
    frequency = value(schedule, ["Frequency", "frequency"])
    %{"Frequency" => normalize_enum(frequency, @valid_frequencies)}
  end

  defp normalize_schedule(_schedule), do: invalid_stored!()

  defp normalize_optional_fields(nil), do: []
  defp normalize_optional_fields([]), do: []

  defp normalize_optional_fields(fields) when is_list(fields),
    do: Enum.map(fields, &normalize_optional_field/1)

  defp normalize_optional_fields(field) when is_binary(field),
    do: [normalize_optional_field(field)]

  defp normalize_optional_fields(_fields), do: invalid_stored!()

  defp normalize_optional_field(field) when field in @valid_optional_fields, do: field
  defp normalize_optional_field(_field), do: invalid_stored!()

  defp normalize_boolean(true), do: true
  defp normalize_boolean(false), do: false
  defp normalize_boolean("true"), do: true
  defp normalize_boolean("false"), do: false
  defp normalize_boolean(_value), do: invalid_stored!()

  defp maybe_put_filter(config, nil), do: config
  defp maybe_put_filter(config, filter), do: Map.put(config, "Filter", filter)

  defp maybe_put_optional_fields(config, []), do: config

  defp maybe_put_optional_fields(config, fields) do
    if Enum.uniq(fields) == fields do
      Map.put(config, "OptionalFields", fields)
    else
      invalid_stored!()
    end
  end

  defp maybe_put_encryption(destination, nil), do: destination

  defp maybe_put_encryption(destination, encryption),
    do: Map.put(destination, "Encryption", encryption)

  defp maybe_put_normalized_string(map, _key, nil), do: map

  defp maybe_put_normalized_string(map, key, value),
    do: Map.put(map, key, normalize_string(value))

  defp normalize_string(value) when is_binary(value), do: value
  defp normalize_string(_value), do: invalid_stored!()

  defp normalize_non_empty_string(value) when is_binary(value) and value != "", do: value
  defp normalize_non_empty_string(_value), do: invalid_stored!()

  defp normalize_enum(value, allowed) when is_binary(value) do
    if value in allowed, do: value, else: invalid_stored!()
  end

  defp normalize_enum(_value, _allowed), do: invalid_stored!()

  defp validate_unique_ids!(configs) do
    ids = Enum.map(configs, & &1["Id"])

    if Enum.uniq(ids) == ids do
      configs
    else
      invalid_stored!()
    end
  end

  defp sort_configs(configs), do: Enum.sort_by(configs, & &1["Id"])

  defp token_index(configs, token) do
    case Enum.find_index(configs, &(&1["Id"] == token)) do
      nil -> invalid_token!()
      index -> index + 1
    end
  end

  defp invalid_token! do
    raise Error.new(:invalid_argument, message: "Invalid inventory continuation-token")
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp value(map, keys, default \\ nil) do
    Enum.reduce_while(keys, default, fn key, fallback ->
      case Map.fetch(map, key) do
        {:ok, value} -> {:halt, value}
        :error -> {:cont, fallback}
      end
    end)
  end

  defp invalid_stored!,
    do: raise(Error.new(:internal_error, message: "Invalid stored InventoryConfiguration"))
end
