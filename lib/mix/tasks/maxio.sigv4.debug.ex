defmodule Mix.Tasks.Maxio.Sigv4.Debug do
  @shortdoc "复算并打印一次 SigV4 签名的全部中间产物（取证用）"
  @moduledoc """
  SigV4 签名复算取证 CLI（AGENTS.md 铁律 4：后端无 GUI，签名问题靠 CLI 定位）。

  用法（PowerShell；先设 $env:ERL_FLAGS="-kernel standard_io_encoding unicode"）：

      mix maxio.sigv4.debug ^
        --method GET --path /test.txt ^
        --region us-east-1 --service s3 ^
        --access-key AKIAIOSFODNN7EXAMPLE ^
        --secret "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY" ^
        --date 20130524T000000Z ^
        --payload-hash e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 ^
        --header "host:examplebucket.s3.amazonaws.com" ^
        --header "range:bytes=0-9" ^
        --header "x-amz-content-sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" ^
        --header "x-amz-date:20130524T000000Z"

  打印 canonical request / string-to-sign / kDate/kRegion/kService/kSigning(hex) / 最终签名。
  用官方 VECTOR A 参数运行应得签名 f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41。
  """
  use Mix.Task

  alias Maxio.Auth.SigV4.{Canonical, Signer}

  @switches [
    method: :string,
    path: :string,
    region: :string,
    service: :string,
    access_key: :string,
    secret: :string,
    date: :string,
    payload_hash: :string,
    header: :keep,
    query: :keep
  ]

  @impl true
  def run(argv) do
    {opts, _rest, _invalid} = OptionParser.parse(argv, strict: @switches)
    result = run_debug(opts)

    IO.puts("=== CanonicalRequest ===")
    IO.puts(result.canonical_request)
    IO.puts("\n=== StringToSign ===")
    IO.puts(result.string_to_sign)
    IO.puts("\n=== Signing key chain (hex) ===")
    IO.puts("kDate    = #{result.k_date}")
    IO.puts("kRegion  = #{result.k_region}")
    IO.puts("kService = #{result.k_service}")
    IO.puts("kSigning = #{result.k_signing}")
    IO.puts("\n=== Signature ===")
    IO.puts(result.signature)
  end

  @doc "纯计算：返回各中间产物（便于测试断言，不打印）。"
  @spec run_debug(keyword()) :: map()
  def run_debug(opts) do
    method = Keyword.get(opts, :method, "GET")
    path = Keyword.get(opts, :path, "/")
    region = Keyword.get(opts, :region, "us-east-1")
    service = Keyword.get(opts, :service, "s3")
    secret = Keyword.fetch!(opts, :secret)
    date = Keyword.fetch!(opts, :date)
    payload_hash = Keyword.get(opts, :payload_hash, Signer.hex_sha256(""))
    scope_date = String.slice(date, 0, 8)
    scope = "#{scope_date}/#{region}/#{service}/aws4_request"

    headers =
      opts
      |> Keyword.get_values(:header)
      |> Enum.map(fn h ->
        [name, value] = String.split(h, ":", parts: 2)
        {String.downcase(name), value}
      end)

    query =
      opts
      |> Keyword.get_values(:query)
      |> Enum.map(fn q ->
        case String.split(q, "=", parts: 2) do
          [k, v] -> {k, v}
          [k] -> {k, ""}
        end
      end)
      |> Enum.into(%{})

    canonical =
      Canonical.canonical_request(%{
        method: method,
        path: path,
        query: query,
        headers: headers,
        payload_hash: payload_hash
      })

    sts = Signer.string_to_sign(date, scope, canonical, "AWS4-HMAC-SHA256")

    # 逐级链（hex 仅供人读取证；真实链用原始二进制）
    k_date = hmac("AWS4" <> secret, scope_date)
    k_region = hmac(k_date, region)
    k_service = hmac(k_region, service)
    k_signing = hmac(k_service, "aws4_request")
    sig = Signer.signature(k_signing, sts)

    %{
      canonical_request: canonical,
      string_to_sign: sts,
      k_date: hex(k_date),
      k_region: hex(k_region),
      k_service: hex(k_service),
      k_signing: hex(k_signing),
      signature: sig
    }
  end

  defp hmac(key, data), do: :crypto.mac(:hmac, :sha256, key, data)
  defp hex(bin), do: Base.encode16(bin, case: :lower)
end
