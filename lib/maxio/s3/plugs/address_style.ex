defmodule Maxio.S3.Plugs.AddressStyle do
  @moduledoc """
  寻址解析 plug：把 path-style 与 virtual-host 两种寻址统一成
  assigns.s3_bucket / s3_key / s3_level（:service | :bucket | :object）。
  下游 handler 只看 {bucket, key}，不关心寻址方式（铁律 1）。
  domain 来自 config :maxio, :s3, :domain。

  host 的权威来源是 `conn.host`（由 HTTP 适配器从 Host 头/authority 解析），
  与 SigV4 plug 一致：直接读 conn.host 而非 req_headers 的 host（新版 Plug 不再
  把 host 放进 req_headers，且禁止用 put_req_header 写 host）。跨适配器稳健（铁律 5）。
  """
  import Plug.Conn
  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    host = conn.host
    domain = domain()

    {bucket, key} =
      case virtual_host_bucket(host, domain) do
        nil -> path_style(conn.path_info)
        vbucket -> {vbucket, join_key(conn.path_info)}
      end

    level = level_of(bucket, key)

    conn
    |> assign(:s3_bucket, bucket)
    |> assign(:s3_key, key)
    |> assign(:s3_level, level)
  end

  # virtual-host：host == "<bucket>.<domain>" 时返回 bucket，否则 nil。
  defp virtual_host_bucket(nil, _domain), do: nil

  defp virtual_host_bucket(host, domain) do
    suffix = "." <> domain

    if String.ends_with?(host, suffix) and host != domain do
      String.replace_suffix(host, suffix, "")
    else
      nil
    end
  end

  # path-style：[] → service；[bucket] → bucket；[bucket | rest] → object。
  defp path_style([]), do: {nil, nil}
  defp path_style([bucket]), do: {bucket, nil}
  defp path_style([bucket | rest]), do: {bucket, Enum.join(rest, "/")}

  defp join_key([]), do: nil
  defp join_key(path_info), do: Enum.join(path_info, "/")

  defp level_of(nil, _key), do: :service
  defp level_of(_bucket, nil), do: :bucket
  defp level_of(_bucket, ""), do: :bucket
  defp level_of(_bucket, _key), do: :object

  defp domain do
    Application.fetch_env!(:maxio, :s3) |> Keyword.fetch!(:domain)
  end
end
