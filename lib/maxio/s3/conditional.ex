defmodule Maxio.S3.Conditional do
  @moduledoc """
  S3 条件请求求值（RFC 7232 §6 次序，对齐真实 S3，铁律 5）。
  evaluate(headers, %{etag, last_modified}, method) →
    :proceed | {:respond, 304} | {:error, :precondition_failed}

  次序：
    1. If-Match：false→412；true→忽略 If-Unmodified-Since，继续。
    2. 否则 If-Unmodified-Since：false（已改）→412；true→继续。
    3. If-None-Match：false（匹配）→ GET/HEAD 304，其它 412；true→忽略 If-Modified-Since，继续。
    4. 否则 If-Modified-Since（GET/HEAD）：false（未改）→304；true→继续。
    5. proceed。
  ETag 比较：strip W/ + strip 引号；* 表示存在性。日期 RFC1123，不可解析则忽略该头。
  """

  @type meta :: %{etag: String.t(), last_modified: DateTime.t()}

  @spec evaluate([{String.t(), String.t()}], meta(), String.t()) ::
          :proceed | {:respond, 304} | {:error, :precondition_failed}
  def evaluate(headers, %{etag: etag, last_modified: lm}, method) do
    if_match = get(headers, "if-match")
    if_unmod = get(headers, "if-unmodified-since")
    if_none = get(headers, "if-none-match")
    if_mod = get(headers, "if-modified-since")

    # HTTP-date 是秒粒度；把存储的亚秒 last_modified 截断到秒再比较（M2 note #3，铁律 5）。
    lm = truncate_to_second(lm)

    step1(if_match, if_unmod, if_none, if_mod, etag, lm, method)
  end

  defp truncate_to_second(%DateTime{} = dt), do: %{dt | microsecond: {0, 0}}

  defp step1(if_match, if_unmod, if_none, if_mod, etag, lm, method) do
    cond do
      is_binary(if_match) ->
        if etag_matches?(if_match, etag),
          do: step3(if_none, if_mod, etag, lm, method),
          else: {:error, :precondition_failed}

      true ->
        step2(if_unmod, if_none, if_mod, etag, lm, method)
    end
  end

  defp step2(if_unmod, if_none, if_mod, etag, lm, method) do
    case parse_http_date(if_unmod) do
      {:ok, since} ->
        # 已修改（lm > since）→ 412
        if DateTime.compare(lm, since) == :gt,
          do: {:error, :precondition_failed},
          else: step3(if_none, if_mod, etag, lm, method)

      :none ->
        step3(if_none, if_mod, etag, lm, method)
    end
  end

  defp step3(if_none, if_mod, etag, lm, method) do
    cond do
      is_binary(if_none) ->
        if etag_matches?(if_none, etag) do
          if method in ["GET", "HEAD"], do: {:respond, 304}, else: {:error, :precondition_failed}
        else
          :proceed
        end

      true ->
        step4(if_mod, lm, method)
    end
  end

  defp step4(if_mod, lm, method) do
    if method in ["GET", "HEAD"] do
      case parse_http_date(if_mod) do
        {:ok, since} ->
          # 未修改（lm <= since）→ 304
          if DateTime.compare(lm, since) == :gt, do: :proceed, else: {:respond, 304}

        :none ->
          :proceed
      end
    else
      :proceed
    end
  end

  # ETag 匹配：* 总命中（存在性）；否则按逗号分隔逐个比，strip W/ + 引号。
  defp etag_matches?("*", _etag), do: true

  defp etag_matches?(value, etag) do
    normalized_stored = normalize(etag)

    value
    |> String.split(",")
    |> Enum.map(&normalize/1)
    |> Enum.any?(fn v -> v == normalized_stored end)
  end

  defp normalize(tag) do
    tag
    |> String.trim()
    |> strip_weak()
    |> String.trim("\"")
    |> String.downcase()
  end

  defp strip_weak("W/" <> rest), do: rest
  defp strip_weak(other), do: other

  defp get(headers, name) do
    Enum.find_value(headers, fn {k, v} -> if String.downcase(k) == name, do: v end)
  end

  # RFC1123（"Wed, 30 Nov 2011 03:39:05 GMT"）。不可解析 → :none（忽略该头）。
  defp parse_http_date(nil), do: :none
  defp parse_http_date(str), do: rfc1123(str)

  defp rfc1123(str) do
    re = ~r/^[A-Za-z]{3}, (\d{2}) ([A-Za-z]{3}) (\d{4}) (\d{2}):(\d{2}):(\d{2}) GMT$/

    case Regex.run(re, String.trim(str)) do
      [_, d, mon, y, h, mi, s] ->
        with {:ok, month} <- month_num(mon),
             {:ok, naive} <-
               NaiveDateTime.new(
                 String.to_integer(y),
                 month,
                 String.to_integer(d),
                 String.to_integer(h),
                 String.to_integer(mi),
                 String.to_integer(s)
               ) do
          {:ok, DateTime.from_naive!(naive, "Etc/UTC")}
        else
          _ -> :none
        end

      _ ->
        :none
    end
  end

  defp month_num(m) do
    map = %{
      "Jan" => 1,
      "Feb" => 2,
      "Mar" => 3,
      "Apr" => 4,
      "May" => 5,
      "Jun" => 6,
      "Jul" => 7,
      "Aug" => 8,
      "Sep" => 9,
      "Oct" => 10,
      "Nov" => 11,
      "Dec" => 12
    }

    case Map.get(map, m) do
      nil -> :error
      n -> {:ok, n}
    end
  end
end
