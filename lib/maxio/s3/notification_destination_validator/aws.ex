defmodule Maxio.S3.NotificationDestinationValidator.AWS do
  @moduledoc """
  AWS-backed bucket notification destination validator.

  This validator is opt-in:

      config :maxio, :notification_destination_validator,
        validator: {Maxio.S3.NotificationDestinationValidator.AWS, opts}

  It validates AWS destinations with control-plane calls:

    * SNS `GetTopicAttributes`, then `Publish` with a simplified `s3:TestEvent`
    * SQS `GetQueueAttributes`, then `SendMessage` with a simplified `s3:TestEvent`
    * Lambda `GetPolicy`

  The destination policy must include an Allow statement that lets the S3
  service principal publish/send/invoke from the current bucket source ARN and
  account. Unsupported policy conditions fail closed. SNS/SQS test sends are
  control-plane probes and are not written to maxio's notification outbox.
  """

  @behaviour Maxio.S3.NotificationDestinationValidator

  alias Maxio.S3.{AWSClient, AWSQueryAttributesParser, Log, Notification}
  alias Maxio.S3.NotificationDelivery.AWS, as: AWSDelivery

  @sns_version "2010-03-31"
  @sqs_target "AmazonSQS.GetQueueAttributes"
  @local_account_id "000000000000"

  @impl true
  def validate(bucket, config, opts)
      when is_binary(bucket) and is_map(config) and is_list(opts) do
    case Notification.validate_client_config(config) do
      {:ok, config} ->
        config
        |> destinations()
        |> validate_destinations(bucket, opts)

      {:error, :malformed_xml} ->
        {:error, :invalid_notification_configuration}
    end
  end

  def validate(_bucket, _config, opts), do: {:error, {:invalid_validator_opts, opts}}

  defp validate_destinations(destinations, bucket, opts) do
    Enum.reduce_while(destinations, {:ok, []}, fn destination, {:ok, acc} ->
      case validate_destination(bucket, destination, opts) do
        {:ok, metadata} -> {:cont, {:ok, [metadata | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, validated} ->
        validated = Enum.reverse(validated)

        {:ok,
         %{
           validated: validated,
           count: length(validated),
           test_messages_sent: Enum.count(validated, &Map.has_key?(&1, :test_message)),
           sns_test_message_id: sns_test_message_id(validated)
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_destination(bucket, destination, opts) do
    result =
      with {:ok, arn_parts} <- AWSClient.parse_arn(destination.arn, destination.service),
           :ok <- validate_bucket_region(arn_parts, opts),
           :ok <- validate_supported_destination_shape(destination, arn_parts),
           {:ok, attributes} <- fetch_attributes(destination, arn_parts, opts),
           :ok <- validate_identity_attribute(destination, attributes),
           {:ok, policy} <- decode_policy(Map.get(attributes, "Policy"), destination),
           :ok <- validate_policy(bucket, destination, arn_parts, policy, opts),
           {:ok, test_message} <- send_test_message(bucket, destination, opts) do
        metadata =
          %{
            type: destination.type,
            arn: destination.arn,
            id: destination.id,
            region: arn_parts.region,
            account: arn_parts.account
          }
          |> maybe_put(:test_message, test_message)

        {:ok, metadata}
      end

    case result do
      {:ok, metadata} ->
        {:ok, metadata}

      {:error, reason} ->
        log_validation_failure(bucket, destination, reason)
        {:error, reason}
    end
  end

  defp destinations(config) do
    [
      {"TopicConfigurations", "Topic", "sns", "SNS:Publish"},
      {"QueueConfigurations", "Queue", "sqs", "SQS:SendMessage"},
      {"LambdaFunctionConfigurations", "LambdaFunction", "lambda", "lambda:InvokeFunction"}
    ]
    |> Enum.flat_map(fn {list_key, arn_key, service, action} ->
      config
      |> Map.get(list_key, [])
      |> Enum.map(fn item ->
        %{
          type: arn_key,
          service: service,
          action: action,
          arn: Map.get(item, arn_key),
          id: Map.get(item, "Id")
        }
      end)
    end)
  end

  defp sns_test_message_id(validated) do
    Enum.find_value(validated, fn
      %{type: "Topic", test_message: %{message_id: message_id}} when is_binary(message_id) ->
        message_id

      _other ->
        nil
    end)
  end

  defp send_test_message(bucket, %{type: type} = destination, opts)
       when type in ["Topic", "Queue"] do
    test_destination = %{
      type: destination.type,
      arn: destination.arn,
      id: destination.id,
      events: [],
      filter: nil
    }

    AWSDelivery.deliver_test_message(bucket, test_destination, opts)
  end

  defp send_test_message(_bucket, %{type: "LambdaFunction"}, _opts), do: {:ok, nil}

  defp validate_bucket_region(%{region: region}, opts) do
    expected_region =
      Keyword.get(opts, :bucket_region) ||
        Application.get_env(:maxio, :s3, [])[:region] ||
        "us-east-1"

    if Keyword.get(opts, :validate_bucket_region?, true) and region != expected_region do
      {:error, {:destination_region_mismatch, region, expected_region}}
    else
      :ok
    end
  end

  defp validate_supported_destination_shape(%{type: type}, %{resource: resource})
       when type in ["Topic", "Queue"] do
    if String.ends_with?(resource, ".fifo") do
      {:error, {:fifo_destination_not_supported, type}}
    else
      :ok
    end
  end

  defp validate_supported_destination_shape(_destination, _arn_parts), do: :ok

  defp fetch_attributes(%{type: "Topic", arn: arn}, arn_parts, opts) do
    with {:ok, request} <-
           AWSClient.signed_form_request(
             :post,
             AWSClient.endpoint(opts, :sns, arn_parts),
             "sns",
             arn_parts.region,
             %{
               "Action" => "GetTopicAttributes",
               "Version" => @sns_version,
               "TopicArn" => arn
             },
             opts
           ),
         {:ok, body} <- AWSClient.perform_request(request, opts),
         {:ok, xml} <- ensure_binary_body(body, :sns_get_topic_attributes),
         {:ok, attributes} <- AWSQueryAttributesParser.parse(xml) do
      {:ok, attributes}
    end
  end

  defp fetch_attributes(%{type: "Queue", arn: arn}, arn_parts, opts) do
    with {:ok, queue_url} <- AWSClient.queue_url(arn, arn_parts, opts),
         {:ok, request} <-
           AWSClient.signed_json_request(
             :post,
             AWSClient.endpoint(opts, :sqs, arn_parts),
             "sqs",
             arn_parts.region,
             %{"x-amz-target" => @sqs_target, "content-type" => "application/x-amz-json-1.0"},
             %{"QueueUrl" => queue_url, "AttributeNames" => ["QueueArn", "Policy"]},
             opts
           ),
         {:ok, body} <- AWSClient.perform_request(request, opts),
         {:ok, decoded} <- decode_json_body(body, :sqs_get_queue_attributes),
         {:ok, attributes} <- fetch_map(decoded, "Attributes", :sqs_missing_attributes) do
      {:ok, attributes}
    end
  end

  defp fetch_attributes(%{type: "LambdaFunction", arn: arn}, arn_parts, opts) do
    path = "/2015-03-31/functions/#{arn}/policy"

    with {:ok, request} <-
           AWSClient.signed_request(
             :get,
             String.trim_trailing(AWSClient.endpoint(opts, :lambda, arn_parts), "/") <> path,
             "lambda",
             arn_parts.region,
             %{},
             "",
             opts
           ),
         {:ok, body} <- AWSClient.perform_request(request, opts),
         {:ok, decoded} <- decode_json_body(body, :lambda_get_policy),
         {:ok, policy} <- fetch_non_empty_binary(decoded, "Policy", :lambda_missing_policy) do
      {:ok, %{"Policy" => policy}}
    end
  end

  defp validate_identity_attribute(%{type: "Topic", arn: arn}, attributes) do
    validate_attribute_equals(attributes, "TopicArn", arn, :topic_arn_mismatch)
  end

  defp validate_identity_attribute(%{type: "Queue", arn: arn}, attributes) do
    validate_attribute_equals(attributes, "QueueArn", arn, :queue_arn_mismatch)
  end

  defp validate_identity_attribute(_destination, _attributes), do: :ok

  defp validate_attribute_equals(attributes, key, expected, reason) do
    case Map.get(attributes, key) do
      ^expected -> :ok
      nil -> {:error, {:missing_destination_attribute, key}}
      other -> {:error, {reason, other, expected}}
    end
  end

  defp decode_policy(nil, destination),
    do: {:error, {:missing_destination_policy, destination.type, destination.arn}}

  defp decode_policy("", destination),
    do: {:error, {:missing_destination_policy, destination.type, destination.arn}}

  defp decode_policy(policy, _destination) when is_map(policy), do: {:ok, policy}

  defp decode_policy(policy, _destination) when is_binary(policy) do
    case Jason.decode(policy) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      {:ok, _other} -> {:error, :destination_policy_not_object}
      {:error, reason} -> {:error, {:bad_destination_policy_json, Exception.message(reason)}}
    end
  end

  defp decode_policy(_policy, _destination), do: {:error, :destination_policy_not_object}

  defp validate_policy(bucket, destination, arn_parts, policy, opts) do
    context = %{
      principal_service: "s3.amazonaws.com",
      action: destination.action,
      resource: destination.arn,
      source_arn: "arn:#{arn_parts.partition}:s3:::#{bucket}",
      source_account: source_account(opts)
    }

    case policy_decision(policy, context) do
      :allow -> :ok
      {:deny, reason} -> {:error, {reason, destination.type, destination.arn}}
    end
  end

  defp policy_decision(policy, context) do
    statements = statements(policy)

    cond do
      Enum.any?(statements, &deny_statement_blocks?(&1, context)) ->
        {:deny, :destination_policy_explicit_deny}

      Enum.any?(statements, &allow_statement_matches?(&1, context)) ->
        :allow

      true ->
        {:deny, :destination_policy_missing_allow}
    end
  end

  defp statements(%{"Statement" => statements}) when is_list(statements), do: statements
  defp statements(%{"Statement" => statement}) when is_map(statement), do: [statement]
  defp statements(_policy), do: []

  defp deny_statement_blocks?(statement, context) when is_map(statement) do
    deny_base_matches?(statement, context) and
      conditions_result(Map.get(statement, "Condition"), context) in [:match, :unknown]
  end

  defp deny_statement_blocks?(_statement, _context), do: false

  defp allow_statement_matches?(statement, context) when is_map(statement) do
    positive_base_matches?(statement, "Allow", context) and
      conditions_result(Map.get(statement, "Condition"), context) == :match
  end

  defp allow_statement_matches?(_statement, _context), do: false

  defp deny_base_matches?(statement, context) do
    statement_effect(statement) == "Deny" and
      principal_selector_matches?(
        Map.get(statement, "Principal"),
        Map.get(statement, "NotPrincipal"),
        context.principal_service
      ) and
      action_selector_matches?(
        Map.get(statement, "Action"),
        Map.get(statement, "NotAction"),
        context.action
      ) and
      resource_selector_matches?(
        Map.get(statement, "Resource"),
        Map.get(statement, "NotResource"),
        context.resource
      )
  end

  defp positive_base_matches?(statement, effect, context) do
    statement_effect(statement) == effect and
      principal_matches?(Map.get(statement, "Principal"), context.principal_service) and
      selector_matches?(Map.get(statement, "Action"), context.action, :case_insensitive) and
      selector_matches?(Map.get(statement, "Resource"), context.resource, :case_sensitive)
  end

  defp statement_effect(statement), do: Map.get(statement, "Effect") |> to_string()

  defp principal_matches?("*", _service), do: true

  defp principal_matches?(%{"Service" => service}, expected),
    do: value_matches_any?(service, expected, :case_insensitive)

  defp principal_matches?(%{"AWS" => "*"}, _service), do: true
  defp principal_matches?(_principal, _service), do: false

  defp principal_selector_matches?(principal, nil, expected),
    do: principal_matches?(principal, expected)

  defp principal_selector_matches?(nil, not_principal, expected),
    do: not principal_matches?(not_principal, expected)

  defp principal_selector_matches?(_principal, _not_principal, _expected), do: false

  defp action_selector_matches?(action, nil, expected),
    do: selector_matches?(action, expected, :case_insensitive)

  defp action_selector_matches?(nil, not_action, expected),
    do: not selector_matches?(not_action, expected, :case_insensitive)

  defp action_selector_matches?(_action, _not_action, _expected), do: false

  defp resource_selector_matches?(resource, nil, expected),
    do: selector_matches?(resource, expected, :case_sensitive)

  defp resource_selector_matches?(nil, not_resource, expected),
    do: not selector_matches?(not_resource, expected, :case_sensitive)

  defp resource_selector_matches?(_resource, _not_resource, _expected), do: false

  defp selector_matches?(nil, _expected, _case_mode), do: false

  defp selector_matches?(selector, expected, case_mode) do
    selector
    |> listify()
    |> Enum.any?(&glob_matches?(&1, expected, case_mode))
  end

  defp value_matches_any?(value, expected, case_mode) do
    value
    |> listify()
    |> Enum.any?(fn item ->
      case case_mode do
        :case_insensitive -> String.downcase(to_string(item)) == String.downcase(expected)
        :case_sensitive -> to_string(item) == expected
      end
    end)
  end

  defp conditions_result(nil, _context), do: :match
  defp conditions_result(condition, _context) when condition == %{}, do: :match

  defp conditions_result(condition, context) when is_map(condition) do
    Enum.reduce_while(condition, :match, fn {operator, entries}, :match ->
      case condition_operator_result(to_string(operator), entries, context) do
        :match -> {:cont, :match}
        result when result in [:no_match, :unknown] -> {:halt, result}
      end
    end)
  end

  defp conditions_result(_condition, _context), do: :unknown

  defp condition_operator_result(operator, entries, context) when is_map(entries) do
    base_operator =
      operator
      |> String.replace_prefix("ForAnyValue:", "")
      |> String.replace_prefix("ForAllValues:", "")
      |> String.replace_suffix("IfExists", "")

    if supported_condition_operator?(base_operator) do
      Enum.reduce_while(entries, :match, fn {key, expected_values}, :match ->
        case condition_entry_result(base_operator, key, expected_values, context) do
          :match -> {:cont, :match}
          result when result in [:no_match, :unknown] -> {:halt, result}
        end
      end)
    else
      :unknown
    end
  end

  defp condition_operator_result(_operator, _entries, _context), do: :unknown

  defp condition_entry_result(operator, key, expected_values, context) do
    with {:ok, actual} <- condition_actual(key, context) do
      if condition_values_hold?(operator, expected_values, actual), do: :match, else: :no_match
    else
      :error -> :unknown
    end
  end

  defp supported_condition_operator?(operator),
    do: operator in ["StringEquals", "ArnEquals", "StringLike", "ArnLike"]

  defp condition_actual(key, context) do
    case String.downcase(to_string(key)) do
      "aws:sourcearn" -> {:ok, context.source_arn}
      "aws:sourceaccount" -> {:ok, context.source_account}
      "aws:sourceowner" -> {:ok, context.source_account}
      _other -> :error
    end
  end

  defp condition_values_hold?(operator, values, actual) do
    case operator do
      operator when operator in ["StringEquals", "ArnEquals"] ->
        values |> listify() |> Enum.any?(&(to_string(&1) == actual))

      operator when operator in ["StringLike", "ArnLike"] ->
        values |> listify() |> Enum.any?(&glob_matches?(&1, actual, :case_sensitive))

      _unsupported ->
        false
    end
  end

  defp decode_json_body(body, context) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      {:ok, _other} -> {:error, {:bad_aws_json_response, context, :not_object}}
      {:error, reason} -> {:error, {:bad_aws_json_response, context, Exception.message(reason)}}
    end
  end

  defp decode_json_body(body, _context) when is_map(body), do: {:ok, body}

  defp decode_json_body(_body, context),
    do: {:error, {:bad_aws_json_response, context, :not_json}}

  defp ensure_binary_body(body, _context) when is_binary(body), do: {:ok, body}
  defp ensure_binary_body(_body, context), do: {:error, {:bad_aws_response_body, context}}

  defp fetch_map(map, key, reason) do
    case Map.get(map, key) do
      value when is_map(value) -> {:ok, value}
      _other -> {:error, reason}
    end
  end

  defp fetch_non_empty_binary(map, key, reason) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, reason}
    end
  end

  defp source_account(opts) do
    Keyword.get(opts, :source_account) ||
      Keyword.get(opts, :account_id) ||
      Application.get_env(:maxio, :sts, [])[:account_id] ||
      @local_account_id
  end

  defp glob_matches?(pattern, value, :case_insensitive) do
    glob_matches?(String.downcase(to_string(pattern)), String.downcase(value), :case_sensitive)
  end

  defp glob_matches?(pattern, value, :case_sensitive) do
    pattern =
      pattern
      |> to_string()
      |> Regex.escape()
      |> String.replace("\\*", ".*")
      |> String.replace("\\?", ".")

    Regex.match?(Regex.compile!("\\A" <> pattern <> "\\z"), value)
  end

  defp listify(value) when is_list(value), do: value
  defp listify(value), do: [value]

  defp log_validation_failure(bucket, destination, reason) do
    Log.warn("bucket notification aws destination validation failed",
      action: :put_bucket_notification,
      bucket: bucket,
      destination_type: destination.type,
      destination_arn: destination.arn,
      configuration_id: destination.id,
      reason: inspect(reason)
    )
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
