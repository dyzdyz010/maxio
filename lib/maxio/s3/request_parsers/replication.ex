defmodule Maxio.S3.RequestParsers.Replication do
  @moduledoc "PutBucketReplication ReplicationConfiguration XML parser."
  @behaviour Saxy.Handler

  alias Maxio.S3.Replication

  @unset {:__maxio_replication_unset__, []}

  @spec parse(binary()) :: {:ok, map()} | {:error, :malformed_xml}
  def parse(xml) when is_binary(xml) do
    case Saxy.parse_string(xml, __MODULE__, %{stack: [], root: nil, invalid?: false}) do
      {:ok, %{root: {"ReplicationConfiguration", _attrs, children}, invalid?: false}} ->
        build_config(children)

      _other ->
        {:error, :malformed_xml}
    end
  end

  @impl true
  def handle_event(:start_document, _prolog, state), do: {:ok, state}

  @impl true
  def handle_event(:start_element, {name, attrs}, state) do
    tag = local(name)
    attrs = Enum.map(attrs, fn {name, value} -> {local(name), value} end)
    {:ok, %{state | stack: [{tag, attrs, []} | state.stack]}}
  end

  @impl true
  def handle_event(:characters, chars, state) do
    {:ok, append_child(state, {:text, chars})}
  end

  @impl true
  def handle_event(:end_element, name, %{stack: [{tag, attrs, children} | rest]} = state) do
    if local(name) == tag do
      node = {tag, attrs, Enum.reverse(children)}

      case rest do
        [] ->
          {:ok, %{state | root: node, stack: []}}

        [{parent_tag, parent_attrs, parent_children} | parent_rest] ->
          stack = [{parent_tag, parent_attrs, [node | parent_children]} | parent_rest]
          {:ok, %{state | stack: stack}}
      end
    else
      {:ok, %{state | invalid?: true}}
    end
  end

  def handle_event(:end_element, _name, state), do: {:ok, %{state | invalid?: true}}

  @impl true
  def handle_event(:end_document, _data, state), do: {:ok, state}

  defp append_child(%{stack: []} = state, _child), do: %{state | invalid?: true}

  defp append_child(%{stack: [{tag, attrs, children} | rest]} = state, child) do
    %{state | stack: [{tag, attrs, [child | children]} | rest]}
  end

  defp build_config(children) do
    children
    |> structural_children()
    |> Enum.reduce_while({:ok, %{"Role" => @unset, "Rules" => []}}, fn
      {"Role", _attrs, children}, {:ok, config} ->
        put_once(config, "Role", required_text(children))

      {"Rule", _attrs, children}, {:ok, config} ->
        case parse_rule(children) do
          {:ok, rule} -> {:cont, {:ok, Map.update!(config, "Rules", &(&1 ++ [rule]))}}
          :error -> {:halt, :error}
        end

      _other, _acc ->
        {:halt, :error}
    end)
    |> case do
      {:ok, config} ->
        config = normalize_unset_fields(config)

        case Replication.validate_client_config(config) do
          {:ok, config} -> {:ok, config}
          {:error, :malformed_xml} -> {:error, :malformed_xml}
        end

      :error ->
        {:error, :malformed_xml}
    end
  end

  defp parse_rule(children) do
    children
    |> structural_children()
    |> Enum.reduce_while(
      {:ok,
       %{
         "ID" => @unset,
         "Priority" => @unset,
         "Prefix" => @unset,
         "Filter" => @unset,
         "Status" => @unset,
         "Destination" => @unset,
         "DeleteMarkerReplication" => @unset,
         "ExistingObjectReplication" => @unset,
         "SourceSelectionCriteria" => @unset
       }},
      fn
        {tag, _attrs, children}, {:ok, rule} when tag in ["ID", "Id"] ->
          put_once(rule, "ID", required_text(children))

        {"Priority", _attrs, children}, {:ok, rule} ->
          put_once(rule, "Priority", required_text(children))

        {"Prefix", _attrs, children}, {:ok, rule} ->
          put_once(rule, "Prefix", text(children))

        {"Filter", _attrs, children}, {:ok, rule} ->
          with {:ok, filter} <- parse_filter(children),
               {:cont, {:ok, rule}} <- put_once(rule, "Filter", {:ok, filter}) do
            {:cont, {:ok, rule}}
          else
            _other -> {:halt, :error}
          end

        {"Status", _attrs, children}, {:ok, rule} ->
          put_once(rule, "Status", required_text(children))

        {"Destination", _attrs, children}, {:ok, rule} ->
          with {:ok, destination} <- parse_destination(children),
               {:cont, {:ok, rule}} <- put_once(rule, "Destination", {:ok, destination}) do
            {:cont, {:ok, rule}}
          else
            _other -> {:halt, :error}
          end

        {"DeleteMarkerReplication", _attrs, children}, {:ok, rule} ->
          parse_status_block(rule, "DeleteMarkerReplication", children)

        {"ExistingObjectReplication", _attrs, children}, {:ok, rule} ->
          parse_status_block(rule, "ExistingObjectReplication", children)

        {"SourceSelectionCriteria", _attrs, children}, {:ok, rule} ->
          with {:ok, criteria} <- parse_source_selection_criteria(children),
               {:cont, {:ok, rule}} <-
                 put_once(rule, "SourceSelectionCriteria", {:ok, criteria}) do
            {:cont, {:ok, rule}}
          else
            _other -> {:halt, :error}
          end

        _other, _acc ->
          {:halt, :error}
      end
    )
    |> normalize_result()
  end

  defp parse_filter(children), do: do_parse_filter(structural_children(children))

  defp do_parse_filter([{"Prefix", _attrs, children}]) do
    with {:ok, prefix} <- text(children) do
      {:ok, %{"Prefix" => prefix}}
    end
  end

  defp do_parse_filter([{"Tag", _attrs, children}]) do
    with {:ok, tag} <- parse_tag(children) do
      {:ok, %{"Tag" => tag}}
    end
  end

  defp do_parse_filter([{"And", _attrs, children}]) do
    with {:ok, and_operator} <- parse_and(children) do
      {:ok, %{"And" => and_operator}}
    end
  end

  defp do_parse_filter(_children), do: :error

  defp parse_and(children) do
    children
    |> structural_children()
    |> Enum.reduce_while({:ok, %{"Prefix" => @unset, "Tags" => []}}, fn
      {"Prefix", _attrs, children}, {:ok, and_operator} ->
        put_once(and_operator, "Prefix", text(children))

      {"Tag", _attrs, children}, {:ok, and_operator} ->
        case parse_tag(children) do
          {:ok, tag} -> {:cont, {:ok, Map.update!(and_operator, "Tags", &(&1 ++ [tag]))}}
          :error -> {:halt, :error}
        end

      _other, _acc ->
        {:halt, :error}
    end)
    |> case do
      {:ok, and_operator} ->
        and_operator = normalize_unset_fields(and_operator)

        try do
          {:ok, %{"Rules" => [%{"Filter" => %{"And" => normalized}}]}} =
            Replication.validate_client_config(%{
              "Role" => "arn:aws:iam::000000000000:role/probe",
              "Rules" => [
                %{
                  "Status" => "Enabled",
                  "Priority" => "1",
                  "Filter" => %{"And" => and_operator},
                  "DeleteMarkerReplication" => %{"Status" => "Disabled"},
                  "Destination" => %{"Bucket" => "arn:aws:s3:::dest"}
                }
              ]
            })

          {:ok, normalized}
        rescue
          _err -> :error
        end

      :error ->
        :error
    end
  end

  defp parse_tag(children) do
    children
    |> structural_children()
    |> Enum.reduce_while({:ok, %{"Key" => @unset, "Value" => @unset}}, fn
      {"Key", _attrs, children}, {:ok, tag} ->
        put_once(tag, "Key", required_text(children))

      {"Value", _attrs, children}, {:ok, tag} ->
        put_once(tag, "Value", text(children))

      _other, _acc ->
        {:halt, :error}
    end)
    |> case do
      {:ok, tag} ->
        tag = normalize_unset_fields(tag)

        try do
          {:ok, %{"Rules" => [%{"Filter" => %{"Tag" => normalized}}]}} =
            Replication.validate_client_config(%{
              "Role" => "arn:aws:iam::000000000000:role/probe",
              "Rules" => [
                %{
                  "Status" => "Enabled",
                  "Priority" => "1",
                  "Filter" => %{"Tag" => tag},
                  "DeleteMarkerReplication" => %{"Status" => "Disabled"},
                  "Destination" => %{"Bucket" => "arn:aws:s3:::dest"}
                }
              ]
            })

          {:ok, normalized}
        rescue
          _err -> :error
        end

      :error ->
        :error
    end
  end

  defp parse_destination(children) do
    children
    |> structural_children()
    |> Enum.reduce_while(
      {:ok,
       %{
         "Bucket" => @unset,
         "Account" => @unset,
         "StorageClass" => @unset,
         "EncryptionConfiguration" => @unset,
         "Metrics" => @unset,
         "ReplicationTime" => @unset,
         "AccessControlTranslation" => @unset
       }},
      fn
        {"Bucket", _attrs, children}, {:ok, destination} ->
          put_once(destination, "Bucket", required_text(children))

        {"Account", _attrs, children}, {:ok, destination} ->
          put_once(destination, "Account", required_text(children))

        {"StorageClass", _attrs, children}, {:ok, destination} ->
          put_once(destination, "StorageClass", required_text(children))

        {"EncryptionConfiguration", _attrs, children}, {:ok, destination} ->
          with {:ok, encryption} <- parse_encryption(children),
               {:cont, {:ok, destination}} <-
                 put_once(destination, "EncryptionConfiguration", {:ok, encryption}) do
            {:cont, {:ok, destination}}
          else
            _other -> {:halt, :error}
          end

        {"Metrics", _attrs, children}, {:ok, destination} ->
          with {:ok, metrics} <- parse_metrics(children),
               {:cont, {:ok, destination}} <- put_once(destination, "Metrics", {:ok, metrics}) do
            {:cont, {:ok, destination}}
          else
            _other -> {:halt, :error}
          end

        {"ReplicationTime", _attrs, children}, {:ok, destination} ->
          with {:ok, replication_time} <- parse_replication_time(children),
               {:cont, {:ok, destination}} <-
                 put_once(destination, "ReplicationTime", {:ok, replication_time}) do
            {:cont, {:ok, destination}}
          else
            _other -> {:halt, :error}
          end

        {"AccessControlTranslation", _attrs, children}, {:ok, destination} ->
          with {:ok, translation} <- parse_access_control_translation(children),
               {:cont, {:ok, destination}} <-
                 put_once(destination, "AccessControlTranslation", {:ok, translation}) do
            {:cont, {:ok, destination}}
          else
            _other -> {:halt, :error}
          end

        _other, _acc ->
          {:halt, :error}
      end
    )
    |> normalize_result()
  end

  defp parse_encryption(children) do
    children
    |> structural_children()
    |> Enum.reduce_while({:ok, %{"ReplicaKmsKeyID" => @unset}}, fn
      {tag, _attrs, children}, {:ok, encryption}
      when tag in ["ReplicaKmsKeyID", "ReplicaKmsKeyId"] ->
        put_once(encryption, "ReplicaKmsKeyID", required_text(children))

      _other, _acc ->
        {:halt, :error}
    end)
    |> normalize_result()
  end

  defp parse_metrics(children) do
    children
    |> structural_children()
    |> Enum.reduce_while({:ok, %{"Status" => @unset, "EventThreshold" => @unset}}, fn
      {"Status", _attrs, children}, {:ok, metrics} ->
        put_once(metrics, "Status", required_text(children))

      {"EventThreshold", _attrs, children}, {:ok, metrics} ->
        with {:ok, threshold} <- parse_minutes_block(children),
             {:cont, {:ok, metrics}} <- put_once(metrics, "EventThreshold", {:ok, threshold}) do
          {:cont, {:ok, metrics}}
        else
          _other -> {:halt, :error}
        end

      _other, _acc ->
        {:halt, :error}
    end)
    |> normalize_result()
  end

  defp parse_replication_time(children) do
    children
    |> structural_children()
    |> Enum.reduce_while({:ok, %{"Status" => @unset, "Time" => @unset}}, fn
      {"Status", _attrs, children}, {:ok, replication_time} ->
        put_once(replication_time, "Status", required_text(children))

      {"Time", _attrs, children}, {:ok, replication_time} ->
        with {:ok, time} <- parse_minutes_block(children),
             {:cont, {:ok, replication_time}} <- put_once(replication_time, "Time", {:ok, time}) do
          {:cont, {:ok, replication_time}}
        else
          _other -> {:halt, :error}
        end

      _other, _acc ->
        {:halt, :error}
    end)
    |> normalize_result()
  end

  defp parse_minutes_block(children) do
    children
    |> structural_children()
    |> Enum.reduce_while({:ok, %{"Minutes" => @unset}}, fn
      {"Minutes", _attrs, children}, {:ok, time} ->
        put_once(time, "Minutes", required_text(children))

      _other, _acc ->
        {:halt, :error}
    end)
    |> normalize_result()
  end

  defp parse_access_control_translation(children) do
    children
    |> structural_children()
    |> Enum.reduce_while({:ok, %{"Owner" => @unset}}, fn
      {"Owner", _attrs, children}, {:ok, translation} ->
        put_once(translation, "Owner", required_text(children))

      _other, _acc ->
        {:halt, :error}
    end)
    |> normalize_result()
  end

  defp parse_source_selection_criteria(children) do
    children
    |> structural_children()
    |> Enum.reduce_while(
      {:ok, %{"SseKmsEncryptedObjects" => @unset, "ReplicaModifications" => @unset}},
      fn
        {tag, _attrs, children}, {:ok, criteria}
        when tag in ["SseKmsEncryptedObjects", "SSEKmsEncryptedObjects"] ->
          with {:ok, block} <- parse_plain_status_block(children),
               {:cont, {:ok, criteria}} <-
                 put_once(criteria, "SseKmsEncryptedObjects", {:ok, block}) do
            {:cont, {:ok, criteria}}
          else
            _other -> {:halt, :error}
          end

        {"ReplicaModifications", _attrs, children}, {:ok, criteria} ->
          with {:ok, block} <- parse_plain_status_block(children),
               {:cont, {:ok, criteria}} <-
                 put_once(criteria, "ReplicaModifications", {:ok, block}) do
            {:cont, {:ok, criteria}}
          else
            _other -> {:halt, :error}
          end

        _other, _acc ->
          {:halt, :error}
      end
    )
    |> normalize_result()
  end

  defp parse_status_block(rule, key, children) do
    with {:ok, block} <- parse_plain_status_block(children),
         {:cont, {:ok, rule}} <- put_once(rule, key, {:ok, block}) do
      {:cont, {:ok, rule}}
    else
      _other -> {:halt, :error}
    end
  end

  defp parse_plain_status_block(children) do
    children
    |> structural_children()
    |> Enum.reduce_while({:ok, %{"Status" => @unset}}, fn
      {"Status", _attrs, children}, {:ok, block} ->
        put_once(block, "Status", required_text(children))

      _other, _acc ->
        {:halt, :error}
    end)
    |> normalize_result()
  end

  defp normalize_result({:ok, value}), do: {:ok, normalize_unset_fields(value)}
  defp normalize_result(:error), do: :error

  defp normalize_unset_fields(map) do
    Map.new(map, fn
      {key, @unset} -> {key, nil}
      {key, value} -> {key, value}
    end)
  end

  defp put_once(map, key, {:ok, value}) do
    if Map.fetch!(map, key) == @unset do
      {:cont, {:ok, Map.put(map, key, value)}}
    else
      {:halt, :error}
    end
  end

  defp put_once(_map, _key, :error), do: {:halt, :error}

  defp required_text(children) do
    case text(children) do
      {:ok, ""} -> :error
      other -> other
    end
  end

  defp text([]), do: {:ok, ""}

  defp text(children) when is_list(children) do
    if Enum.all?(children, &match?({:text, value} when is_binary(value), &1)) do
      {:ok, children |> Enum.map(fn {:text, value} -> value end) |> Enum.join()}
    else
      :error
    end
  end

  defp structural_children(children) do
    Enum.reject(children, fn
      {:text, value} -> String.trim(value) == ""
      _node -> false
    end)
  end

  defp local({_namespace, name}), do: local(name)

  defp local(name) do
    case String.split(to_string(name), ":") do
      [_namespace, local] -> local
      [local] -> local
    end
  end
end
