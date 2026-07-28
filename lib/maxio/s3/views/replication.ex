defmodule Maxio.S3.Views.Replication do
  @moduledoc """
  GetBucketReplication response XML renderer.
  """
  import Saxy.XML

  alias Maxio.S3.{Replication, XML}

  @spec render_config(map()) :: iodata()
  def render_config(config) when is_map(config) do
    XML.encode(
      element("ReplicationConfiguration", [{"xmlns", XML.namespace()}], config_children(config))
    )
  end

  defp config_children(config) do
    config = Replication.normalize_config(config)

    [
      element("Role", [], characters(config["Role"]))
      | Enum.map(config["Rules"], &rule_element/1)
    ]
  end

  defp rule_element(rule) do
    element(
      "Rule",
      [],
      []
      |> maybe_text("ID", rule["ID"])
      |> maybe_integer("Priority", rule["Priority"])
      |> add_legacy_prefix(rule["Prefix"])
      |> add_filter(rule["Filter"])
      |> Kernel.++([
        element("Status", [], characters(rule["Status"])),
        destination_element(rule["Destination"])
      ])
      |> add_status_block("DeleteMarkerReplication", rule["DeleteMarkerReplication"])
      |> add_status_block("DeleteReplication", rule["DeleteReplication"])
      |> add_status_block("ExistingObjectReplication", rule["ExistingObjectReplication"])
      |> add_source_selection_criteria(rule["SourceSelectionCriteria"])
    )
  end

  defp add_legacy_prefix(children, nil), do: children

  defp add_legacy_prefix(children, prefix),
    do: children ++ [element("Prefix", [], characters(prefix))]

  defp add_filter(children, nil), do: children

  defp add_filter(children, filter) do
    children ++ [element("Filter", [], filter_children(filter))]
  end

  defp filter_children(filter) when filter == %{}, do: []
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

  defp destination_element(destination) do
    children =
      [element("Bucket", [], characters(destination["Bucket"]))]
      |> maybe_text("Account", destination["Account"])
      |> maybe_text("StorageClass", destination["StorageClass"])
      |> add_encryption(destination["EncryptionConfiguration"])
      |> add_access_control_translation(destination["AccessControlTranslation"])
      |> add_metrics(destination["Metrics"])
      |> add_replication_time(destination["ReplicationTime"])

    element("Destination", [], children)
  end

  defp add_encryption(children, nil), do: children

  defp add_encryption(children, %{"ReplicaKmsKeyID" => key_id}) do
    children ++
      [
        element("EncryptionConfiguration", [], [
          element("ReplicaKmsKeyID", [], characters(key_id))
        ])
      ]
  end

  defp add_access_control_translation(children, nil), do: children

  defp add_access_control_translation(children, %{"Owner" => owner}) do
    children ++
      [
        element("AccessControlTranslation", [], [
          element("Owner", [], characters(owner))
        ])
      ]
  end

  defp add_metrics(children, nil), do: children

  defp add_metrics(children, metrics) do
    metric_children =
      [element("Status", [], characters(metrics["Status"]))]
      |> add_time_block("EventThreshold", metrics["EventThreshold"])

    children ++ [element("Metrics", [], metric_children)]
  end

  defp add_replication_time(children, nil), do: children

  defp add_replication_time(children, replication_time) do
    children ++
      [
        element("ReplicationTime", [], [
          element("Status", [], characters(replication_time["Status"])),
          time_element("Time", replication_time["Time"])
        ])
      ]
  end

  defp add_time_block(children, _tag, nil), do: children
  defp add_time_block(children, tag, time), do: children ++ [time_element(tag, time)]

  defp time_element(tag, %{"Minutes" => minutes}) do
    element(tag, [], [element("Minutes", [], characters(Integer.to_string(minutes)))])
  end

  defp add_status_block(children, _tag, nil), do: children

  defp add_status_block(children, tag, %{"Status" => status}) do
    children ++ [element(tag, [], [element("Status", [], characters(status))])]
  end

  defp add_source_selection_criteria(children, nil), do: children

  defp add_source_selection_criteria(children, criteria) do
    source_children =
      []
      |> add_status_block("SseKmsEncryptedObjects", criteria["SseKmsEncryptedObjects"])
      |> add_status_block("ReplicaModifications", criteria["ReplicaModifications"])

    children ++ [element("SourceSelectionCriteria", [], source_children)]
  end

  defp maybe_text(children, _tag, nil), do: children
  defp maybe_text(children, _tag, ""), do: children
  defp maybe_text(children, tag, value), do: children ++ [element(tag, [], characters(value))]

  defp maybe_integer(children, _tag, nil), do: children

  defp maybe_integer(children, tag, value) when is_integer(value),
    do: children ++ [element(tag, [], characters(Integer.to_string(value)))]
end
