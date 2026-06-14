defmodule Maxio.IAM.TOTP do
  @moduledoc """
  RFC 6238 TOTP/HOTP helpers for local MFA Delete devices.

  Defaults match common AWS-compatible virtual MFA devices: HMAC-SHA1, 6 digits,
  30 second period, and a +/- 1 step verifier window.
  """
  import Bitwise

  @default_period 30
  @default_digits 6
  @default_drift 1
  @default_algorithm "sha1"

  @type verify_error ::
          :invalid_totp_secret
          | :invalid_totp_code
          | :unsupported_totp_algorithm
          | :totp_code_mismatch

  @spec generate_secret(pos_integer()) :: String.t()
  def generate_secret(byte_count \\ 20) when is_integer(byte_count) and byte_count > 0 do
    byte_count
    |> :crypto.strong_rand_bytes()
    |> Base.encode32(padding: false)
  end

  @spec code(String.t(), keyword()) :: {:ok, String.t()} | {:error, verify_error()}
  def code(secret_base32, opts \\ []) when is_binary(secret_base32) do
    with {:ok, secret} <- decode_secret(secret_base32),
         {:ok, algorithm} <- algorithm(opts),
         digits <- Keyword.get(opts, :digits, @default_digits),
         true <- valid_digits?(digits) do
      {:ok, hotp(secret, current_step(opts), digits, algorithm)}
    else
      false -> {:error, :invalid_totp_code}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec code!(String.t(), keyword()) :: String.t()
  def code!(secret_base32, opts \\ []) do
    case code(secret_base32, opts) do
      {:ok, code} -> code
      {:error, reason} -> raise ArgumentError, "could not generate TOTP code: #{inspect(reason)}"
    end
  end

  @spec verify(String.t(), String.t(), keyword()) :: :ok | {:error, verify_error()}
  def verify(secret_base32, code, opts \\ []) do
    case match(secret_base32, code, opts) do
      {:ok, _step, _offset} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec match(String.t(), String.t(), keyword()) ::
          {:ok, integer(), integer()} | {:error, verify_error()}
  def match(secret_base32, code, opts \\ [])
      when is_binary(secret_base32) and is_binary(code) do
    digits = Keyword.get(opts, :digits, @default_digits)

    with true <- valid_digits?(digits),
         {:ok, normalized_code} <- normalize_code(code, digits),
         {:ok, secret} <- decode_secret(secret_base32),
         {:ok, algorithm} <- algorithm(opts) do
      base_step = current_step(opts)
      drift = Keyword.get(opts, :drift_steps, @default_drift)

      -drift..drift
      |> Enum.find_value(fn offset ->
        step = base_step + offset
        expected = hotp(secret, step, digits, algorithm)

        if Plug.Crypto.secure_compare(expected, normalized_code) do
          {:ok, step, offset}
        end
      end)
      |> case do
        nil -> {:error, :totp_code_mismatch}
        matched -> matched
      end
    else
      false -> {:error, :invalid_totp_code}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec verification_uri(String.t(), keyword()) :: String.t()
  def verification_uri(secret_base32, opts \\ []) do
    issuer = Keyword.get(opts, :issuer, "maxio")
    label = Keyword.get(opts, :label, "root-account-mfa-device")

    algorithm =
      Keyword.get(opts, :algorithm, @default_algorithm) |> to_string() |> String.upcase()

    digits = Keyword.get(opts, :digits, @default_digits)
    period = Keyword.get(opts, :period_seconds, @default_period)

    query =
      URI.encode_query(%{
        "secret" => secret_base32,
        "issuer" => issuer,
        "algorithm" => algorithm,
        "digits" => digits,
        "period" => period
      })

    "otpauth://totp/#{URI.encode_www_form("#{issuer}:#{label}")}?#{query}"
  end

  @spec time_step(DateTime.t() | NaiveDateTime.t() | integer(), pos_integer()) :: integer()
  def time_step(time, period_seconds \\ @default_period)

  def time_step(%DateTime{} = time, period_seconds),
    do: time |> DateTime.to_unix() |> div(period_seconds)

  def time_step(%NaiveDateTime{} = time, period_seconds) do
    time
    |> DateTime.from_naive!("Etc/UTC")
    |> time_step(period_seconds)
  end

  def time_step(unix_seconds, period_seconds) when is_integer(unix_seconds),
    do: div(unix_seconds, period_seconds)

  defp current_step(opts) do
    period = Keyword.get(opts, :period_seconds, @default_period)
    time = Keyword.get(opts, :time, DateTime.utc_now())
    time_step(time, period)
  end

  defp decode_secret(secret_base32) do
    normalized =
      secret_base32
      |> String.trim()
      |> String.replace(~r/\s+/, "")
      |> String.trim_trailing("=")

    case Base.decode32(normalized, case: :mixed, padding: false) do
      {:ok, secret} when byte_size(secret) > 0 -> {:ok, secret}
      _other -> {:error, :invalid_totp_secret}
    end
  end

  defp normalize_code(code, digits) do
    pattern = ~r/^\d{#{digits}}$/

    if Regex.match?(pattern, code) do
      {:ok, code}
    else
      {:error, :invalid_totp_code}
    end
  end

  defp valid_digits?(digits), do: is_integer(digits) and digits >= 6 and digits <= 8

  defp algorithm(opts) do
    case Keyword.get(opts, :algorithm, @default_algorithm) do
      "sha1" -> {:ok, :sha}
      "SHA1" -> {:ok, :sha}
      :sha1 -> {:ok, :sha}
      :sha -> {:ok, :sha}
      _other -> {:error, :unsupported_totp_algorithm}
    end
  end

  defp hotp(secret, counter, digits, algorithm) when counter >= 0 do
    hmac = :crypto.mac(:hmac, algorithm, secret, <<counter::unsigned-big-integer-size(64)>>)
    offset = :binary.last(hmac) &&& 0x0F
    <<_prefix::binary-size(offset), truncated::binary-size(4), _rest::binary>> = hmac
    <<value::unsigned-big-integer-size(32)>> = truncated

    value
    |> band(0x7FFFFFFF)
    |> rem(pow10(digits))
    |> Integer.to_string()
    |> String.pad_leading(digits, "0")
  end

  defp pow10(digits), do: :erlang.trunc(:math.pow(10, digits))
end
