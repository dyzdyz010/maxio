defmodule Maxio.S3.RequestParsers.CompleteMultipartUpload do
  @moduledoc """
  CompleteMultipartUpload 请求体 SAX 解析（saxy）。按元素名取值（PartNumber/ETag 顺序不敏感），
  返回 [%{part_number, etag}]（保留请求出现顺序，升序校验交上下文）。畸形/无 Part → :malformed_xml。
  小 XML 走带上限整读后传入（铁律 4：只有小 XML 整读，对象字节绝不整读）。
  """
  @behaviour Saxy.Handler

  @spec parse(binary()) ::
          {:ok, [%{part_number: pos_integer(), etag: String.t()}]} | {:error, :malformed_xml}
  def parse(xml) when is_binary(xml) do
    case Saxy.parse_string(xml, __MODULE__, %{parts: [], current: nil, text: nil, in: nil}) do
      {:ok, %{parts: []}} -> {:error, :malformed_xml}
      {:ok, %{parts: parts}} -> {:ok, Enum.reverse(parts)}
      {:error, _} -> {:error, :malformed_xml}
    end
  end

  @impl true
  def handle_event(:start_document, _prolog, state), do: {:ok, state}

  @impl true
  def handle_event(:start_element, {name, _attrs}, state) do
    case local_name(name) do
      "Part" -> {:ok, %{state | current: %{part_number: nil, etag: nil}, in: nil}}
      "PartNumber" -> {:ok, %{state | in: :part_number, text: ""}}
      "ETag" -> {:ok, %{state | in: :etag, text: ""}}
      _ -> {:ok, %{state | in: nil}}
    end
  end

  @impl true
  def handle_event(:characters, _chars, %{in: nil} = state), do: {:ok, state}

  def handle_event(:characters, chars, %{text: text} = state) when is_binary(text) do
    {:ok, %{state | text: text <> chars}}
  end

  def handle_event(:characters, _chars, state), do: {:ok, state}

  @impl true
  def handle_event(:end_element, name, state) do
    case local_name(name) do
      "PartNumber" ->
        pn = parse_int(state.text)

        {:ok,
         %{state | current: Map.put(state.current || %{}, :part_number, pn), in: nil, text: nil}}

      "ETag" ->
        {:ok,
         %{
           state
           | current: Map.put(state.current || %{}, :etag, String.trim(state.text || "")),
             in: nil,
             text: nil
         }}

      "Part" ->
        case state.current do
          %{part_number: pn, etag: etag} when is_integer(pn) and is_binary(etag) ->
            {:ok, %{state | parts: [%{part_number: pn, etag: etag} | state.parts], current: nil}}

          _ ->
            # Part 缺字段：丢弃该 Part；最终若无有效 Part 则 parse/1 报 malformed。
            {:ok, %{state | current: nil}}
        end

      _ ->
        {:ok, %{state | in: nil, text: nil}}
    end
  end

  @impl true
  def handle_event(:end_document, _data, state), do: {:ok, state}

  # saxy 可能给 "ns:Local" 形式的名；取本地名。
  defp local_name(name) do
    case String.split(name, ":") do
      [_ns, local] -> local
      [local] -> local
    end
  end

  defp parse_int(nil), do: nil

  defp parse_int(str) do
    case Integer.parse(String.trim(str)) do
      {n, _} -> n
      _ -> nil
    end
  end
end
