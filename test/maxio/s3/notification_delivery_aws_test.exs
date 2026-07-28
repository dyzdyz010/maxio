defmodule Maxio.S3.NotificationDeliveryAWSTest do
  use ExUnit.Case, async: true

  alias Maxio.S3.NotificationDelivery.AWS

  @now ~U[2026-06-24 12:00:00Z]
  @credentials [
    access_key_id: "AKIAIOSFODNN7EXAMPLE",
    secret_access_key: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
    session_token: "session-token"
  ]

  test "publishes Topic destinations to SNS Publish with SigV4" do
    opts = opts(self())

    assert :ok =
             AWS.deliver(
               event("Topic", "arn:aws:sns:us-west-2:123456789012:images"),
               opts
             )

    request = assert_request()
    assert request.method == :post
    assert request.url == "https://sns.us-west-2.amazonaws.com/"
    assert header(request, "content-type") == "application/x-www-form-urlencoded"
    assert header(request, "x-amz-security-token") == "session-token"

    assert header(request, "authorization") =~
             "Credential=AKIAIOSFODNN7EXAMPLE/20260624/us-west-2/sns/aws4_request"

    assert header(request, "authorization") =~ "x-amz-security-token"

    form = URI.decode_query(request.body)
    assert form["Action"] == "Publish"
    assert form["Version"] == "2010-03-31"
    assert form["TopicArn"] == "arn:aws:sns:us-west-2:123456789012:images"

    assert {:ok, %{"Records" => [%{"eventName" => "ObjectCreated:Put"}]}} =
             Jason.decode(form["Message"])
  end

  test "sends Queue destinations to SQS SendMessage with derived QueueUrl" do
    assert :ok =
             AWS.deliver(
               event("Queue", "arn:aws:sqs:eu-central-1:123456789012:images-queue"),
               opts(self())
             )

    request = assert_request()
    assert request.url == "https://sqs.eu-central-1.amazonaws.com/"
    assert header(request, "x-amz-target") == "AmazonSQS.SendMessage"
    assert header(request, "content-type") == "application/x-amz-json-1.0"
    assert header(request, "authorization") =~ "eu-central-1/sqs/aws4_request"

    assert {:ok, body} = Jason.decode(request.body)
    assert body["QueueUrl"] == "https://sqs.eu-central-1.amazonaws.com/123456789012/images-queue"
    assert {:ok, %{"Records" => [_record]}} = Jason.decode(body["MessageBody"])
  end

  test "derives AWS partition DNS suffixes and rejects unsupported partitions" do
    assert :ok =
             AWS.deliver(
               event("Queue", "arn:aws-cn:sqs:cn-north-1:123456789012:images-queue"),
               opts(self())
             )

    request = assert_request()
    assert request.url == "https://sqs.cn-north-1.amazonaws.com.cn/"

    assert {:ok, body} = Jason.decode(request.body)

    assert body["QueueUrl"] ==
             "https://sqs.cn-north-1.amazonaws.com.cn/123456789012/images-queue"

    assert header(request, "authorization") =~ "cn-north-1/sqs/aws4_request"

    assert {:error, {:unsupported_arn_partition, "aws-iso"}} =
             AWS.deliver(
               event("Queue", "arn:aws-iso:sqs:us-iso-east-1:123456789012:images-queue"),
               opts(self())
             )
  end

  test "invokes Lambda destinations asynchronously" do
    arn = "arn:aws:lambda:ap-southeast-1:123456789012:function:ingest"

    assert :ok = AWS.deliver(event("LambdaFunction", arn), opts(self(), response_status: 202))

    request = assert_request()

    assert request.url ==
             "https://lambda.ap-southeast-1.amazonaws.com/2015-03-31/functions/#{arn}/invocations"

    assert header(request, "x-amz-invocation-type") == "Event"
    assert header(request, "authorization") =~ "ap-southeast-1/lambda/aws4_request"
    assert {:ok, %{"Records" => [_record]}} = Jason.decode(request.body)

    assert {:error, {:aws_http_error, 200, "{}"}} =
             AWS.deliver(event("LambdaFunction", arn), opts(self(), response_status: 200))

    _bad_status_request = assert_request()
  end

  test "puts EventBridge events and checks failed entries" do
    opts =
      opts(self(),
        response_body:
          Jason.encode!(%{"FailedEntryCount" => 0, "Entries" => [%{"EventId" => "evt-1"}]}),
        event_bus_name: "default"
      )

    assert :ok = AWS.deliver(event("EventBridge", nil), opts)

    request = assert_request()
    assert request.url == "https://events.us-east-1.amazonaws.com/"
    assert header(request, "x-amz-target") == "AWSEvents.PutEvents"
    assert header(request, "authorization") =~ "us-east-1/events/aws4_request"

    assert {:ok, %{"Entries" => [entry]}} = Jason.decode(request.body)
    assert entry["Source"] == "maxio.s3"
    assert entry["DetailType"] == "Object Created"
    assert entry["Resources"] == ["arn:aws:s3:::photos"]
    assert entry["EventBusName"] == "default"
    assert {:ok, %{"bucket" => %{"name" => "photos"}}} = Jason.decode(entry["Detail"])

    failed_opts =
      opts(self(),
        response_body:
          Jason.encode!(%{
            "FailedEntryCount" => 1,
            "Entries" => [%{"ErrorCode" => "InternalFailure"}]
          })
      )

    assert {:error, {:eventbridge_failed_entries, [%{"ErrorCode" => "InternalFailure"}]}} =
             AWS.deliver(event("EventBridge", nil), failed_opts)

    _failed_request = assert_request()

    missing_event_id_opts =
      opts(self(),
        response_body: Jason.encode!(%{"FailedEntryCount" => 0, "Entries" => [%{}]})
      )

    assert {:error, {:eventbridge_missing_event_id, [%{}]}} =
             AWS.deliver(event("EventBridge", nil), missing_event_id_opts)

    _missing_event_id_request = assert_request()

    assert {:error, {:eventbridge_bad_response, %{"Entries" => []}}} =
             AWS.deliver(
               event("EventBridge", nil),
               opts(self(), response_body: Jason.encode!(%{"Entries" => []}))
             )

    _bad_response_request = assert_request()

    assert {:error, {:unsupported_arn_partition, "aws-iso"}} =
             AWS.deliver(event("EventBridge", nil), opts(self(), partition: "aws-iso"))

    custom_source_opts =
      opts(self(),
        response_body:
          Jason.encode!(%{"FailedEntryCount" => 0, "Entries" => [%{"EventId" => "evt-2"}]}),
        eventbridge_source: "com.example.maxio"
      )

    assert :ok = AWS.deliver(event("EventBridge", nil), custom_source_opts)
    custom_source_request = assert_request()
    assert {:ok, %{"Entries" => [custom_entry]}} = Jason.decode(custom_source_request.body)
    assert custom_entry["Source"] == "com.example.maxio"
  end

  test "returns structured errors for missing credentials and HTTP failures" do
    assert {:error, {:request_build_failed, message}} =
             AWS.deliver(
               event("Topic", "arn:aws:sns:us-east-1:123456789012:images"),
               credentials: [access_key_id: "", secret_access_key: ""]
             )

    assert message =~ "requires access_key_id"

    assert {:error, {:request_build_failed, lambda_message}} =
             AWS.deliver(
               event("LambdaFunction", "arn:aws:lambda:us-east-1:123456789012:function:ingest"),
               credentials: [access_key_id: "", secret_access_key: ""]
             )

    assert lambda_message =~ "requires access_key_id"

    assert {:error, {:aws_http_error, 500, "down"}} =
             AWS.deliver(
               event("Topic", "arn:aws:sns:us-east-1:123456789012:images"),
               opts(self(), response_status: 500, response_body: "down")
             )

    _request = assert_request()
  end

  defp opts(pid, overrides \\ []) do
    Keyword.merge(
      [
        credentials: @credentials,
        now: @now,
        http_client: fn request ->
          send(pid, {:aws_notification_request, request})

          {:ok,
           %{
             status: Keyword.get(overrides, :response_status, 200),
             body: Keyword.get(overrides, :response_body, "{}")
           }}
        end
      ],
      overrides
    )
  end

  defp assert_request do
    assert_receive {:aws_notification_request, request}
    request
  end

  defp header(%{headers: headers}, name) do
    headers
    |> Enum.find_value(fn {key, value} ->
      if String.downcase(to_string(key)) == name, do: value
    end)
  end

  defp event(type, arn) do
    message = %{
      "Records" => [
        %{
          "eventName" => "ObjectCreated:Put",
          "s3" => %{
            "bucket" => %{"name" => "photos"},
            "object" => %{"key" => "cat.jpg", "sequencer" => "1"}
          }
        }
      ],
      "version" => "0",
      "detail-type" => "Object Created",
      "source" => "aws.s3",
      "resources" => ["arn:aws:s3:::photos"],
      "detail" => %{
        "bucket" => %{"name" => "photos"},
        "object" => %{"key" => "cat.jpg", "sequencer" => "1"}
      }
    }

    %{
      destination: %{
        type: type,
        arn: arn,
        id: "config-1",
        events: ["s3:ObjectCreated:*"],
        filter: nil
      },
      message: message,
      record: hd(message["Records"]),
      event_name: "s3:ObjectCreated:Put",
      bucket: "photos",
      key: "cat.jpg"
    }
  end
end
