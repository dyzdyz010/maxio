defmodule Maxio.S3.Notification do
  @moduledoc """
  Bucket notification configuration helpers.

  This stores and renders the S3 NotificationConfiguration control-plane
  document. Actual event delivery to SNS/SQS/Lambda/EventBridge is a separate
  data-plane feature and is not implemented in this slice.
  """

  alias Maxio.BucketConfigs
  alias Maxio.S3.Error

  @known_events ~w(
    s3:ObjectCreated:*
    s3:ObjectCreated:Put
    s3:ObjectCreated:Post
    s3:ObjectCreated:Copy
    s3:ObjectCreated:CompleteMultipartUpload
    s3:ObjectRemoved:*
    s3:ObjectRemoved:Delete
    s3:ObjectRemoved:DeleteMarkerCreated
    s3:ObjectRestore:*
    s3:ObjectRestore:Post
    s3:ObjectRestore:Completed
    s3:ObjectRestore:Delete
    s3:ReducedRedundancyLostObject
    s3:Replication:*
    s3:Replication:OperationFailedReplication
    s3:Replication:OperationMissedThreshold
    s3:Replication:OperationReplicatedAfterThreshold
    s3:Replication:OperationNotTracked
    s3:LifecycleExpiration:*
    s3:LifecycleExpiration:Delete
    s3:LifecycleExpiration:DeleteMarkerCreated
    s3:LifecycleTransition
    s3:IntelligentTiering
    s3:ObjectAcl:Put
    s3:ObjectTagging:*
    s3:ObjectTagging:Put
    s3:ObjectTagging:Delete
  )

  @empty %{
    "TopicConfigurations" => [],
    "QueueConfigurations" => [],
    "LambdaFunctionConfigurations" => [],
    "EventBridgeConfiguration" => nil
  }

  @spec empty() :: map()
  def empty, do: @empty

  @spec known_event?(term()) :: boolean()
  def known_event?(event), do: event in @known_events

  @spec empty_config?(map()) :: boolean()
  def empty_config?(config) when is_map(config) do
    normalized = normalize(config)

    normalized["TopicConfigurations"] == [] and
      normalized["QueueConfigurations"] == [] and
      normalized["LambdaFunctionConfigurations"] == [] and
      is_nil(normalized["EventBridgeConfiguration"])
  end

  @spec normalize(map()) :: map()
  def normalize(config) when is_map(config) do
    topic = value(config, ["TopicConfigurations", "topic_configurations"], [])
    queue = value(config, ["QueueConfigurations", "queue_configurations"], [])

    lambda =
      value(
        config,
        ["LambdaFunctionConfigurations", "lambda_function_configurations"],
        value(config, ["CloudFunctionConfigurations", "cloud_function_configurations"], [])
      )

    event_bridge =
      value(config, ["EventBridgeConfiguration", "event_bridge_configuration"])

    normalized = %{
      "TopicConfigurations" => normalize_destination_list!(topic, "Topic"),
      "QueueConfigurations" => normalize_destination_list!(queue, "Queue"),
      "LambdaFunctionConfigurations" => normalize_destination_list!(lambda, "LambdaFunction"),
      "EventBridgeConfiguration" => normalize_event_bridge!(event_bridge)
    }

    if unique_destination_ids?(normalized) and non_overlapping_filters?(normalized) do
      normalized
    else
      invalid_stored!()
    end
  end

  @spec validate_client_config(map()) :: {:ok, map()} | {:error, :malformed_xml}
  def validate_client_config(config) when is_map(config) do
    {:ok, normalize(config)}
  rescue
    _err in Error -> {:error, :malformed_xml}
  end

  @spec get_config(String.t()) :: {:ok, map()}
  def get_config(bucket) when is_binary(bucket) do
    case BucketConfigs.get(bucket, :notification) do
      {:ok, config} -> {:ok, normalize(config)}
      :none -> {:ok, @empty}
    end
  end

  defp normalize_destination_list!(list, destination_key) when is_list(list) do
    Enum.map(list, &normalize_destination!(&1, destination_key))
  end

  defp normalize_destination_list!(_list, _destination_key), do: invalid_stored!()

  defp normalize_destination!(config, destination_key) when is_map(config) do
    destination = value(config, [destination_key, Macro.underscore(destination_key)])
    events = value(config, ["Events", "events"], [])
    id = value(config, ["Id", "ID", "id"])
    filter = value(config, ["Filter", "filter"])

    cond do
      not non_empty_string?(destination) ->
        invalid_stored!()

      not is_list(events) or events == [] or Enum.any?(events, &(not known_event?(&1))) ->
        invalid_stored!()

      true ->
        %{
          destination_key => destination,
          "Events" => events,
          "Id" => normalize_optional_string!(id),
          "Filter" => normalize_filter!(filter)
        }
    end
  end

  defp normalize_destination!(_config, _destination_key), do: invalid_stored!()

  defp normalize_filter!(nil), do: nil

  defp normalize_filter!(%{"S3Key" => %{"FilterRules" => rules}}) when is_list(rules) do
    normalize_filter_rules!(rules)
  end

  defp normalize_filter!(%{"s3_key" => %{"filter_rules" => rules}}) when is_list(rules) do
    normalize_filter_rules!(rules)
  end

  defp normalize_filter!(_filter), do: invalid_stored!()

  defp normalize_filter_rules!(rules) when is_list(rules) do
    normalized = Enum.map(rules, &normalize_filter_rule!/1)
    names = Enum.map(normalized, & &1["Name"])

    if normalized != [] and Enum.uniq(names) == names do
      %{"S3Key" => %{"FilterRules" => normalized}}
    else
      invalid_stored!()
    end
  end

  defp normalize_filter_rule!(rule) when is_map(rule) do
    name = value(rule, ["Name", "name"])
    value = value(rule, ["Value", "value"])

    if name in ["prefix", "suffix"] and valid_filter_value?(value) do
      %{"Name" => name, "Value" => value}
    else
      invalid_stored!()
    end
  end

  defp normalize_filter_rule!(_rule), do: invalid_stored!()

  defp normalize_event_bridge!(nil), do: nil
  defp normalize_event_bridge!(config) when is_map(config) and map_size(config) == 0, do: %{}
  defp normalize_event_bridge!(_config), do: invalid_stored!()

  defp normalize_optional_string!(nil), do: nil
  defp normalize_optional_string!(""), do: nil
  defp normalize_optional_string!(value) when is_binary(value), do: value
  defp normalize_optional_string!(_value), do: invalid_stored!()

  defp unique_destination_ids?(config) do
    configs =
      config["TopicConfigurations"] ++
        config["QueueConfigurations"] ++ config["LambdaFunctionConfigurations"]

    ids =
      configs
      |> Enum.map(& &1["Id"])
      |> Enum.reject(&is_nil/1)

    Enum.uniq(ids) == ids
  end

  defp non_overlapping_filters?(config) do
    entries =
      config
      |> destination_configs()
      |> Enum.flat_map(&notification_entries/1)

    entries
    |> pairs()
    |> Enum.all?(fn {left, right} ->
      not (event_overlaps?(left.event, right.event) and
             filter_overlaps?(left.filter, right.filter))
    end)
  end

  defp destination_configs(config) do
    config["TopicConfigurations"] ++
      config["QueueConfigurations"] ++ config["LambdaFunctionConfigurations"]
  end

  defp notification_entries(destination) do
    filter = filter_match(destination["Filter"])
    Enum.map(destination["Events"], &%{event: &1, filter: filter})
  end

  defp filter_match(nil), do: %{prefix: "", suffix: ""}

  defp filter_match(%{"S3Key" => %{"FilterRules" => rules}}) do
    Enum.reduce(rules, %{prefix: "", suffix: ""}, fn
      %{"Name" => "prefix", "Value" => value}, acc ->
        %{acc | prefix: decode_filter_value!(value)}

      %{"Name" => "suffix", "Value" => value}, acc ->
        %{acc | suffix: decode_filter_value!(value)}
    end)
  end

  defp pairs([]), do: []
  defp pairs([_one]), do: []

  defp pairs([head | tail]) do
    Enum.map(tail, &{head, &1}) ++ pairs(tail)
  end

  defp event_overlaps?(event, event), do: true

  defp event_overlaps?(left, right) do
    event_wildcard_covers?(left, right) or event_wildcard_covers?(right, left)
  end

  defp event_wildcard_covers?(wildcard, event) do
    String.ends_with?(wildcard, ":*") and
      String.starts_with?(event, String.trim_trailing(wildcard, "*"))
  end

  defp filter_overlaps?(left, right) do
    prefix_overlaps?(left.prefix, right.prefix) and suffix_overlaps?(left.suffix, right.suffix)
  end

  defp prefix_overlaps?(left, right) do
    String.starts_with?(left, right) or String.starts_with?(right, left)
  end

  defp suffix_overlaps?(left, right) do
    String.ends_with?(left, right) or String.ends_with?(right, left)
  end

  defp valid_filter_value?(value) when is_binary(value) do
    valid_encoded_filter_chars?(String.to_charlist(value)) and
      match?({:ok, _}, decode_filter_value(value))
  end

  defp valid_filter_value?(_value), do: false

  defp valid_encoded_filter_chars?([]), do: true

  defp valid_encoded_filter_chars?([?%, high, low | rest]) do
    hex_digit?(high) and hex_digit?(low) and valid_encoded_filter_chars?(rest)
  end

  defp valid_encoded_filter_chars?([char | rest]) do
    raw_filter_char?(char) and valid_encoded_filter_chars?(rest)
  end

  defp raw_filter_char?(char)
       when char in ?a..?z or char in ?A..?Z or char in ?0..?9 or
              char in [?-, ?_, ?., ?~, ?/, ?+],
       do: true

  defp raw_filter_char?(_char), do: false

  defp hex_digit?(char),
    do: char in ?0..?9 or char in ?a..?f or char in ?A..?F

  defp decode_filter_value!(value) do
    case decode_filter_value(value) do
      {:ok, decoded} -> decoded
      :error -> invalid_stored!()
    end
  end

  defp decode_filter_value(value) do
    with encoded when is_binary(encoded) <- decode_filter_chars(String.to_charlist(value), []),
         decoded when is_binary(decoded) <- :unicode.characters_to_binary(encoded, :utf8) do
      {:ok, decoded}
    else
      _error -> :error
    end
  end

  defp decode_filter_chars([], acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp decode_filter_chars([?%, high, low | rest], acc) do
    byte = String.to_integer(<<high, low>>, 16)
    decode_filter_chars(rest, [byte | acc])
  end

  defp decode_filter_chars([?+ | rest], acc), do: decode_filter_chars(rest, [?\s | acc])

  defp decode_filter_chars([char | rest], acc) when char < 128 do
    decode_filter_chars(rest, [char | acc])
  end

  defp decode_filter_chars(_chars, _acc), do: :error

  defp value(map, keys, default \\ nil) do
    Enum.reduce_while(keys, default, fn key, fallback ->
      case Map.fetch(map, key) do
        {:ok, value} -> {:halt, value}
        :error -> {:cont, fallback}
      end
    end)
  end

  defp non_empty_string?(value), do: is_binary(value) and value != ""

  defp invalid_stored!,
    do: raise(Error.new(:internal_error, message: "Invalid stored NotificationConfiguration"))
end
