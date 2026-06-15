defmodule Maxio.S3.Accelerate do
  @moduledoc """
  Bucket-level Transfer Acceleration configuration helpers.

  This stores and renders the S3 control-plane AccelerateConfiguration.
  Transfer Acceleration endpoint behavior is a separate feature.
  """

  alias Maxio.BucketConfigs
  alias Maxio.S3.Error

  @values ~w(Enabled Suspended)
  @empty %{"Status" => nil}

  @spec values() :: [String.t()]
  def values, do: @values

  @spec empty() :: map()
  def empty, do: @empty

  @spec valid_status?(term()) :: boolean()
  def valid_status?(status), do: status in @values

  @spec normalize(map()) :: map()
  def normalize(config) when is_map(config) do
    case fetch_status(config) do
      nil ->
        @empty

      status when status in @values ->
        %{"Status" => status}

      _other ->
        raise Error.new(:internal_error, message: "Invalid stored AccelerateConfiguration")
    end
  end

  @spec get_config(String.t()) :: {:ok, map()}
  def get_config(bucket) when is_binary(bucket) do
    case BucketConfigs.get(bucket, :accelerate) do
      {:ok, config} -> {:ok, normalize(config)}
      :none -> {:ok, @empty}
    end
  end

  defp fetch_status(config) do
    cond do
      Map.has_key?(config, "Status") -> Map.get(config, "Status")
      Map.has_key?(config, "status") -> Map.get(config, "status")
      true -> nil
    end
  end
end
