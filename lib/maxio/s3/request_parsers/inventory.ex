defmodule Maxio.S3.RequestParsers.Inventory do
  @moduledoc "PutBucketInventoryConfiguration InventoryConfiguration XML parser."
  @behaviour Saxy.Handler

  alias Maxio.S3.Inventory

  @unset {:__maxio_inventory_unset__, []}

  @spec parse(binary()) :: {:ok, map()} | {:error, :malformed_xml}
  def parse(xml) when is_binary(xml) do
    case Saxy.parse_string(xml, __MODULE__, %{stack: [], root: nil, invalid?: false}) do
      {:ok, %{root: {"InventoryConfiguration", _attrs, children}, invalid?: false}} ->
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
      {:ok,
       %{
         "Id" => @unset,
         "Destination" => @unset,
         "IsEnabled" => @unset,
         "Filter" => @unset,
         "IncludedObjectVersions" => @unset,
         "OptionalFields" => @unset,
         "Schedule" => @unset
       }},
      fn
        {"Id", _attrs, children}, {:ok, config} ->
          put_once(config, "Id", required_text(children))

        {"Destination", _attrs, children}, {:ok, config} ->
          with {:ok, destination} <- parse_destination(children),
               {:cont, {:ok, config}} <- put_once(config, "Destination", {:ok, destination}) do
            {:cont, {:ok, config}}
          else
            _other -> {:halt, :error}
          end

        {"IsEnabled", _attrs, children}, {:ok, config} ->
          put_once(config, "IsEnabled", required_text(children))

        {"Filter", _attrs, children}, {:ok, config} ->
          with {:ok, filter} <- parse_filter(children),
               {:cont, {:ok, config}} <- put_once(config, "Filter", {:ok, filter}) do
            {:cont, {:ok, config}}
          else
            _other -> {:halt, :error}
          end

        {"IncludedObjectVersions", _attrs, children}, {:ok, config} ->
          put_once(config, "IncludedObjectVersions", required_text(children))

        {"OptionalFields", _attrs, children}, {:ok, config} ->
          with {:ok, fields} <- parse_optional_fields(children),
               {:cont, {:ok, config}} <- put_once(config, "OptionalFields", {:ok, fields}) do
            {:cont, {:ok, config}}
          else
            _other -> {:halt, :error}
          end

        {"Schedule", _attrs, children}, {:ok, config} ->
          with {:ok, schedule} <- parse_schedule(children),
               {:cont, {:ok, config}} <- put_once(config, "Schedule", {:ok, schedule}) do
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

        case Inventory.validate_client_config(config, config["Id"] || "") do
          {:ok, config} -> {:ok, config}
          {:error, :malformed_xml} -> {:error, :malformed_xml}
        end

      :error ->
        {:error, :malformed_xml}
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
         "AccountId" => @unset,
         "Bucket" => @unset,
         "Format" => @unset,
         "Prefix" => @unset,
         "Encryption" => @unset
       }},
      fn
        {"AccountId", _attrs, children}, {:ok, destination} ->
          put_once(destination, "AccountId", required_text(children))

        {"Bucket", _attrs, children}, {:ok, destination} ->
          put_once(destination, "Bucket", required_text(children))

        {"Format", _attrs, children}, {:ok, destination} ->
          put_once(destination, "Format", required_text(children))

        {"Prefix", _attrs, children}, {:ok, destination} ->
          put_once(destination, "Prefix", text(children))

        {"Encryption", _attrs, children}, {:ok, destination} ->
          with {:ok, encryption} <- parse_encryption(children),
               {:cont, {:ok, destination}} <-
                 put_once(destination, "Encryption", {:ok, encryption}) do
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
    case structural_children(children) do
      [{tag, _attrs, children}] when tag in ["SSE-S3", "SSES3"] ->
        if structural_children(children) == [], do: {:ok, %{"SSE-S3" => %{}}}, else: :error

      [{tag, _attrs, children}] when tag in ["SSE-KMS", "SSEKMS"] ->
        with {:ok, kms} <- parse_sse_kms(children) do
          {:ok, %{"SSE-KMS" => kms}}
        end

      _other ->
        :error
    end
  end

  defp parse_sse_kms(children) do
    children
    |> structural_children()
    |> Enum.reduce_while({:ok, %{"KeyId" => @unset}}, fn
      {"KeyId", _attrs, children}, {:ok, kms} ->
        put_once(kms, "KeyId", required_text(children))

      _other, _acc ->
        {:halt, :error}
    end)
    |> normalize_result()
  end

  defp parse_filter(children) do
    case structural_children(children) do
      [{"Prefix", _attrs, children}] ->
        with {:ok, prefix} <- text(children) do
          {:ok, %{"Prefix" => prefix}}
        end

      _other ->
        :error
    end
  end

  defp parse_optional_fields(children) do
    children
    |> structural_children()
    |> Enum.reduce_while({:ok, []}, fn
      {"Field", _attrs, children}, {:ok, fields} ->
        case required_text(children) do
          {:ok, field} -> {:cont, {:ok, fields ++ [field]}}
          :error -> {:halt, :error}
        end

      _other, _acc ->
        {:halt, :error}
    end)
    |> case do
      {:ok, []} -> :error
      {:ok, fields} -> {:ok, fields}
      :error -> :error
    end
  end

  defp parse_schedule(children) do
    children
    |> structural_children()
    |> Enum.reduce_while({:ok, %{"Frequency" => @unset}}, fn
      {"Frequency", _attrs, children}, {:ok, schedule} ->
        put_once(schedule, "Frequency", required_text(children))

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
