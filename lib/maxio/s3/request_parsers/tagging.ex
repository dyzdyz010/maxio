defmodule Maxio.S3.RequestParsers.Tagging do
  @moduledoc """
  Put{Object,Bucket}Tagging 的 XML body 解析（saxy SAX）：Tagging>TagSet>Tag>(Key,Value)。
  容忍命名空间前缀与 xmlns（accept with/without）。空 TagSet → []（删除语义）。
  返回 {:ok, [{Key, Value}]} | {:error, :malformed_xml}。校验（数量/字符/aws:）由 Maxio.Tags.validate 另做。
  """
  @behaviour Saxy.Handler

  @spec parse(binary()) :: {:ok, [{String.t(), String.t()}]} | {:error, :malformed_xml}
  def parse(xml) when is_binary(xml) do
    init = %{tags: [], cur_key: nil, cur_val: nil, in: nil, text: nil}

    case Saxy.parse_string(xml, __MODULE__, init) do
      {:ok, %{tags: tags}} -> {:ok, Enum.reverse(tags)}
      {:error, _} -> {:error, :malformed_xml}
    end
  end

  @impl true
  def handle_event(:start_document, _p, s), do: {:ok, s}

  @impl true
  def handle_event(:start_element, {name, _attrs}, s) do
    case local(name) do
      "Tag" -> {:ok, %{s | cur_key: nil, cur_val: nil, in: nil}}
      "Key" -> {:ok, %{s | in: :key, text: ""}}
      "Value" -> {:ok, %{s | in: :val, text: ""}}
      _ -> {:ok, %{s | in: nil}}
    end
  end

  @impl true
  def handle_event(:characters, c, %{text: t} = s) when is_binary(t), do: {:ok, %{s | text: t <> c}}
  def handle_event(:characters, _c, s), do: {:ok, s}

  @impl true
  def handle_event(:end_element, name, s) do
    case local(name) do
      "Key" -> {:ok, %{s | cur_key: s.text || "", in: nil, text: nil}}
      "Value" -> {:ok, %{s | cur_val: s.text || "", in: nil, text: nil}}
      "Tag" -> {:ok, %{s | tags: [{s.cur_key, s.cur_val} | s.tags], in: nil}}
      _ -> {:ok, %{s | in: nil, text: nil}}
    end
  end

  @impl true
  def handle_event(:end_document, _d, s), do: {:ok, s}

  defp local(name) do
    case String.split(name, ":") do
      [_ns, l] -> l
      [l] -> l
    end
  end
end
