defmodule Maxio.S3.Analytics do
  @moduledoc """
  Bucket Analytics configuration helpers.

  This slice stores and returns the S3 analytics control-plane configuration.
  It does not export analytics data.
  """

  alias Maxio.BucketConfigs
  alias Maxio.S3.Error
  alias Maxio.Tags

  @max_configs 1_000
  @page_size 100
  @id_pattern ~r/\A[A-Za-z0-9._-]{1,64}\z/
  @storage_class_analysis_data_export_version "V_1"
  @valid_output_schema_versions ~w(V_1)
  @valid_s3_bucket_destination_formats ~w(CSV)

  @spec max_configs() :: pos_integer()
  def max_configs, do: @max_configs

  @spec valid_id?(term()) :: boolean()
  def valid_id?(id), do: is_binary(id) and Regex.match?(@id_pattern, id)

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

    :ok = BucketConfigs.put(bucket, :analytics, %{"Configurations" => configs})
  end

  @spec delete_config(String.t(), String.t()) :: :ok
  def delete_config(bucket, id) when is_binary(bucket) and is_binary(id) do
    configs =
      bucket
      |> all_configs()
      |> Enum.reject(&(&1["Id"] == id))

    if configs == [] do
      BucketConfigs.delete(bucket, :analytics)
    else
      BucketConfigs.put(bucket, :analytics, %{"Configurations" => configs})
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
    case BucketConfigs.get(bucket, :analytics) do
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
    filter = value(config, ["Filter", "filter"])
    storage_class_analysis = value(config, ["StorageClassAnalysis", "storage_class_analysis"])

    if valid_id?(id) do
      %{
        "Id" => id,
        "StorageClassAnalysis" => normalize_storage_class_analysis(storage_class_analysis)
      }
      |> maybe_put_filter(normalize_filter(filter))
    else
      invalid_stored!()
    end
  end

  def normalize_config(_config), do: invalid_stored!()

  defp normalize_filter(nil), do: nil

  defp normalize_filter(filter) when is_map(filter) do
    keys =
      [
        {"Prefix", value(filter, ["Prefix", "prefix"])},
        {"Tag", value(filter, ["Tag", "tag"])},
        {"And", value(filter, ["And", "and"])}
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    case keys do
      [] -> invalid_stored!()
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

  defp normalize_storage_class_analysis(nil), do: invalid_stored!()

  defp normalize_storage_class_analysis(analysis) when is_map(analysis) do
    data_export = value(analysis, ["DataExport", "data_export"])

    %{}
    |> maybe_put_data_export(normalize_data_export(data_export))
  end

  defp normalize_storage_class_analysis(_analysis), do: invalid_stored!()

  defp normalize_data_export(nil), do: nil

  defp normalize_data_export(data_export) when is_map(data_export) do
    output_schema_version =
      value(data_export, ["OutputSchemaVersion", "output_schema_version"])
      |> normalize_enum(@valid_output_schema_versions)

    destination = value(data_export, ["Destination", "destination"])

    %{
      "OutputSchemaVersion" => output_schema_version,
      "Destination" => normalize_destination(destination)
    }
  end

  defp normalize_data_export(_data_export), do: invalid_stored!()

  defp normalize_destination(destination) when is_map(destination) do
    s3_bucket_destination =
      value(destination, ["S3BucketDestination", "s3_bucket_destination"])

    %{"S3BucketDestination" => normalize_s3_bucket_destination(s3_bucket_destination)}
  end

  defp normalize_destination(_destination), do: invalid_stored!()

  defp normalize_s3_bucket_destination(destination) when is_map(destination) do
    format =
      destination
      |> value(["Format", "format"])
      |> normalize_enum(@valid_s3_bucket_destination_formats)

    bucket_account_id = value(destination, ["BucketAccountId", "bucket_account_id"])
    bucket = value(destination, ["Bucket", "bucket"])
    prefix = value(destination, ["Prefix", "prefix"])

    %{"Format" => format, "Bucket" => normalize_non_empty_string(bucket)}
    |> maybe_put_non_empty_string("BucketAccountId", bucket_account_id)
    |> maybe_put_normalized_string("Prefix", prefix)
  end

  defp normalize_s3_bucket_destination(_destination), do: invalid_stored!()

  defp maybe_put_data_export(analysis, nil), do: analysis

  defp maybe_put_data_export(analysis, data_export),
    do: Map.put(analysis, "DataExport", data_export)

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

  defp maybe_put_filter(config, nil), do: config
  defp maybe_put_filter(config, filter), do: Map.put(config, "Filter", filter)

  defp maybe_put_normalized_string(map, _key, nil), do: map

  defp maybe_put_normalized_string(map, key, value),
    do: Map.put(map, key, normalize_string(value))

  defp maybe_put_non_empty_string(map, _key, nil), do: map

  defp maybe_put_non_empty_string(map, key, value),
    do: Map.put(map, key, normalize_non_empty_string(value))

  defp maybe_count(acc, nil), do: acc
  defp maybe_count(acc, _value), do: [:present | acc]

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

  defp validate_tag_set!([]), do: []

  defp validate_tag_set!(tags) do
    tag_pairs = Enum.map(tags, &{&1["Key"], &1["Value"]})

    case Tags.validate(tag_pairs, :object) do
      :ok -> tags
      {:error, :invalid_tag} -> invalid_stored!()
    end
  end

  def storage_class_analysis_data_export_version,
    do: @storage_class_analysis_data_export_version

  defp invalid_token! do
    raise Error.new(:invalid_argument, message: "Invalid analytics continuation-token")
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
    do: raise(Error.new(:internal_error, message: "Invalid stored AnalyticsConfiguration"))
end
