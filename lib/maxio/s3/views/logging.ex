defmodule Maxio.S3.Views.Logging do
  @moduledoc "GetBucketLogging response XML renderer."
  import Saxy.XML

  alias Maxio.S3.{Logging, XML}

  @xsi "http://www.w3.org/2001/XMLSchema-instance"

  @spec render(map()) :: iodata()
  def render(config) when is_map(config) do
    %{"LoggingEnabled" => enabled} = Logging.normalize(config)

    children =
      case enabled do
        nil -> []
        enabled -> [logging_enabled_elem(enabled)]
      end

    XML.encode(element("BucketLoggingStatus", [{"xmlns", XML.namespace()}], children))
  end

  defp logging_enabled_elem(enabled) do
    children =
      [
        element("TargetBucket", [], characters(enabled["TargetBucket"])),
        element("TargetPrefix", [], characters(enabled["TargetPrefix"]))
      ]
      |> add_target_grants(enabled["TargetGrants"])
      |> add_target_object_key_format(enabled["TargetObjectKeyFormat"])

    element("LoggingEnabled", [], children)
  end

  defp add_target_grants(children, []), do: children
  defp add_target_grants(children, nil), do: children

  defp add_target_grants(children, grants) when is_list(grants) do
    children ++ [element("TargetGrants", [], Enum.map(grants, &target_grant_elem/1))]
  end

  defp target_grant_elem(%{"Grantee" => grantee, "Permission" => permission}) do
    element("Grant", [], [
      grantee_elem(grantee),
      element("Permission", [], characters(permission))
    ])
  end

  defp grantee_elem(%{"type" => "CanonicalUser"} = grantee) do
    children =
      []
      |> add_text("ID", grantee["ID"])
      |> add_text("DisplayName", grantee["DisplayName"])

    element("Grantee", [{"xmlns:xsi", @xsi}, {"xsi:type", "CanonicalUser"}], children)
  end

  defp grantee_elem(%{"type" => "Group", "URI" => uri}) do
    element("Grantee", [{"xmlns:xsi", @xsi}, {"xsi:type", "Group"}], [
      element("URI", [], characters(uri))
    ])
  end

  defp add_target_object_key_format(children, %{"type" => "partitioned"} = format) do
    children ++
      [
        element("TargetObjectKeyFormat", [], [
          element("PartitionedPrefix", [], [
            element("PartitionDateSource", [], characters(format["partition_date_source"]))
          ])
        ])
      ]
  end

  defp add_target_object_key_format(children, _format), do: children

  defp add_text(children, _tag, nil), do: children
  defp add_text(children, _tag, ""), do: children
  defp add_text(children, tag, value), do: children ++ [element(tag, [], characters(value))]
end
