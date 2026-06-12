defmodule Maxio.S3.RequestParsers.Lifecycle do
  @moduledoc """
  PutBucketLifecycleConfiguration 的 XML body 解析（saxy SAX）。把每个 Rule 解析为通用嵌套 map
  （保留结构以便忠实出站 round-trip）：%{id, status, filter, expiration, noncurrent_version_expiration,
  abort_incomplete_multipart_upload, transition, noncurrent_version_transition}（缺省 nil）。
  本解析器只抽取语义校验所需的关键字段（status / expiration days+date / expired_object_delete_marker /
  filter prefix），其余结构性子元素以 raw 文本累积保留供出站。
  为简化 round-trip：解析为「扁平字段 + 原始 prefix」结构，出站 view 据此重建标准 XML。
  返回 {:ok, [rule_map]} | {:error, :malformed_xml}。语义校验由 handler 另做。
  """
  @behaviour Saxy.Handler

  @spec parse(binary()) :: {:ok, [map()]} | {:error, :malformed_xml}
  def parse(xml) when is_binary(xml) do
    init = %{rules: [], cur: nil, path: [], in: nil, text: nil, tag: nil}

    case Saxy.parse_string(xml, __MODULE__, init) do
      {:ok, %{rules: rules}} -> {:ok, Enum.reverse(rules)}
      {:error, _} -> {:error, :malformed_xml}
    end
  end

  @impl true
  def handle_event(:start_document, _p, s), do: {:ok, s}

  @impl true
  def handle_event(:start_element, {name, _attrs}, s) do
    l = local(name)

    cond do
      l == "Rule" ->
        {:ok, %{s | cur: new_rule(), path: ["Rule"], in: nil, tag: nil}}

      l == "Filter" and is_map(s.cur) ->
        {:ok, %{s | cur: %{s.cur | "has_filter" => true}, in: nil, path: [l | s.path]}}

      l == "Tag" and ("Filter" in s.path or "And" in s.path) ->
        {:ok, %{s | path: ["Tag" | s.path], in: nil, tag: %{}}}

      l in leaf_tags() ->
        {:ok, %{s | in: l, text: "", path: [l | s.path]}}

      true ->
        {:ok, %{s | in: nil, path: [l | s.path]}}
    end
  end

  @impl true
  def handle_event(:characters, c, %{text: t} = s) when is_binary(t),
    do: {:ok, %{s | text: t <> c}}

  def handle_event(:characters, _c, s), do: {:ok, s}

  @impl true
  def handle_event(:end_element, name, %{cur: cur} = s) do
    l = local(name)

    cond do
      l == "Rule" and is_map(cur) ->
        {:ok, %{s | rules: [cur | s.rules], cur: nil, path: tl_safe(s.path), in: nil, tag: nil}}

      l == "Tag" and is_map(cur) ->
        {:ok,
         %{
           s
           | cur: append_tag(cur, s.tag),
             in: nil,
             text: nil,
             tag: nil,
             path: tl_safe(s.path)
         }}

      l in leaf_tags() and is_map(cur) ->
        s = put_tag(s, l, trim(s.text))

        {:ok,
         %{
           s
           | cur: store(cur, l, s.path, trim(s.text)),
             in: nil,
             text: nil,
             path: tl_safe(s.path)
         }}

      true ->
        {:ok, %{s | in: nil, text: nil, path: tl_safe(s.path)}}
    end
  end

  @impl true
  def handle_event(:end_document, _d, s), do: {:ok, s}

  defp new_rule do
    %{
      "id" => nil,
      "status" => nil,
      "prefix" => nil,
      "filter_prefix" => nil,
      "filter_tags" => [],
      "filter_size_gt" => nil,
      "filter_size_lt" => nil,
      "has_filter" => false,
      "expiration_days" => nil,
      "expiration_date" => nil,
      "expired_object_delete_marker" => nil,
      "noncurrent_days" => nil,
      "newer_noncurrent_versions" => nil,
      "abort_days_after_initiation" => nil,
      "transition_days" => nil,
      "transition_date" => nil,
      "transition_storage_class" => nil,
      "noncurrent_transition_days" => nil,
      "noncurrent_transition_newer_noncurrent_versions" => nil,
      "noncurrent_transition_storage_class" => nil,
      "parse_errors" => []
    }
  end

  defp leaf_tags do
    ~w(ID Status Prefix Days Date ExpiredObjectDeleteMarker NoncurrentDays NewerNoncurrentVersions
       DaysAfterInitiation StorageClass ObjectSizeGreaterThan ObjectSizeLessThan Key Value)
  end

  # 据 path（标签栈）把叶子值塞进 rule map 的对应键。path 形如 [叶子, 父, ..., "Rule"]。
  defp store(cur, "ID", _path, v), do: %{cur | "id" => v}
  defp store(cur, "Status", _path, v), do: %{cur | "status" => v}

  defp store(cur, "Prefix", path, v) do
    # Filter 内 Prefix → filter_prefix；Rule 直属（legacy） Prefix → prefix；And 内 Prefix → filter_prefix。
    if "Filter" in path or "And" in path,
      do: %{cur | "filter_prefix" => v},
      else: %{cur | "prefix" => v}
  end

  defp store(cur, "Days", path, v) do
    cond do
      "Transition" in path -> put_int(cur, "transition_days", v, 1)
      "Expiration" in path -> put_int(cur, "expiration_days", v, 1)
      true -> cur
    end
  end

  defp store(cur, "Date", path, v) do
    cond do
      "Transition" in path -> %{cur | "transition_date" => v}
      "Expiration" in path -> %{cur | "expiration_date" => v}
      true -> cur
    end
  end

  defp store(cur, "ExpiredObjectDeleteMarker", _p, v),
    do: %{cur | "expired_object_delete_marker" => v == "true"}

  defp store(cur, "NoncurrentDays", path, v) do
    cond do
      "NoncurrentVersionExpiration" in path -> put_int(cur, "noncurrent_days", v, 1)
      "NoncurrentVersionTransition" in path -> put_int(cur, "noncurrent_transition_days", v, 1)
      true -> cur
    end
  end

  defp store(cur, "NewerNoncurrentVersions", path, v) do
    cond do
      "NoncurrentVersionExpiration" in path ->
        put_int(cur, "newer_noncurrent_versions", v, 1)

      "NoncurrentVersionTransition" in path ->
        put_int(cur, "noncurrent_transition_newer_noncurrent_versions", v, 1)

      true ->
        cur
    end
  end

  defp store(cur, "DaysAfterInitiation", _p, v),
    do: put_int(cur, "abort_days_after_initiation", v, 1)

  defp store(cur, "StorageClass", path, v) do
    cond do
      "NoncurrentVersionTransition" in path -> %{cur | "noncurrent_transition_storage_class" => v}
      "Transition" in path -> %{cur | "transition_storage_class" => v}
      true -> cur
    end
  end

  defp store(cur, "ObjectSizeGreaterThan", _p, v),
    do: put_int(cur, "filter_size_gt", v, 0)

  defp store(cur, "ObjectSizeLessThan", _p, v),
    do: put_int(cur, "filter_size_lt", v, 1)

  defp store(cur, _other, _path, _v), do: cur

  defp append_tag(cur, %{"key" => key, "value" => value}) when is_binary(key) do
    Map.update!(cur, "filter_tags", fn tags ->
      tags ++ [%{"key" => key, "value" => value || ""}]
    end)
  end

  defp append_tag(cur, tag) when is_map(tag),
    do: add_parse_error(cur, "invalid_filter_tag")

  defp append_tag(cur, _tag), do: cur

  defp put_tag(%{tag: tag} = s, "Key", v) when is_map(tag), do: %{s | tag: Map.put(tag, "key", v)}

  defp put_tag(%{tag: tag} = s, "Value", v) when is_map(tag),
    do: %{s | tag: Map.put(tag, "value", v)}

  defp put_tag(s, _l, _v), do: s

  defp put_int(cur, field, value, min) do
    case int(value) do
      n when is_integer(n) and n >= min -> %{cur | field => n}
      _ -> add_parse_error(cur, "invalid_integer:#{field}")
    end
  end

  defp int(s) do
    case Integer.parse(s) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp add_parse_error(cur, error),
    do: Map.update!(cur, "parse_errors", &[error | &1])

  defp trim(nil), do: ""
  defp trim(t), do: String.trim(t)

  defp tl_safe([]), do: []
  defp tl_safe([_ | rest]), do: rest

  defp local(name) do
    case String.split(name, ":") do
      [_ns, l] -> l
      [l] -> l
    end
  end
end
