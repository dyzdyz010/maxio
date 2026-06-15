defmodule Maxio.S3.RequestPayment do
  @moduledoc """
  Bucket-level RequestPayment helpers.

  This slice stores and renders the S3 control-plane RequestPaymentConfiguration.
  Requester Pays data-plane enforcement is a separate feature.
  """

  alias Maxio.BucketConfigs
  alias Maxio.S3.Error

  @values ~w(Requester BucketOwner)
  @default %{"Payer" => "BucketOwner"}

  @spec values() :: [String.t()]
  def values, do: @values

  @spec default() :: map()
  def default, do: @default

  @spec valid_payer?(term()) :: boolean()
  def valid_payer?(payer), do: payer in @values

  @spec normalize(map()) :: map()
  def normalize(config) when is_map(config) do
    config
    |> fetch_payer()
    |> case do
      payer when payer in @values ->
        %{"Payer" => payer}

      _other ->
        raise Error.new(:internal_error, message: "Invalid stored RequestPaymentConfiguration")
    end
  end

  defp fetch_payer(config) do
    cond do
      Map.has_key?(config, "Payer") -> Map.get(config, "Payer")
      Map.has_key?(config, "payer") -> Map.get(config, "payer")
      true -> :missing
    end
  end

  @spec get_config(String.t()) :: {:ok, map()}
  def get_config(bucket) when is_binary(bucket) do
    case BucketConfigs.get(bucket, :request_payment) do
      {:ok, config} -> {:ok, normalize(config)}
      :none -> {:ok, @default}
    end
  end
end
