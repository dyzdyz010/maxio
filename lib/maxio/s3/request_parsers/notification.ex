defmodule Maxio.S3.RequestParsers.Notification do
  @moduledoc """
  Strict PutBucketNotificationConfiguration NotificationConfiguration XML parser.

  The parser owns XML shape, duplicate-field, and scalar syntax validation. The
  `Maxio.S3.Notification` domain module still owns cross-destination semantics
  and stores the normalized configuration contract used by S3 handlers and
  Console JSON callers.
  """

  alias Maxio.S3.Notification
  alias Maxio.S3.RequestParsers.XMLTree

  @unset {:__maxio_notification_unset__, []}

  @spec parse(binary()) :: {:ok, map()} | {:error, :malformed_xml}
  def parse(xml) when is_binary(xml) do
    with {:ok, {"NotificationConfiguration", _attrs, children}} <- XMLTree.parse(xml),
         {:ok, config} <- parse_config(children),
         {:ok, config} <- Notification.validate_client_config(config) do
      {:ok, config}
    else
      _other -> {:error, :malformed_xml}
    end
  end

  defp parse_config(children) do
    children
    |> XMLTree.structural_children()
    |> Enum.reduce_while({:ok, Notification.empty(), false}, fn
      {"TopicConfiguration", _attrs, children}, {:ok, config, event_bridge_seen?} ->
        put_destination(config, event_bridge_seen?, "TopicConfigurations", "Topic", children)

      {"QueueConfiguration", _attrs, children}, {:ok, config, event_bridge_seen?} ->
        put_destination(config, event_bridge_seen?, "QueueConfigurations", "Queue", children)

      {"CloudFunctionConfiguration", _attrs, children}, {:ok, config, event_bridge_seen?} ->
        put_destination(
          config,
          event_bridge_seen?,
          "LambdaFunctionConfigurations",
          "LambdaFunction",
          children
        )

      {"EventBridgeConfiguration", _attrs, children}, {:ok, config, false} ->
        if XMLTree.structural_children(children) == [] do
          {:cont, {:ok, Map.put(config, "EventBridgeConfiguration", %{}), true}}
        else
          {:halt, :error}
        end

      _other, _acc ->
        {:halt, :error}
    end)
    |> case do
      {:ok, config, _event_bridge_seen?} -> {:ok, config}
      :error -> :error
    end
  end

  defp put_destination(config, event_bridge_seen?, list_key, destination_key, children) do
    case parse_destination(destination_key, children) do
      {:ok, destination} ->
        {:cont, {:ok, Map.update!(config, list_key, &(&1 ++ [destination])), event_bridge_seen?}}

      :error ->
        {:halt, :error}
    end
  end

  defp parse_destination(destination_key, children) do
    initial = %{
      destination_key => @unset,
      "Events" => [],
      "Id" => @unset,
      "Filter" => @unset
    }

    children
    |> XMLTree.structural_children()
    |> Enum.reduce_while({:ok, initial, MapSet.new()}, fn
      {"Id", _attrs, children}, {:ok, destination, events_seen} ->
        put_once_destination(destination, events_seen, "Id", optional_text(children))

      {^destination_key, _attrs, children}, {:ok, destination, events_seen} ->
        put_once_destination(destination, events_seen, destination_key, required_text(children))

      {"CloudFunction", _attrs, children}, {:ok, destination, events_seen}
      when destination_key == "LambdaFunction" ->
        put_once_destination(destination, events_seen, destination_key, required_text(children))

      {"Event", _attrs, children}, {:ok, destination, events_seen} ->
        put_event(destination, events_seen, children)

      {"Filter", _attrs, children}, {:ok, destination, events_seen} ->
        with {:ok, filter} <- parse_filter(children) do
          put_once_destination(destination, events_seen, "Filter", {:ok, filter})
        else
          _other -> {:halt, :error}
        end

      _other, _acc ->
        {:halt, :error}
    end)
    |> case do
      {:ok, destination, _events_seen} ->
        destination = normalize_unset_fields(destination)

        if is_binary(destination[destination_key]) and destination["Events"] != [] do
          {:ok, destination}
        else
          :error
        end

      :error ->
        :error
    end
  end

  defp put_event(destination, events_seen, children) do
    with {:ok, event} <- required_text(children),
         true <- Notification.known_event?(event),
         false <- MapSet.member?(events_seen, event) do
      {:cont,
       {:ok, Map.update!(destination, "Events", &(&1 ++ [event])), MapSet.put(events_seen, event)}}
    else
      _other -> {:halt, :error}
    end
  end

  defp parse_filter(children) do
    case XMLTree.structural_children(children) do
      [{"S3Key", _attrs, children}] ->
        parse_s3_key_filter(children)

      _other ->
        :error
    end
  end

  defp parse_s3_key_filter(children) do
    children
    |> XMLTree.structural_children()
    |> Enum.reduce_while({:ok, []}, fn
      {"FilterRule", _attrs, children}, {:ok, rules} ->
        case parse_filter_rule(children) do
          {:ok, rule} -> {:cont, {:ok, rules ++ [rule]}}
          :error -> {:halt, :error}
        end

      _other, _acc ->
        {:halt, :error}
    end)
    |> case do
      {:ok, rules} when rules != [] -> {:ok, %{"S3Key" => %{"FilterRules" => rules}}}
      _other -> :error
    end
  end

  defp parse_filter_rule(children) do
    children
    |> XMLTree.structural_children()
    |> Enum.reduce_while({:ok, %{"Name" => @unset, "Value" => @unset}}, fn
      {"Name", _attrs, children}, {:ok, rule} ->
        put_once(rule, "Name", required_text(children))

      {"Value", _attrs, children}, {:ok, rule} ->
        put_once(rule, "Value", text(children))

      _other, _acc ->
        {:halt, :error}
    end)
    |> case do
      {:ok, rule} ->
        rule = normalize_unset_fields(rule)
        validate_filter_rule(rule)

      :error ->
        :error
    end
  end

  defp validate_filter_rule(%{"Name" => name, "Value" => value})
       when name in ["prefix", "suffix"] and is_binary(value) do
    {:ok, %{"Name" => name, "Value" => value}}
  end

  defp validate_filter_rule(_rule), do: :error

  defp normalize_unset_fields(map) do
    Map.new(map, fn
      {key, @unset} -> {key, nil}
      {key, value} -> {key, value}
    end)
  end

  defp put_once_destination(map, events_seen, key, {:ok, value}) do
    case put_once_value(map, key, value) do
      {:ok, map} -> {:cont, {:ok, map, events_seen}}
      :error -> {:halt, :error}
    end
  end

  defp put_once_destination(_map, _events_seen, _key, :error), do: {:halt, :error}

  defp put_once(map, key, {:ok, value}) do
    case put_once_value(map, key, value) do
      {:ok, map} -> {:cont, {:ok, map}}
      :error -> {:halt, :error}
    end
  end

  defp put_once(_map, _key, :error), do: {:halt, :error}

  defp put_once_value(map, key, value) do
    if Map.fetch!(map, key) == @unset do
      {:ok, Map.put(map, key, value)}
    else
      :error
    end
  end

  defp text(children), do: XMLTree.text(children)
  defp required_text(children), do: XMLTree.required_text(children, trim: true)

  defp optional_text(children) do
    case XMLTree.text(children, trim: true) do
      {:ok, ""} -> {:ok, nil}
      other -> other
    end
  end
end
