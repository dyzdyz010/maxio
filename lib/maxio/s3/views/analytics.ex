defmodule Maxio.S3.Views.Analytics do
  @moduledoc """
  Get/List Bucket Analytics configuration response XML renderer.
  """
  import Saxy.XML

  alias Maxio.S3.{Analytics, XML}

  @spec render_config(map()) :: iodata()
  def render_config(config) when is_map(config) do
    XML.encode(
      element("AnalyticsConfiguration", [{"xmlns", XML.namespace()}], config_children(config))
    )
  end

  @spec render_list(map()) :: iodata()
  def render_list(%{configs: configs} = page) when is_list(configs) do
    children =
      configs
      |> Enum.map(&element("AnalyticsConfiguration", [], config_children(&1)))
      |> Kernel.++([
        element("IsTruncated", [], characters(to_string(page.is_truncated)))
      ])
      |> maybe_text("ContinuationToken", page.continuation_token)
      |> maybe_text("NextContinuationToken", page.next_continuation_token)

    XML.encode(
      element("ListBucketAnalyticsConfigurationResult", [{"xmlns", XML.namespace()}], children)
    )
  end

  defp config_children(config) do
    config = Analytics.normalize_config(config)

    [element("Id", [], characters(config["Id"]))]
    |> add_filter(config["Filter"])
    |> Kernel.++([storage_class_analysis_element(config["StorageClassAnalysis"])])
  end

  defp add_filter(children, nil), do: children

  defp add_filter(children, filter) do
    children ++ [element("Filter", [], filter_children(filter))]
  end

  defp filter_children(%{"Prefix" => prefix}), do: [element("Prefix", [], characters(prefix))]

  defp filter_children(%{"Tag" => tag}), do: [tag_element(tag)]

  defp filter_children(%{"And" => and_operator}) do
    [element("And", [], and_children(and_operator))]
  end

  defp and_children(and_operator) do
    []
    |> maybe_text("Prefix", Map.get(and_operator, "Prefix"))
    |> Kernel.++(Enum.map(Map.get(and_operator, "Tags", []), &tag_element/1))
  end

  defp tag_element(tag) do
    element("Tag", [], [
      element("Key", [], characters(tag["Key"])),
      element("Value", [], characters(tag["Value"]))
    ])
  end

  defp storage_class_analysis_element(analysis) do
    children =
      []
      |> add_data_export(analysis["DataExport"])

    element("StorageClassAnalysis", [], children)
  end

  defp add_data_export(children, nil), do: children

  defp add_data_export(children, data_export) do
    children ++
      [
        element("DataExport", [], [
          element("OutputSchemaVersion", [], characters(data_export["OutputSchemaVersion"])),
          destination_element(data_export["Destination"])
        ])
      ]
  end

  defp destination_element(%{"S3BucketDestination" => destination}) do
    element("Destination", [], [
      element("S3BucketDestination", [], s3_bucket_destination_children(destination))
    ])
  end

  defp s3_bucket_destination_children(destination) do
    [
      element("Format", [], characters(destination["Format"])),
      element("Bucket", [], characters(destination["Bucket"]))
    ]
    |> maybe_text("BucketAccountId", destination["BucketAccountId"])
    |> maybe_text("Prefix", destination["Prefix"])
  end

  defp maybe_text(children, _tag, nil), do: children
  defp maybe_text(children, _tag, ""), do: children
  defp maybe_text(children, tag, value), do: children ++ [element(tag, [], characters(value))]
end
