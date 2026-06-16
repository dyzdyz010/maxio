defmodule Maxio.S3.RequestParsers.Analytics do
  @moduledoc "PutBucketAnalyticsConfiguration AnalyticsConfiguration XML parser."
  @behaviour Saxy.Handler

  alias Maxio.S3.Analytics

  @unset {:__maxio_analytics_unset__, []}

  @spec parse(binary()) :: {:ok, map()} | {:error, :malformed_xml}
  def parse(xml) when is_binary(xml) do
    case Saxy.parse_string(xml, __MODULE__, %{stack: [], root: nil, invalid?: false}) do
      {:ok, %{root: {"AnalyticsConfiguration", _attrs, children}, invalid?: false}} ->
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
    |> Enum.reduce_while(
      {:ok, %{"Id" => @unset, "Filter" => @unset, "StorageClassAnalysis" => @unset}},
      fn
        {"Id", _attrs, children}, {:ok, config} ->
          put_once(config, "Id", required_text(children))

        {"Filter", _attrs, children}, {:ok, config} ->
          with {:ok, filter} <- parse_filter(children),
               {:cont, {:ok, config}} <- put_once(config, "Filter", {:ok, filter}) do
            {:cont, {:ok, config}}
          else
            _other -> {:halt, :error}
          end

        {"StorageClassAnalysis", _attrs, children}, {:ok, config} ->
          with {:ok, analysis} <- parse_storage_class_analysis(children),
               {:cont, {:ok, config}} <-
                 put_once(config, "StorageClassAnalysis", {:ok, analysis}) do
            {:cont, {:ok, config}}
          else
            _other -> {:halt, :error}
          end

        _other, _acc ->
          {:halt, :error}
      end
    )
    |> case do
      {:ok, config} ->
        config = normalize_unset_fields(config)

        case Analytics.validate_client_config(config, config["Id"] || "") do
          {:ok, config} -> {:ok, config}
          {:error, :malformed_xml} -> {:error, :malformed_xml}
        end

      :error ->
        {:error, :malformed_xml}
    end
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
          {:ok, %{"Filter" => %{"And" => normalized}}} =
            Analytics.validate_client_config(
              %{
                "Id" => "probe",
                "StorageClassAnalysis" => %{},
                "Filter" => %{"And" => and_operator}
              },
              "probe"
            )

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
          {:ok, %{"Filter" => %{"Tag" => normalized}}} =
            Analytics.validate_client_config(
              %{"Id" => "probe", "StorageClassAnalysis" => %{}, "Filter" => %{"Tag" => tag}},
              "probe"
            )

          {:ok, normalized}
        rescue
          _err -> :error
        end

      :error ->
        :error
    end
  end

  defp parse_storage_class_analysis(children) do
    children = structural_children(children)

    case children do
      [] ->
        {:ok, %{}}

      [{"DataExport", _attrs, children}] ->
        with {:ok, data_export} <- parse_data_export(children) do
          {:ok, %{"DataExport" => data_export}}
        end

      _other ->
        :error
    end
  end

  defp parse_data_export(children) do
    children
    |> structural_children()
    |> Enum.reduce_while(
      {:ok, %{"OutputSchemaVersion" => @unset, "Destination" => @unset}},
      fn
        {"OutputSchemaVersion", _attrs, children}, {:ok, data_export} ->
          put_once(data_export, "OutputSchemaVersion", required_text(children))

        {"Destination", _attrs, children}, {:ok, data_export} ->
          with {:ok, destination} <- parse_destination(children),
               {:cont, {:ok, data_export}} <-
                 put_once(data_export, "Destination", {:ok, destination}) do
            {:cont, {:ok, data_export}}
          else
            _other -> {:halt, :error}
          end

        _other, _acc ->
          {:halt, :error}
      end
    )
    |> case do
      {:ok, data_export} ->
        {:ok, normalize_unset_fields(data_export)}

      :error ->
        :error
    end
  end

  defp parse_destination(children) do
    case structural_children(children) do
      [{"S3BucketDestination", _attrs, children}] ->
        with {:ok, destination} <- parse_s3_bucket_destination(children) do
          {:ok, %{"S3BucketDestination" => destination}}
        end

      _other ->
        :error
    end
  end

  defp parse_s3_bucket_destination(children) do
    children
    |> structural_children()
    |> Enum.reduce_while(
      {:ok,
       %{
         "Format" => @unset,
         "BucketAccountId" => @unset,
         "Bucket" => @unset,
         "Prefix" => @unset
       }},
      fn
        {"Format", _attrs, children}, {:ok, destination} ->
          put_once(destination, "Format", required_text(children))

        {"BucketAccountId", _attrs, children}, {:ok, destination} ->
          put_once(destination, "BucketAccountId", required_text(children))

        {"Bucket", _attrs, children}, {:ok, destination} ->
          put_once(destination, "Bucket", required_text(children))

        {"Prefix", _attrs, children}, {:ok, destination} ->
          put_once(destination, "Prefix", text(children))

        _other, _acc ->
          {:halt, :error}
      end
    )
    |> case do
      {:ok, destination} ->
        {:ok, normalize_unset_fields(destination)}

      :error ->
        :error
    end
  end

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
