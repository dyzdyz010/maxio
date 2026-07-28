defmodule Maxio.S3.Views.Inventory do
  @moduledoc """
  Get/List Bucket Inventory configuration response XML renderer.
  """
  import Saxy.XML

  alias Maxio.S3.{Inventory, XML}

  @spec render_config(map()) :: iodata()
  def render_config(config) when is_map(config) do
    XML.encode(
      element("InventoryConfiguration", [{"xmlns", XML.namespace()}], config_children(config))
    )
  end

  @spec render_list(map()) :: iodata()
  def render_list(%{configs: configs} = page) when is_list(configs) do
    children =
      configs
      |> Enum.map(&element("InventoryConfiguration", [], config_children(&1)))
      |> Kernel.++([
        element("IsTruncated", [], characters(to_string(page.is_truncated)))
      ])
      |> maybe_text("ContinuationToken", page.continuation_token)
      |> maybe_text("NextContinuationToken", page.next_continuation_token)

    XML.encode(
      element("ListInventoryConfigurationsResult", [{"xmlns", XML.namespace()}], children)
    )
  end

  defp config_children(config) do
    config = Inventory.normalize_config(config)

    [
      destination_element(config["Destination"]),
      element("IsEnabled", [], characters(to_string(config["IsEnabled"]))),
      element("Id", [], characters(config["Id"]))
    ]
    |> add_filter(config["Filter"])
    |> Kernel.++([
      element("IncludedObjectVersions", [], characters(config["IncludedObjectVersions"]))
    ])
    |> add_optional_fields(config["OptionalFields"])
    |> Kernel.++([schedule_element(config["Schedule"])])
  end

  defp destination_element(%{"S3BucketDestination" => destination}) do
    element("Destination", [], [
      element("S3BucketDestination", [], s3_bucket_destination_children(destination))
    ])
  end

  defp s3_bucket_destination_children(destination) do
    []
    |> maybe_text("AccountId", destination["AccountId"])
    |> Kernel.++([
      element("Bucket", [], characters(destination["Bucket"])),
      element("Format", [], characters(destination["Format"]))
    ])
    |> maybe_text("Prefix", destination["Prefix"])
    |> add_encryption(destination["Encryption"])
  end

  defp add_encryption(children, nil), do: children

  defp add_encryption(children, %{"SSE-S3" => %{}}),
    do: children ++ [element("Encryption", [], [element("SSE-S3", [], [])])]

  defp add_encryption(children, %{"SSE-KMS" => %{"KeyId" => key_id}}) do
    children ++
      [
        element("Encryption", [], [
          element("SSE-KMS", [], [element("KeyId", [], characters(key_id))])
        ])
      ]
  end

  defp add_filter(children, nil), do: children

  defp add_filter(children, %{"Prefix" => prefix}) do
    children ++ [element("Filter", [], [element("Prefix", [], characters(prefix))])]
  end

  defp add_optional_fields(children, nil), do: children
  defp add_optional_fields(children, []), do: children

  defp add_optional_fields(children, fields) when is_list(fields) do
    children ++
      [
        element(
          "OptionalFields",
          [],
          Enum.map(fields, &element("Field", [], characters(&1)))
        )
      ]
  end

  defp schedule_element(%{"Frequency" => frequency}) do
    element("Schedule", [], [element("Frequency", [], characters(frequency))])
  end

  defp maybe_text(children, _tag, nil), do: children
  defp maybe_text(children, _tag, ""), do: children
  defp maybe_text(children, tag, value), do: children ++ [element(tag, [], characters(value))]
end
