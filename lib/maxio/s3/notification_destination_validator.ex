defmodule Maxio.S3.NotificationDestinationValidator do
  @moduledoc """
  Pluggable validation seam for S3 bucket notification destinations.

  S3 validates SNS/SQS/Lambda notification destinations when storing a
  non-empty `NotificationConfiguration`, unless the request explicitly uses
  `x-amz-skip-destination-validation:true`. EventBridge has no per-destination
  ARN to validate.

  The default maxio configuration has no validator and therefore fails closed
  for direct SNS/SQS/Lambda destinations. Operators can wire a validator here
  without changing the S3 handler or the durable delivery/outbox pipeline.

  A validator that returns `:ok` or `{:ok, metadata}` is asserting the complete
  AWS-compatible validation contract for the supplied direct destinations:
  SNS/SQS destinations exist, allow this bucket owner to publish, and accepted
  the control-plane `s3:TestEvent` probe; Lambda destinations grant invoke
  permission to S3 for this bucket. The built-in opt-in AWS implementation is
  available as `Maxio.S3.NotificationDestinationValidator.AWS`.
  """

  alias Maxio.S3.Notification

  @callback validate(String.t(), map(), term()) :: :ok | {:ok, map()} | {:error, term()}

  @spec validate(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def validate(bucket, config, opts \\ []) when is_binary(bucket) and is_map(config) do
    config = Notification.normalize(config)

    if direct_destinations(config) == [] do
      {:ok, %{}}
    else
      case configured_validator(opts) do
        nil -> {:error, :no_validator}
        validator -> invoke_validator(validator, bucket, config)
      end
    end
  end

  @spec requires_validation?(map()) :: boolean()
  def requires_validation?(config) when is_map(config) do
    config
    |> Notification.normalize()
    |> direct_destinations()
    |> Enum.any?()
  end

  @spec direct_destinations(map()) :: [map()]
  def direct_destinations(config) when is_map(config) do
    (config["TopicConfigurations"] || []) ++
      (config["QueueConfigurations"] || []) ++ (config["LambdaFunctionConfigurations"] || [])
  end

  defp configured_validator(opts) do
    Keyword.get(opts, :validator) || app_validator()
  end

  defp app_validator do
    case Application.get_env(:maxio, :notification_destination_validator, []) do
      cfg when is_list(cfg) -> Keyword.get(cfg, :validator)
      validator -> validator
    end
  end

  defp invoke_validator({module, opts}, bucket, config) when is_atom(module) do
    module.validate(bucket, config, opts)
    |> normalize_result()
  rescue
    error -> {:error, {:validator_crashed, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:validator_caught, kind, reason}}
  end

  defp invoke_validator(module, bucket, config) when is_atom(module),
    do: invoke_validator({module, []}, bucket, config)

  defp invoke_validator(fun, bucket, config) when is_function(fun, 2) do
    fun.(bucket, config)
    |> normalize_result()
  rescue
    error -> {:error, {:validator_crashed, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:validator_caught, kind, reason}}
  end

  defp invoke_validator({fun, opts}, bucket, config) when is_function(fun, 3) do
    fun.(bucket, config, opts)
    |> normalize_result()
  rescue
    error -> {:error, {:validator_crashed, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:validator_caught, kind, reason}}
  end

  defp invoke_validator(fun, bucket, config) when is_function(fun, 3),
    do: invoke_validator({fun, []}, bucket, config)

  defp invoke_validator(other, _bucket, _config), do: {:error, {:invalid_validator, other}}

  defp normalize_result(:ok), do: {:ok, %{}}
  defp normalize_result({:ok, metadata}) when is_map(metadata), do: {:ok, metadata}
  defp normalize_result({:ok, nil}), do: {:ok, %{}}
  defp normalize_result({:error, reason}), do: {:error, reason}
  defp normalize_result(other), do: {:error, {:bad_validator_return, other}}
end
