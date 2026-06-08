defmodule Maxio.S3.XML do
  @moduledoc """
  S3 XML 出站渲染辅助（saxy 封装）。统一命名空间、ISO8601 时间格式、ETag 引号、
  prolog（<?xml version="1.0" encoding="UTF-8"?>）。各响应 view 用 Saxy.XML.element/3
  构造 simple-form，再用本模块 encode/1 输出 iodata（零中间字符串，直接喂 send_resp）。
  """

  @namespace "http://s3.amazonaws.com/doc/2006-03-01/"

  @doc "S3 XML 命名空间字面量。"
  @spec namespace() :: String.t()
  def namespace, do: @namespace

  @doc """
  把 simple-form 根元素编码为带 prolog 的 XML iodata。

  与真实 AWS S3 / MinIO 对齐（铁律 5）：S3 在元素文本内容（CharData）里把 `"` / `'`
  保留为字面量（如 ETag 渲染为 `<ETag>"abc"</ETag>`，而非 `&quot;abc&quot;`）。这正是
  Go `encoding/xml`（AWS/MinIO 实现所用）的行为——CharData 只转义 `& < >`，不转义 `" '`。
  saxy 默认会把 `"`→`&quot;`、`'`→`&apos;`，与 S3 客户端（如 minio-go）不兼容（参见
  rustfs#1771：`&quot;` 的 ETag 会破坏 minio-go 解析）。因此编码后把这两个实体还原为字面量。

  安全性：用户输入里的字面 `&` 会先被 saxy 转义成 `&amp;`，故最终字节流中出现的
  `&quot;` / `&apos;` 只可能源自真实的 `"` / `'` 字符——还原是可逆且无歧义的。
  """
  @spec encode(Saxy.XML.element()) :: iodata()
  def encode(root) do
    root
    |> Saxy.encode_to_iodata!(version: "1.0", encoding: "UTF-8")
    |> IO.iodata_to_binary()
    |> unescape_s3_quotes()
  end

  defp unescape_s3_quotes(xml) do
    xml
    |> String.replace("&quot;", "\"")
    |> String.replace("&apos;", "'")
  end

  @doc """
  DateTime → 列举 XML 体所用 ISO8601（UTC、毫秒、Z）：YYYY-MM-DDTHH:MM:SS.000Z。
  （注意：HTTP Last-Modified 响应头用 RFC1123，不走这里。）
  """
  @spec iso8601(DateTime.t()) :: String.t()
  def iso8601(%DateTime{} = dt) do
    dt = DateTime.shift_zone!(dt, "Etc/UTC", Calendar.UTCOnlyTimeZoneDatabase)
    ms = div(elem(dt.microsecond, 0), 1000)

    date = Calendar.strftime(dt, "%Y-%m-%dT%H:%M:%S")
    millis = ms |> Integer.to_string() |> String.pad_leading(3, "0")
    "#{date}.#{millis}Z"
  end

  @doc "给 ETag 加引号（幂等：已带引号不重复加）。"
  @spec quote_etag(String.t()) :: String.t()
  def quote_etag(etag) do
    trimmed = String.trim(etag, "\"")
    "\"" <> trimmed <> "\""
  end
end
