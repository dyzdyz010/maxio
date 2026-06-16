defmodule Maxio.S3.RequestParsers.Logging do
  @moduledoc "PutBucketLogging BucketLoggingStatus XML parser."
  @behaviour Saxy.Handler

  alias Maxio.S3.Logging

  @leaf_tags ~w(TargetBucket TargetPrefix ID DisplayName URI Permission PartitionDateSource)

  @spec parse(binary()) :: {:ok, map()} | {:error, :malformed_xml}
  def parse(xml) when is_binary(xml) do
    init = %{
      root?: false,
      logging_enabled?: false,
      config: Logging.empty(),
      enabled: nil,
      current_grant: nil,
      current_grantee: nil,
      seen: MapSet.new(),
      path: [],
      in: nil,
      text: nil,
      invalid?: false
    }

    case Saxy.parse_string(xml, __MODULE__, init) do
      {:ok, %{root?: true, invalid?: false, config: config}} -> {:ok, config}
      _other -> {:error, :malformed_xml}
    end
  end

  @impl true
  def handle_event(:start_document, _prolog, state), do: {:ok, state}

  @impl true
  def handle_event(:start_element, {name, attrs}, state) do
    tag = local(name)
    parent_path = state.path
    state = %{state | path: [tag | parent_path], in: nil, text: nil}

    cond do
      parent_path == [] and tag == "BucketLoggingStatus" ->
        {:ok, %{state | root?: true}}

      parent_path == [] ->
        {:ok, invalid(state)}

      tag == "BucketLoggingStatus" ->
        {:ok, invalid(state)}

      tag == "LoggingEnabled" and parent_path == ["BucketLoggingStatus"] ->
        if state.logging_enabled? do
          {:ok, invalid(state)}
        else
          {:ok, %{state | logging_enabled?: true, enabled: new_enabled()}}
        end

      tag == "TargetGrants" and parent_path == ["LoggingEnabled", "BucketLoggingStatus"] ->
        put_seen(state, :target_grants)

      tag == "Grant" and parent_path == ["TargetGrants", "LoggingEnabled", "BucketLoggingStatus"] ->
        {:ok, %{state | current_grant: new_grant()}}

      tag == "Grantee" and
          parent_path == ["Grant", "TargetGrants", "LoggingEnabled", "BucketLoggingStatus"] ->
        {:ok, %{state | current_grantee: %{"type" => grantee_type(attrs)}}}

      tag == "TargetObjectKeyFormat" and parent_path == ["LoggingEnabled", "BucketLoggingStatus"] ->
        put_seen(state, :target_object_key_format)

      tag in ["SimplePrefix", "PartitionedPrefix"] and
          parent_path == ["TargetObjectKeyFormat", "LoggingEnabled", "BucketLoggingStatus"] ->
        state
        |> put_seen(:target_object_key_format_variant)
        |> then(fn
          {:ok, state} -> put_key_format_type(state, tag)
          other -> other
        end)

      tag in @leaf_tags ->
        if valid_leaf_parent?(tag, parent_path) and not seen_leaf?(state, tag, parent_path) do
          {:ok, %{state | in: tag, text: ""}}
        else
          {:ok, invalid(state)}
        end

      true ->
        {:ok, invalid(state)}
    end
  end

  @impl true
  def handle_event(:characters, chars, %{text: text} = state) when is_binary(text),
    do: {:ok, %{state | text: text <> chars}}

  def handle_event(:characters, chars, state) do
    if String.trim(chars) == "" do
      {:ok, state}
    else
      {:ok, invalid(state)}
    end
  end

  @impl true
  def handle_event(:end_element, name, state) do
    tag = local(name)

    cond do
      tag in @leaf_tags ->
        {:ok,
         state
         |> store_leaf(tag, String.trim(state.text || ""))
         |> mark_seen_leaf(tag)
         |> clear_text()
         |> pop_path()}

      tag == "Grantee" ->
        {:ok,
         state
         |> finish_grantee()
         |> clear_text()
         |> pop_path()}

      tag == "Grant" ->
        {:ok,
         state
         |> finish_grant()
         |> clear_text()
         |> pop_path()}

      tag == "LoggingEnabled" ->
        {:ok,
         state
         |> finish_enabled()
         |> clear_text()
         |> pop_path()}

      true ->
        {:ok, state |> clear_text() |> pop_path()}
    end
  end

  @impl true
  def handle_event(:end_document, _data, state), do: {:ok, state}

  defp new_enabled do
    %{
      "TargetBucket" => nil,
      "TargetPrefix" => nil,
      "TargetGrants" => [],
      "TargetObjectKeyFormat" => %{"type" => "simple"}
    }
  end

  defp new_grant, do: %{"Grantee" => nil, "Permission" => nil}

  defp put_key_format_type(%{enabled: enabled} = state, "SimplePrefix") when is_map(enabled) do
    {:ok, put_enabled(state, "TargetObjectKeyFormat", %{"type" => "simple"})}
  end

  defp put_key_format_type(%{enabled: enabled} = state, "PartitionedPrefix")
       when is_map(enabled) do
    {:ok,
     put_enabled(state, "TargetObjectKeyFormat", %{
       "type" => "partitioned",
       "partition_date_source" => nil
     })}
  end

  defp put_key_format_type(state, _tag), do: {:ok, invalid(state)}

  defp store_leaf(
         %{path: ["TargetBucket", "LoggingEnabled", "BucketLoggingStatus"]} = state,
         "TargetBucket",
         value
       ),
       do: put_enabled(state, "TargetBucket", value)

  defp store_leaf(
         %{path: ["TargetPrefix", "LoggingEnabled", "BucketLoggingStatus"]} = state,
         "TargetPrefix",
         value
       ),
       do: put_enabled(state, "TargetPrefix", value)

  defp store_leaf(
         %{
           path: ["Permission", "Grant", "TargetGrants", "LoggingEnabled", "BucketLoggingStatus"],
           current_grant: grant
         } = state,
         "Permission",
         value
       )
       when is_map(grant) do
    %{state | current_grant: Map.put(grant, "Permission", value)}
  end

  defp store_leaf(
         %{
           path: [
             tag,
             "Grantee",
             "Grant",
             "TargetGrants",
             "LoggingEnabled",
             "BucketLoggingStatus"
           ],
           current_grantee: grantee
         } = state,
         tag,
         value
       )
       when is_map(grantee) and tag in ["ID", "DisplayName", "URI"] do
    %{state | current_grantee: Map.put(grantee, tag, value)}
  end

  defp store_leaf(
         %{
           path: [
             "PartitionDateSource",
             "PartitionedPrefix",
             "TargetObjectKeyFormat",
             "LoggingEnabled",
             "BucketLoggingStatus"
           ],
           enabled: enabled
         } = state,
         "PartitionDateSource",
         value
       )
       when is_map(enabled) do
    format =
      enabled
      |> Map.get("TargetObjectKeyFormat", %{"type" => "partitioned"})
      |> Map.put("type", "partitioned")
      |> Map.put("partition_date_source", value)

    put_enabled(state, "TargetObjectKeyFormat", format)
  end

  defp store_leaf(state, _tag, _value), do: state

  defp finish_grantee(%{current_grant: grant, current_grantee: grantee} = state)
       when is_map(grant) and is_map(grantee) do
    %{state | current_grant: Map.put(grant, "Grantee", grantee), current_grantee: nil}
  end

  defp finish_grantee(state), do: invalid(state)

  defp finish_grant(%{enabled: enabled, current_grant: grant} = state)
       when is_map(enabled) and is_map(grant) do
    grants = Map.get(enabled, "TargetGrants", [])

    %{state | enabled: Map.put(enabled, "TargetGrants", grants ++ [grant]), current_grant: nil}
  end

  defp finish_grant(state), do: invalid(state)

  defp finish_enabled(%{enabled: enabled} = state) when is_map(enabled) do
    config = %{"LoggingEnabled" => enabled}
    %{state | config: config, enabled: nil}
  end

  defp finish_enabled(state), do: invalid(state)

  defp put_enabled(%{enabled: enabled} = state, key, value) when is_map(enabled),
    do: %{state | enabled: Map.put(enabled, key, value)}

  defp put_enabled(state, _key, _value), do: invalid(state)

  defp put_seen(%{seen: seen} = state, key) do
    if MapSet.member?(seen, key) do
      {:ok, invalid(state)}
    else
      {:ok, %{state | seen: MapSet.put(seen, key)}}
    end
  end

  defp seen_leaf?(%{seen: seen}, "TargetBucket", ["LoggingEnabled", "BucketLoggingStatus"]),
    do: MapSet.member?(seen, :target_bucket)

  defp seen_leaf?(%{seen: seen}, "TargetPrefix", ["LoggingEnabled", "BucketLoggingStatus"]),
    do: MapSet.member?(seen, :target_prefix)

  defp seen_leaf?(_state, _tag, _path), do: false

  defp mark_seen_leaf(
         %{path: ["TargetBucket", "LoggingEnabled", "BucketLoggingStatus"]} = state,
         _tag
       ),
       do: %{state | seen: MapSet.put(state.seen, :target_bucket)}

  defp mark_seen_leaf(
         %{path: ["TargetPrefix", "LoggingEnabled", "BucketLoggingStatus"]} = state,
         _tag
       ),
       do: %{state | seen: MapSet.put(state.seen, :target_prefix)}

  defp mark_seen_leaf(state, _tag), do: state

  defp valid_leaf_parent?("TargetBucket", path),
    do: path == ["LoggingEnabled", "BucketLoggingStatus"]

  defp valid_leaf_parent?("TargetPrefix", path),
    do: path == ["LoggingEnabled", "BucketLoggingStatus"]

  defp valid_leaf_parent?("Permission", path),
    do: path == ["Grant", "TargetGrants", "LoggingEnabled", "BucketLoggingStatus"]

  defp valid_leaf_parent?(tag, [
         "Grantee",
         "Grant",
         "TargetGrants",
         "LoggingEnabled",
         "BucketLoggingStatus"
       ]),
       do: tag in ["ID", "DisplayName", "URI"]

  defp valid_leaf_parent?("PartitionDateSource", [
         "PartitionedPrefix",
         "TargetObjectKeyFormat",
         "LoggingEnabled",
         "BucketLoggingStatus"
       ]),
       do: true

  defp valid_leaf_parent?(_tag, _path), do: false

  defp grantee_type(attrs) do
    attrs
    |> Enum.find_value(fn {name, value} ->
      if local(name) == "type", do: value
    end)
  end

  defp clear_text(state), do: %{state | in: nil, text: nil}

  defp pop_path(%{path: []} = state), do: state
  defp pop_path(%{path: [_tag | rest]} = state), do: %{state | path: rest}

  defp invalid(state), do: %{state | invalid?: true, in: nil, text: nil}

  defp local({_namespace, name}), do: local(name)

  defp local(name) do
    case String.split(to_string(name), ":") do
      [_namespace, local] -> local
      [local] -> local
    end
  end
end
