defmodule Maxio.S3.RequestParsers.Delete do
  @moduledoc """
  DeleteObjects 请求体 SAX 解析（saxy）。返回 %{quiet, objects: [%{key, version_id}]}。
  畸形/无 Object → :malformed_xml。小 XML 整读后传入（铁律 4）。
  """
  @behaviour Saxy.Handler

  @spec parse(binary()) ::
          {:ok, %{quiet: boolean(), objects: [%{key: String.t(), version_id: String.t() | nil}]}}
          | {:error, :malformed_xml}
  def parse(xml) when is_binary(xml) do
    init = %{quiet: false, objects: [], current: nil, in: nil, text: nil}

    case Saxy.parse_string(xml, __MODULE__, init) do
      {:ok, %{objects: []}} -> {:error, :malformed_xml}
      {:ok, %{quiet: q, objects: objs}} -> {:ok, %{quiet: q, objects: Enum.reverse(objs)}}
      {:error, _} -> {:error, :malformed_xml}
    end
  end

  @impl true
  def handle_event(:start_document, _prolog, state), do: {:ok, state}

  @impl true
  def handle_event(:start_element, {name, _attrs}, state) do
    case local_name(name) do
      "Object" -> {:ok, %{state | current: %{key: nil, version_id: nil}, in: nil}}
      "Key" -> {:ok, %{state | in: :key, text: ""}}
      "VersionId" -> {:ok, %{state | in: :version_id, text: ""}}
      "Quiet" -> {:ok, %{state | in: :quiet, text: ""}}
      _ -> {:ok, %{state | in: nil}}
    end
  end

  @impl true
  def handle_event(:characters, _chars, %{in: nil} = state), do: {:ok, state}

  def handle_event(:characters, chars, %{text: text} = state) when is_binary(text),
    do: {:ok, %{state | text: text <> chars}}

  def handle_event(:characters, _chars, state), do: {:ok, state}

  @impl true
  def handle_event(:end_element, name, state) do
    case local_name(name) do
      "Key" ->
        {:ok,
         %{
           state
           | current: Map.put(state.current || %{}, :key, String.trim(state.text || "")),
             in: nil,
             text: nil
         }}

      "VersionId" ->
        {:ok,
         %{
           state
           | current: Map.put(state.current || %{}, :version_id, nilify(state.text)),
             in: nil,
             text: nil
         }}

      "Quiet" ->
        {:ok, %{state | quiet: String.trim(state.text || "") == "true", in: nil, text: nil}}

      "Object" ->
        case state.current do
          %{key: key} when is_binary(key) and key != "" ->
            obj = %{key: key, version_id: Map.get(state.current, :version_id)}
            {:ok, %{state | objects: [obj | state.objects], current: nil}}

          _ ->
            {:ok, %{state | current: nil}}
        end

      _ ->
        {:ok, %{state | in: nil, text: nil}}
    end
  end

  @impl true
  def handle_event(:end_document, _data, state), do: {:ok, state}

  defp local_name(name) do
    case String.split(name, ":") do
      [_ns, local] -> local
      [local] -> local
    end
  end

  defp nilify(nil), do: nil
  defp nilify(""), do: nil

  defp nilify(s) do
    case String.trim(s) do
      "" -> nil
      v -> v
    end
  end
end
