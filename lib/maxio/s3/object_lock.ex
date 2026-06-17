defmodule Maxio.S3.ObjectLock do
  @moduledoc """
  Bucket and object Object Lock helpers.

  Bucket configuration controls default retention. Object-level retention and
  legal hold metadata live on each object version and are enforced by write and
  delete handlers before any bytes or delete markers are committed.
  """

  import Plug.Conn, only: [get_req_header: 2]

  alias Maxio.BucketConfigs
  alias Maxio.S3.Error

  @valid_modes ~w(COMPLIANCE GOVERNANCE)
  @enabled "Enabled"

  @spec enabled_config() :: map()
  def enabled_config, do: %{"ObjectLockEnabled" => @enabled}

  @spec get_config(String.t()) :: {:ok, map()} | :none
  def get_config(bucket) when is_binary(bucket) do
    case BucketConfigs.get(bucket, :object_lock) do
      {:ok, stored} -> {:ok, normalize_config(stored)}
      :none -> :none
    end
  end

  @spec put_config(String.t(), map()) :: :ok
  def put_config(bucket, config) when is_binary(bucket) and is_map(config) do
    :ok = BucketConfigs.put(bucket, :object_lock, normalize_config(config))
  end

  @spec bucket_enabled?(String.t()) :: boolean()
  def bucket_enabled?(bucket) when is_binary(bucket) do
    match?({:ok, %{"ObjectLockEnabled" => @enabled}}, get_config(bucket))
  end

  @spec default_retention_attrs(String.t(), DateTime.t()) :: map()
  def default_retention_attrs(bucket, %DateTime{} = now) when is_binary(bucket) do
    case get_config(bucket) do
      {:ok, %{"Rule" => %{"DefaultRetention" => retention}}} ->
        retention_attrs(retention["Mode"], retain_until(retention, now))

      _other ->
        %{}
    end
  end

  @spec retention_from_headers(keyword() | [{String.t(), String.t()}], DateTime.t()) ::
          map() | :none
  def retention_from_headers(headers, %DateTime{} = _now) when is_list(headers) do
    mode = header(headers, "x-amz-object-lock-mode")
    retain_until = header(headers, "x-amz-object-lock-retain-until-date")

    cond do
      is_nil(mode) and is_nil(retain_until) ->
        :none

      is_binary(mode) and is_binary(retain_until) ->
        retention_attrs(normalize_request_mode!(mode), parse_request_retain_until!(retain_until))

      true ->
        invalid_request!("Object Lock retention requires both mode and retain-until-date")
    end
  end

  @spec legal_hold_from_headers(keyword() | [{String.t(), String.t()}]) :: map()
  def legal_hold_from_headers(headers) when is_list(headers) do
    case header(headers, "x-amz-object-lock-legal-hold") do
      nil -> %{}
      value -> %{:object_lock_legal_hold => normalize_request_legal_hold!(value)}
    end
  end

  @spec validate_object_lock_upload_headers!(Plug.Conn.t()) :: :ok
  def validate_object_lock_upload_headers!(conn) do
    has_object_lock_headers? =
      Enum.any?(conn.req_headers, fn {name, _value} ->
        String.starts_with?(String.downcase(name), "x-amz-object-lock-")
      end)

    if has_object_lock_headers? and get_req_header(conn, "content-md5") == [] and
         get_req_header(conn, "x-amz-sdk-checksum-algorithm") == [] do
      raise Error.new(:invalid_request,
              message:
                "Content-MD5 or x-amz-sdk-checksum-algorithm is required for Object Lock protected uploads"
            )
    end

    :ok
  end

  @spec request_retention_attrs(Plug.Conn.t(), String.t(), DateTime.t()) :: map()
  def request_retention_attrs(conn, bucket, %DateTime{} = now) do
    case retention_from_headers(conn.req_headers, now) do
      :none -> default_retention_attrs(bucket, now)
      attrs -> attrs
    end
  end

  @spec request_object_lock_attrs(Plug.Conn.t(), String.t(), DateTime.t()) :: map()
  def request_object_lock_attrs(conn, bucket, %DateTime{} = now) do
    conn
    |> request_retention_attrs(bucket, now)
    |> Map.merge(legal_hold_from_headers(conn.req_headers))
  end

  @spec normalize_object_retention(map()) :: map()
  def normalize_object_retention(%{} = attrs) do
    mode = value(attrs, ["Mode", "mode"])
    retain_until = value(attrs, ["RetainUntilDate", "retain_until_date"])
    retention_attrs(normalize_request_mode!(mode), parse_request_retain_until!(retain_until))
  end

  @spec normalize_object_legal_hold(map()) :: map()
  def normalize_object_legal_hold(%{} = attrs) do
    %{
      :object_lock_legal_hold => normalize_request_legal_hold!(value(attrs, ["Status", "status"]))
    }
  end

  @spec locked?(map(), keyword()) :: boolean()
  def locked?(object, opts \\ []) when is_map(object) do
    bypass_governance? = Keyword.get(opts, :bypass_governance?, false)
    now = Keyword.get(opts, :now, DateTime.utc_now())

    legal_hold_on?(object) or retention_active?(object, now, bypass_governance?)
  end

  @spec validate_client_config(map()) :: {:ok, map()} | {:error, :malformed_xml}
  def validate_client_config(config) when is_map(config) do
    {:ok, normalize_config(config)}
  rescue
    _err in Error -> {:error, :malformed_xml}
  end

  @spec normalize_config(map()) :: map()
  def normalize_config(config) when is_map(config) do
    enabled = value(config, ["ObjectLockEnabled", "object_lock_enabled"])
    rule = value(config, ["Rule", "rule"])

    %{"ObjectLockEnabled" => normalize_enabled(enabled)}
    |> maybe_put_rule(rule)
  end

  def normalize_config(_config), do: invalid_stored!()

  defp retention_attrs(mode, %DateTime{} = retain_until) do
    %{
      object_lock_mode: normalize_mode(mode),
      object_lock_retain_until: retain_until
    }
  end

  defp retain_until(%{"Days" => days}, now),
    do: DateTime.add(now, normalize_positive_integer(days), :day)

  defp retain_until(%{"Years" => years}, now),
    do: add_years(now, normalize_positive_integer(years))

  defp maybe_put_rule(config, nil), do: config

  defp maybe_put_rule(config, rule) when is_map(rule) do
    default_retention = value(rule, ["DefaultRetention", "default_retention"])

    Map.put(config, "Rule", %{
      "DefaultRetention" => normalize_default_retention(default_retention)
    })
  end

  defp maybe_put_rule(_config, _rule), do: invalid_stored!()

  defp normalize_default_retention(retention) when is_map(retention) do
    mode = value(retention, ["Mode", "mode"])
    days = value(retention, ["Days", "days"])
    years = value(retention, ["Years", "years"])

    %{"Mode" => normalize_mode(mode)}
    |> put_duration(days, years)
  end

  defp normalize_default_retention(_retention), do: invalid_stored!()

  defp put_duration(_retention, nil, nil), do: invalid_stored!()

  defp put_duration(retention, days, nil),
    do: Map.put(retention, "Days", normalize_positive_integer(days))

  defp put_duration(retention, nil, years),
    do: Map.put(retention, "Years", normalize_positive_integer(years))

  defp put_duration(_retention, _days, _years), do: invalid_stored!()

  defp normalize_enabled(@enabled), do: @enabled
  defp normalize_enabled(_enabled), do: invalid_stored!()

  defp normalize_mode(mode) when mode in @valid_modes, do: mode

  defp normalize_mode(mode) when is_binary(mode) do
    case mode |> String.trim() |> String.upcase() do
      mode when mode in @valid_modes -> mode
      _other -> invalid_stored!()
    end
  end

  defp normalize_mode(_mode), do: invalid_stored!()

  defp normalize_request_mode!(mode) when is_binary(mode) do
    case mode |> String.trim() |> String.upcase() do
      mode when mode in @valid_modes -> mode
      _other -> invalid_argument!("Object Lock mode must be GOVERNANCE or COMPLIANCE")
    end
  end

  defp normalize_request_mode!(_mode),
    do: invalid_argument!("Object Lock mode must be GOVERNANCE or COMPLIANCE")

  defp normalize_request_legal_hold!(status) when is_binary(status) do
    case status |> String.trim() |> String.upcase() do
      status when status in ["ON", "OFF"] -> status
      _other -> invalid_argument!("Object Lock legal hold status must be ON or OFF")
    end
  end

  defp normalize_request_legal_hold!(_status),
    do: invalid_argument!("Object Lock legal hold status must be ON or OFF")

  defp parse_request_retain_until!(value) do
    parse_retain_until(value, fn ->
      invalid_argument!("Object Lock retain-until-date must be an ISO8601 UTC timestamp")
    end)
  end

  defp parse_retain_until(value, on_error) when is_binary(value) and is_function(on_error, 0) do
    value = String.trim(value)

    cond do
      String.ends_with?(value, "Z") ->
        case DateTime.from_iso8601(value) do
          {:ok, dt, 0} -> dt
          _other -> on_error.()
        end

      true ->
        case NaiveDateTime.from_iso8601(value) do
          {:ok, naive} -> DateTime.from_naive!(naive, "Etc/UTC")
          _other -> on_error.()
        end
    end
  end

  defp parse_retain_until(_value, on_error), do: on_error.()

  defp normalize_positive_integer(value) when is_integer(value) and value > 0, do: value

  defp normalize_positive_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> integer
      _other -> invalid_stored!()
    end
  end

  defp normalize_positive_integer(_value), do: invalid_stored!()

  defp value(map, keys, default \\ nil) do
    Enum.reduce_while(keys, default, fn key, fallback ->
      case Map.fetch(map, key) do
        {:ok, value} -> {:halt, value}
        :error -> {:cont, fallback}
      end
    end)
  end

  defp header(headers, target) do
    target = String.downcase(target)

    headers
    |> Enum.find_value(fn {name, value} ->
      if String.downcase(to_string(name)) == target, do: value
    end)
  end

  defp legal_hold_on?(object), do: object_value(object, :object_lock_legal_hold) == "ON"

  defp retention_active?(object, now, bypass_governance?) do
    mode = object_value(object, :object_lock_mode)
    retain_until = object_value(object, :object_lock_retain_until)

    active_until?(retain_until, now) and
      (mode == "COMPLIANCE" or (mode == "GOVERNANCE" and not bypass_governance?))
  end

  defp active_until?(%DateTime{} = retain_until, %DateTime{} = now),
    do: DateTime.compare(retain_until, now) == :gt

  defp active_until?(_retain_until, _now), do: false

  defp object_value(object, key) when is_map(object) do
    Map.get(object, key) || Map.get(object, Atom.to_string(key))
  end

  defp invalid_request!(message),
    do: raise(Error.new(:invalid_request, message: message))

  defp invalid_argument!(message),
    do: raise(Error.new(:invalid_argument, message: message))

  defp invalid_stored!,
    do: raise(Error.new(:internal_error, message: "Invalid stored ObjectLockConfiguration"))

  defp add_years(%DateTime{} = now, years) do
    current_date = DateTime.to_date(now)
    target_year = current_date.year + years

    day =
      min(current_date.day, Date.days_in_month(%Date{current_date | year: target_year, day: 1}))

    target_date = %Date{current_date | year: target_year, day: day}
    {:ok, target} = DateTime.new(target_date, DateTime.to_time(now), "Etc/UTC")
    target
  end
end
