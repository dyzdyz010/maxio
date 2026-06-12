defmodule Maxio.S3.Views.Lifecycle do
  @moduledoc """
  GetBucketLifecycleConfiguration 响应 XML（LifecycleConfiguration>Rule×N，带 xmlns）。
  从解析后的扁平 rule map 重建标准 XML（Filter + Expiration + NoncurrentVersionExpiration +
  AbortIncompleteMultipartUpload + Transition）。round-trip 忠实度满足 SDK 解析。
  """
  import Saxy.XML
  alias Maxio.S3.XML

  @spec render([map()]) :: iodata()
  def render(rules) when is_list(rules) do
    root =
      element(
        "LifecycleConfiguration",
        [{"xmlns", XML.namespace()}],
        Enum.map(rules, &rule_elem/1)
      )

    XML.encode(root)
  end

  defp rule_elem(r) do
    children =
      []
      |> add(r["id"], fn v -> element("ID", [], characters(v)) end)
      |> add(filter_elem(r), & &1)
      |> add(r["status"], fn v -> element("Status", [], characters(v)) end)
      |> add(expiration_elem(r), & &1)
      |> add(noncurrent_expiration_elem(r), & &1)
      |> add(abort_elem(r), & &1)
      |> add(transition_elem(r), & &1)
      |> add(noncurrent_transition_elem(r), & &1)

    element("Rule", [], children)
  end

  defp filter_elem(r) do
    inner =
      []
      |> add(r["filter_prefix"], fn v -> element("Prefix", [], characters(v)) end)
      |> add_tags(r["filter_tags"] || [])
      |> add_int(r["filter_size_gt"], fn v ->
        element("ObjectSizeGreaterThan", [], characters(Integer.to_string(v)))
      end)
      |> add_int(r["filter_size_lt"], fn v ->
        element("ObjectSizeLessThan", [], characters(Integer.to_string(v)))
      end)

    legacy_prefix = r["prefix"]

    cond do
      # 多条件 → 包进 <And>
      length(inner) > 1 -> element("Filter", [], [element("And", [], inner)])
      inner != [] -> element("Filter", [], inner)
      legacy_prefix -> element("Prefix", [], characters(legacy_prefix))
      true -> element("Filter", [], [])
    end
  end

  defp expiration_elem(r) do
    inner =
      []
      |> add_int(r["expiration_days"], fn v ->
        element("Days", [], characters(Integer.to_string(v)))
      end)
      |> add(r["expiration_date"], fn v -> element("Date", [], characters(v)) end)
      |> add(r["expired_object_delete_marker"], fn v ->
        element("ExpiredObjectDeleteMarker", [], characters(to_string(v)))
      end)

    if inner == [], do: nil, else: element("Expiration", [], inner)
  end

  defp noncurrent_expiration_elem(r) do
    inner =
      []
      |> add_int(r["noncurrent_days"], fn v ->
        element("NoncurrentDays", [], characters(Integer.to_string(v)))
      end)
      |> add_int(r["newer_noncurrent_versions"], fn v ->
        element("NewerNoncurrentVersions", [], characters(Integer.to_string(v)))
      end)

    if inner == [], do: nil, else: element("NoncurrentVersionExpiration", [], inner)
  end

  defp abort_elem(r) do
    case r["abort_days_after_initiation"] do
      nil ->
        nil

      n when is_integer(n) ->
        element("AbortIncompleteMultipartUpload", [], [
          element("DaysAfterInitiation", [], characters(Integer.to_string(n)))
        ])

      _other ->
        nil
    end
  end

  defp transition_elem(r) do
    inner =
      []
      |> add_int(r["transition_days"], fn v ->
        element("Days", [], characters(Integer.to_string(v)))
      end)
      |> add(r["transition_date"], fn v -> element("Date", [], characters(v)) end)
      |> add(r["transition_storage_class"], fn v -> element("StorageClass", [], characters(v)) end)

    if inner == [], do: nil, else: element("Transition", [], inner)
  end

  defp noncurrent_transition_elem(r) do
    inner =
      []
      |> add_int(r["noncurrent_transition_days"], fn v ->
        element("NoncurrentDays", [], characters(Integer.to_string(v)))
      end)
      |> add_int(r["noncurrent_transition_newer_noncurrent_versions"], fn v ->
        element("NewerNoncurrentVersions", [], characters(Integer.to_string(v)))
      end)
      |> add(r["noncurrent_transition_storage_class"], fn v ->
        element("StorageClass", [], characters(v))
      end)

    if inner == [], do: nil, else: element("NoncurrentVersionTransition", [], inner)
  end

  defp add(children, nil, _fun), do: children
  defp add(children, "", _fun), do: children
  defp add(children, value, fun), do: children ++ [fun.(value)]

  defp add_int(children, value, fun) when is_integer(value), do: children ++ [fun.(value)]
  defp add_int(children, _value, _fun), do: children

  defp add_tags(children, tags) when is_list(tags) do
    children ++ Enum.flat_map(tags, &tag_elem/1)
  end

  defp add_tags(children, _tags), do: children

  defp tag_elem(%{"key" => key, "value" => value}) do
    [
      element("Tag", [], [
        element("Key", [], characters(key || "")),
        element("Value", [], characters(value || ""))
      ])
    ]
  end

  defp tag_elem(%{"Key" => key, "Value" => value}),
    do: tag_elem(%{"key" => key, "value" => value})

  defp tag_elem(_other), do: []
end
