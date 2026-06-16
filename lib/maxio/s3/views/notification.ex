defmodule Maxio.S3.Views.Notification do
  @moduledoc "GetBucketNotificationConfiguration response XML renderer."
  import Saxy.XML

  alias Maxio.S3.{Notification, XML}

  @spec render(map()) :: iodata()
  def render(config) when is_map(config) do
    config = Notification.normalize(config)

    children =
      []
      |> add_destinations("TopicConfiguration", "Topic", config["TopicConfigurations"])
      |> add_destinations("QueueConfiguration", "Queue", config["QueueConfigurations"])
      |> add_destinations(
        "CloudFunctionConfiguration",
        "CloudFunction",
        config["LambdaFunctionConfigurations"]
      )
      |> add_event_bridge(config["EventBridgeConfiguration"])

    XML.encode(element("NotificationConfiguration", [{"xmlns", XML.namespace()}], children))
  end

  defp add_destinations(children, _tag, _destination_key, []), do: children

  defp add_destinations(children, tag, destination_key, configs) when is_list(configs) do
    children ++ Enum.map(configs, &destination_elem(tag, destination_key, &1))
  end

  defp destination_elem(tag, output_destination_key, config) do
    stored_destination_key =
      if output_destination_key == "CloudFunction",
        do: "LambdaFunction",
        else: output_destination_key

    children =
      []
      |> add_text("Id", config["Id"])
      |> Kernel.++([
        element(output_destination_key, [], characters(config[stored_destination_key]))
      ])
      |> Kernel.++(Enum.map(config["Events"], &element("Event", [], characters(&1))))
      |> add_filter(config["Filter"])

    element(tag, [], children)
  end

  defp add_filter(children, nil), do: children

  defp add_filter(children, %{"S3Key" => %{"FilterRules" => rules}}) do
    children ++
      [
        element("Filter", [], [
          element("S3Key", [], Enum.map(rules, &filter_rule_elem/1))
        ])
      ]
  end

  defp filter_rule_elem(rule) do
    element("FilterRule", [], [
      element("Name", [], characters(rule["Name"])),
      element("Value", [], characters(rule["Value"]))
    ])
  end

  defp add_event_bridge(children, nil), do: children

  defp add_event_bridge(children, %{}),
    do: children ++ [element("EventBridgeConfiguration", [], [])]

  defp add_text(children, _tag, nil), do: children
  defp add_text(children, _tag, ""), do: children
  defp add_text(children, tag, value), do: children ++ [element(tag, [], characters(value))]
end
