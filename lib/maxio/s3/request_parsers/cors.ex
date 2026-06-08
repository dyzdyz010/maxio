defmodule Maxio.S3.RequestParsers.Cors do
  @moduledoc """
  PutBucketCors 的 XML body 解析（saxy SAX）：CORSConfiguration>CORSRule×N。
  每 rule → %{id, allowed_methods:[..], allowed_origins:[..], allowed_headers:[..],
  expose_headers:[..], max_age_seconds: int|nil}。容忍命名空间/xmlns。
  返回 {:ok, [rule_map]} | {:error, :malformed_xml}。语义校验（方法白名单/单*）由 handler 另做。
  """
  @behaviour Saxy.Handler

  @spec parse(binary()) :: {:ok, [map()]} | {:error, :malformed_xml}
  def parse(xml) when is_binary(xml) do
    init = %{rules: [], cur: nil, in: nil, text: nil}

    case Saxy.parse_string(xml, __MODULE__, init) do
      {:ok, %{rules: rules}} -> {:ok, Enum.reverse(rules)}
      {:error, _} -> {:error, :malformed_xml}
    end
  end

  @impl true
  def handle_event(:start_document, _p, s), do: {:ok, s}

  @impl true
  def handle_event(:start_element, {name, _attrs}, s) do
    case local(name) do
      "CORSRule" ->
        {:ok, %{s | cur: new_rule(), in: nil}}

      tag when tag in ~w(ID AllowedMethod AllowedOrigin AllowedHeader ExposeHeader MaxAgeSeconds) ->
        {:ok, %{s | in: tag, text: ""}}

      _ ->
        {:ok, %{s | in: nil}}
    end
  end

  @impl true
  def handle_event(:characters, c, %{text: t} = s) when is_binary(t), do: {:ok, %{s | text: t <> c}}
  def handle_event(:characters, _c, s), do: {:ok, s}

  @impl true
  def handle_event(:end_element, name, %{cur: cur} = s) do
    case {local(name), cur} do
      {"CORSRule", cur} when is_map(cur) ->
        {:ok, %{s | rules: [finalize(cur) | s.rules], cur: nil, in: nil}}

      {"ID", cur} when is_map(cur) ->
        {:ok, %{s | cur: %{cur | id: trim(s.text)}, in: nil, text: nil}}

      {"AllowedMethod", cur} when is_map(cur) ->
        {:ok, %{s | cur: %{cur | allowed_methods: [trim(s.text) | cur.allowed_methods]}, in: nil, text: nil}}

      {"AllowedOrigin", cur} when is_map(cur) ->
        {:ok, %{s | cur: %{cur | allowed_origins: [trim(s.text) | cur.allowed_origins]}, in: nil, text: nil}}

      {"AllowedHeader", cur} when is_map(cur) ->
        {:ok, %{s | cur: %{cur | allowed_headers: [trim(s.text) | cur.allowed_headers]}, in: nil, text: nil}}

      {"ExposeHeader", cur} when is_map(cur) ->
        {:ok, %{s | cur: %{cur | expose_headers: [trim(s.text) | cur.expose_headers]}, in: nil, text: nil}}

      {"MaxAgeSeconds", cur} when is_map(cur) ->
        {:ok, %{s | cur: %{cur | max_age_seconds: parse_int(trim(s.text))}, in: nil, text: nil}}

      _ ->
        {:ok, %{s | in: nil, text: nil}}
    end
  end

  @impl true
  def handle_event(:end_document, _d, s), do: {:ok, s}

  defp new_rule, do: %{id: nil, allowed_methods: [], allowed_origins: [], allowed_headers: [], expose_headers: [], max_age_seconds: nil}

  # 反转累积列表（SAX 头插），输出 string-key map（jsonb 存储）。
  defp finalize(r) do
    %{
      "id" => r.id,
      "allowed_methods" => Enum.reverse(r.allowed_methods),
      "allowed_origins" => Enum.reverse(r.allowed_origins),
      "allowed_headers" => Enum.reverse(r.allowed_headers),
      "expose_headers" => Enum.reverse(r.expose_headers),
      "max_age_seconds" => r.max_age_seconds
    }
  end

  defp trim(nil), do: ""
  defp trim(t), do: String.trim(t)

  defp parse_int(s) do
    case Integer.parse(s) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp local(name) do
    case String.split(name, ":") do
      [_ns, l] -> l
      [l] -> l
    end
  end
end
