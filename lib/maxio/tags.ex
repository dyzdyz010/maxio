defmodule Maxio.Tags do
  @moduledoc """
  标签集校验与 x-amz-tagging 头编解码（官方核验 bake-in）。
    * 对象 ≤10、桶 ≤50；Key 1..128、Value 0..256 Unicode 字符；Key 唯一；
    * 允许字符 a-zA-Z0-9 与空格及 + - = . _ : / @；保留前缀 aws: 禁用。
  违反 → {:error, :invalid_tag}（调用方映射 InvalidTag 400，铁律 3）。
  x-amz-tagging 头是 query-string 编码（key1=val1&key2=val2，URL 编码）。
  """
  @obj_max 10
  @bucket_max 50
  @allowed ~r/\A[\p{L}\p{N} +\-=._:\/@]*\z/u

  @doc "校验标签集（[{Key,Value}]）。scope :object|:bucket 决定数量上限。"
  @spec validate([{String.t(), String.t()}], :object | :bucket) :: :ok | {:error, :invalid_tag}
  def validate(tags, scope) when is_list(tags) do
    max = if scope == :bucket, do: @bucket_max, else: @obj_max
    keys = Enum.map(tags, fn {k, _v} -> k end)

    cond do
      length(tags) > max -> {:error, :invalid_tag}
      length(Enum.uniq(keys)) != length(keys) -> {:error, :invalid_tag}
      not Enum.all?(tags, &valid_tag?/1) -> {:error, :invalid_tag}
      true -> :ok
    end
  end

  def validate(_other, _scope), do: {:error, :invalid_tag}

  defp valid_tag?({k, v}) when is_binary(k) and is_binary(v) do
    String.length(k) >= 1 and String.length(k) <= 128 and
      String.length(v) <= 256 and
      not String.starts_with?(k, "aws:") and
      Regex.match?(@allowed, k) and Regex.match?(@allowed, v)
  end

  defp valid_tag?(_), do: false

  @doc "解码 x-amz-tagging 头（query-string 形式）为 [{Key,Value}]。畸形 → {:error, :invalid_tag}。"
  @spec parse_header(String.t()) :: {:ok, [{String.t(), String.t()}]} | {:error, :invalid_tag}
  def parse_header(value) when is_binary(value) do
    try do
      pairs =
        value
        |> String.split("&", trim: true)
        |> Enum.map(fn pair ->
          case String.split(pair, "=", parts: 2) do
            [k, v] -> {URI.decode_www_form(k), URI.decode_www_form(v)}
            [k] -> {URI.decode_www_form(k), ""}
          end
        end)

      {:ok, pairs}
    rescue
      _ -> {:error, :invalid_tag}
    end
  end

  @doc "把 jsonb tag map 转为有序 [{Key,Value}]（按 Key 升序，稳定输出）。"
  @spec map_to_list(map()) :: [{String.t(), String.t()}]
  def map_to_list(map) when is_map(map) do
    map |> Enum.map(fn {k, v} -> {to_string(k), to_string(v)} end) |> Enum.sort_by(&elem(&1, 0))
  end

  @doc "把 [{Key,Value}] 转为 jsonb 存储 map。"
  @spec list_to_map([{String.t(), String.t()}]) :: map()
  def list_to_map(list) when is_list(list), do: Map.new(list)
end
