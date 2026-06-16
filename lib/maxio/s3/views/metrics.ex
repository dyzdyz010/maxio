defmodule Maxio.S3.Views.Metrics do
  @moduledoc """
  Get/List Bucket Metrics configuration response XML renderer.
  """
  import Saxy.XML

  alias Maxio.S3.{Metrics, XML}

  @spec render_config(map()) :: iodata()
  def render_config(config) when is_map(config) do
    XML.encode(
      element("MetricsConfiguration", [{"xmlns", XML.namespace()}], config_children(config))
    )
  end

  @spec render_list(map()) :: iodata()
  def render_list(%{configs: configs} = page) when is_list(configs) do
    children =
      configs
      |> Enum.map(&element("MetricsConfiguration", [], config_children(&1)))
      |> Kernel.++([
        element("IsTruncated", [], characters(to_string(page.is_truncated)))
      ])
      |> maybe_text("ContinuationToken", page.continuation_token)
      |> maybe_text("NextContinuationToken", page.next_continuation_token)

    XML.encode(element("ListMetricsConfigurationsResult", [{"xmlns", XML.namespace()}], children))
  end

  defp config_children(config) do
    config = Metrics.normalize_config(config)

    [element("Id", [], characters(config["Id"]))]
    |> add_filter(config["Filter"])
  end

  defp add_filter(children, nil), do: children

  defp add_filter(children, filter) do
    children ++ [element("Filter", [], filter_children(filter))]
  end

  defp filter_children(%{"Prefix" => prefix}), do: [element("Prefix", [], characters(prefix))]

  defp filter_children(%{"Tag" => tag}), do: [tag_element(tag)]

  defp filter_children(%{"AccessPointArn" => arn}),
    do: [element("AccessPointArn", [], characters(arn))]

  defp filter_children(%{"And" => and_operator}) do
    [element("And", [], and_children(and_operator))]
  end

  defp and_children(and_operator) do
    []
    |> maybe_text("Prefix", Map.get(and_operator, "Prefix"))
    |> Kernel.++(Enum.map(Map.get(and_operator, "Tags", []), &tag_element/1))
    |> maybe_text("AccessPointArn", Map.get(and_operator, "AccessPointArn"))
  end

  defp tag_element(tag) do
    element("Tag", [], [
      element("Key", [], characters(tag["Key"])),
      element("Value", [], characters(tag["Value"]))
    ])
  end

  defp maybe_text(children, _tag, nil), do: children
  defp maybe_text(children, _tag, ""), do: children
  defp maybe_text(children, tag, value), do: children ++ [element(tag, [], characters(value))]
end
