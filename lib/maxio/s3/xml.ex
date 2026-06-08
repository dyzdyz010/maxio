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

  @doc "把 simple-form 根元素编码为带 prolog 的 XML iodata。"
  @spec encode(Saxy.XML.element()) :: iodata()
  def encode(root) do
    Saxy.encode_to_iodata!(root, version: "1.0", encoding: "UTF-8")
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
