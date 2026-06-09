defmodule Maxio.Auth do
  @moduledoc """
  鉴权编排 context：验证材料 → 时钟偏移/过期检查 → 查 secret → 复算签名 → 常数时间比对。
  成功返回 principal map，失败返回 %Maxio.S3.Error{}（绝不静默，所有失败打结构化日志）。

  验证材料 map：%{signed_request, method, path, query, headers, payload_hash, now}。
    * query 既可是 raw query 字符串（SigV4 plug 传 conn.query_string，保留字面 '+'/重复键，
      由 Canonical.canonical_query/1 的字符串子句严格 RFC3986 解码后规范化），也可是 name=>value
      map（向后兼容）；presigned 形态必须**已排除 X-Amz-Signature**；
    * headers 必须仅含 SignedHeaders 子集（已小写）；
    * path 是已 URL 解码的真实对象 key 路径（Canonical 内部再做 S3 单次编码）；
    * now 是注入的服务器参考时钟（依赖注入：生产默认 DateTime.utc_now()，
      测试传与 x-amz-date 对齐的固定时刻），鉴权不直接读系统时钟。

  请求时间校验按 auth_type 区分（对齐真实 AWS，铁律 5）：
    * header 形态走 ±clock_skew_ms 时钟偏移窗口；
    * presigned 形态不套偏移窗口，validity 由 X-Amz-Date + X-Amz-Expires 决定。
  """
  alias Maxio.Auth.SigV4.{Canonical, Signer}
  alias Maxio.Auth.CredentialStore
  alias Maxio.S3.{Error, Log}

  @algorithm "AWS4-HMAC-SHA256"

  @spec authenticate(map()) :: {:ok, map(), map()} | {:error, Error.t()}
  def authenticate(%{signed_request: sr} = material) do
    with :ok <- check_signed_headers(sr),
         :ok <- check_request_time(sr, material.now),
         {:ok, %{secret_key: secret, principal: principal}} <- lookup_secret(sr.access_key),
         {:ok, sig_context} <- verify_signature(sr, material, secret) do
      Log.info("sigv4 authenticated", auth_type: sr.auth_type)
      {:ok, principal, sig_context}
    end
  end

  # SignedHeaders 必须含 host（MinIO extractSignedHeaders 在验签前的硬性检查）。
  # 缺 host → ErrUnsignedHeaders（AccessDenied/400），绝不放行自洽但漏签 host 的请求（铁律 3/5）。
  defp check_signed_headers(%{signed_headers: signed_headers}) do
    if "host" in Enum.map(signed_headers, &String.downcase/1) do
      :ok
    else
      Log.warn("unsigned host header", reason: :unsigned_headers)
      {:error, Error.new(:unsigned_headers)}
    end
  end

  # ── 请求时间有效性 ──
  # 时间语义按 auth_type 区分（铁律 5，对齐真实 AWS）：
  #   * header 形态：用 ±clock_skew_ms 时钟偏移窗口校验 x-amz-date；
  #   * presigned 形态：AWS 不套 ±15min 偏移，validity 完全由 X-Amz-Date + X-Amz-Expires 决定。
  # now 是注入的服务器参考时钟（生产默认 DateTime.utc_now()，测试传固定时刻）。
  defp check_request_time(%{auth_type: :presigned} = sr, now) do
    check_presigned_expiry(sr, now)
  end

  defp check_request_time(%{auth_type: :header, amz_date: amz_date}, now) do
    check_clock_skew(amz_date, now)
  end

  # ── 时钟偏移（±clock_skew_ms，仅 header 形态）──
  defp check_clock_skew(amz_date, now) do
    case parse_amz_date(amz_date) do
      {:ok, req_time} ->
        skew_ms = abs(DateTime.diff(now, req_time, :millisecond))

        if skew_ms > clock_skew_ms() do
          Log.warn("request time too skewed",
            auth_type: :header,
            reason: :request_time_too_skewed
          )

          {:error, Error.new(:request_time_too_skewed)}
        else
          :ok
        end

      :error ->
        {:error, Error.new(:authorization_header_malformed, message: "Invalid x-amz-date")}
    end
  end

  # ── presigned 过期（now > amz_date + expires）──
  defp check_presigned_expiry(%{auth_type: :presigned, expires: expires, amz_date: amz_date}, now)
       when is_integer(expires) do
    cond do
      expires < 1 or expires > 604_800 ->
        {:error,
         Error.new(:authorization_query_parameters_error, message: "X-Amz-Expires out of range")}

      true ->
        case parse_amz_date(amz_date) do
          {:ok, start} ->
            if DateTime.diff(now, start, :second) > expires do
              Log.warn("presigned url expired", auth_type: :presigned, reason: :access_denied)
              {:error, Error.new(:access_denied, message: "Request has expired")}
            else
              :ok
            end

          :error ->
            {:error,
             Error.new(:authorization_query_parameters_error, message: "Invalid X-Amz-Date")}
        end
    end
  end

  defp check_presigned_expiry(_sr, _now), do: :ok

  # ── 查 secret ──
  defp lookup_secret(access_key) do
    case CredentialStore.get_secret(access_key) do
      {:ok, found} ->
        {:ok, found}

      :error ->
        Log.warn("unknown access key", auth_type: :header, reason: :invalid_access_key_id)
        {:error, Error.new(:invalid_access_key_id)}
    end
  end

  # ── 复算签名并常数时间比对 ──
  defp verify_signature(sr, material, secret) do
    scope = "#{sr.scope_date}/#{sr.region}/#{sr.service}/aws4_request"

    req = %{
      method: material.method,
      path: material.path,
      query: material.query,
      headers: filter_signed_headers(material.headers, sr.signed_headers),
      payload_hash: material.payload_hash
    }

    canonical = Canonical.canonical_request(req)
    sts = Signer.string_to_sign(sr.amz_date, scope, canonical, @algorithm)
    key = Signer.derive_signing_key(secret, sr.scope_date, sr.region, sr.service)
    computed = Signer.signature(key, sts)

    if Signer.secure_compare(computed, sr.signature) do
      # sig_context = 验完 seed 签名后已有的、逐块流式验证（BodyReader→StreamingVerifier）
      # 要复用的材料——避免重查 secret / 重推 kSigning（铁律 2：不重复劳动）。
      {:ok,
       %{
         k_signing: key,
         scope: scope,
         seed_signature: sr.signature,
         amz_date: sr.amz_date
       }}
    else
      Log.warn("signature mismatch", auth_type: sr.auth_type, reason: :signature_does_not_match)
      {:error, Error.new(:signature_does_not_match)}
    end
  end

  # 仅保留 SignedHeaders 列出的 header（已小写名比较），保持调用方给的值。
  defp filter_signed_headers(headers, signed_names) do
    set = MapSet.new(signed_names)
    Enum.filter(headers, fn {name, _v} -> MapSet.member?(set, String.downcase(name)) end)
  end

  # "yyyyMMddTHHmmssZ" → DateTime（UTC）
  defp parse_amz_date(
         <<y::binary-4, mo::binary-2, d::binary-2, "T", h::binary-2, mi::binary-2, s::binary-2,
           "Z">>
       ) do
    with {year, ""} <- Integer.parse(y),
         {month, ""} <- Integer.parse(mo),
         {day, ""} <- Integer.parse(d),
         {hour, ""} <- Integer.parse(h),
         {minute, ""} <- Integer.parse(mi),
         {second, ""} <- Integer.parse(s),
         {:ok, naive} <- NaiveDateTime.new(year, month, day, hour, minute, second) do
      {:ok, DateTime.from_naive!(naive, "Etc/UTC")}
    else
      _ -> :error
    end
  end

  defp parse_amz_date(_), do: :error

  defp clock_skew_ms do
    Application.fetch_env!(:maxio, :s3) |> Keyword.fetch!(:clock_skew_ms)
  end
end
