defmodule Maxio.S3.Plugs.AddressStyle do
  @moduledoc """
  寻址解析 plug：把 path-style 与 virtual-host 两种寻址统一成
  assigns.s3_bucket / s3_key / s3_level（:service | :bucket | :object）。
  下游 handler 只看 {bucket, key}，不关心寻址方式（铁律 1）。
  domain 来自 config :maxio, :s3, :domain。

  另外 assign `:s3_address_style`（`:path | :virtual_host | :website`）——**寻址方式本身**
  也是数据契约的一部分：MinIO 保留面（`/minio/health/*`、`/minio/admin/*`、metrics）只在
  path-style 下才等于"服务器根命名空间"，vhost 下它是某个真实桶里 `minio/...` 的对象 key。
  认领方（`Maxio.S3.ReservedNamespace.claimed?/2`）据此判定，绝不各自再解析一遍 Host。

  host 的权威来源是 `conn.host`（由 HTTP 适配器从 Host 头/authority 解析），
  与 SigV4 plug 一致：直接读 conn.host 而非 req_headers 的 host（新版 Plug 不再
  把 host 放进 req_headers，且禁止用 put_req_header 写 host）。跨适配器稳健（铁律 5）。

  bucket / object key 一律由 `Maxio.S3.RawPath` 从**原始 request_path** 切出（单次解码、
  不折叠 `/`）：绝不用 `conn.path_info`——后者会丢失尾斜杠/连续斜杠/前导斜杠（如 key
  `"dir/"` 被折叠成 `"dir"` 导致数据丢失，铁律 5 禁止此类归一化）。
  """
  import Plug.Conn
  alias Maxio.S3.RawPath
  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    host = conn.host
    domain = domain()

    {bucket, key, endpoint_kind, address_style} =
      case website_host_bucket(host) do
        nil ->
          case virtual_host_bucket(host, domain) do
            nil ->
              {bucket, key} = RawPath.path_style(conn)
              {bucket, key, :rest, :path}

            vbucket ->
              {vbucket, RawPath.vhost_key(conn), :rest, :virtual_host}
          end

        vbucket ->
          {vbucket, RawPath.vhost_key(conn), :website, :website}
      end

    level = level_of(bucket, key)

    conn
    |> assign(:s3_bucket, bucket)
    |> assign(:s3_key, key)
    |> assign(:s3_level, level)
    |> assign(:s3_endpoint_kind, endpoint_kind)
    |> assign(:s3_address_style, address_style)
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

  defp website_host_bucket(nil), do: nil

  defp website_host_bucket(host) do
    case website_domain() do
      nil -> nil
      domain -> virtual_host_bucket(host, domain)
    end
  end

  defp level_of(nil, _key), do: :service
  defp level_of(_bucket, nil), do: :bucket
  defp level_of(_bucket, ""), do: :bucket
  defp level_of(_bucket, _key), do: :object

  defp domain do
    Application.fetch_env!(:maxio, :s3) |> Keyword.fetch!(:domain)
  end

  defp website_domain do
    :maxio
    |> Application.fetch_env!(:s3)
    |> Keyword.get(:website_domain)
    |> case do
      value when is_binary(value) and value != "" -> value
      _other -> nil
    end
  end
end
