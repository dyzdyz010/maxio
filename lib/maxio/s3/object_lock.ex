defmodule Maxio.S3.ObjectLock do
  @moduledoc """
  Bucket Object Lock configuration helpers.

  This stores and returns the bucket-level default Object Lock configuration.
  It does not enforce object retention or legal holds in the data plane.
  """

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
  defp normalize_mode(_mode), do: invalid_stored!()

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

  defp invalid_stored!,
    do: raise(Error.new(:internal_error, message: "Invalid stored ObjectLockConfiguration"))
end
