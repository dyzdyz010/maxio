defmodule Maxio.S3.NotificationDestinationValidatorAWSTest do
  use ExUnit.Case, async: true

  alias Maxio.S3.NotificationDestinationValidator.AWS

  @now ~U[2026-06-28 12:00:00Z]
  @credentials [
    access_key_id: "AKIAIOSFODNN7EXAMPLE",
    secret_access_key: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
    session_token: "session-token"
  ]

  test "validates SNS topic attributes and resource policy" do
    arn = "arn:aws:sns:us-west-2:123456789012:images"
    policy = allow_policy("SNS:Publish", arn, source_arn: "arn:aws:s3:::photos")

    assert {:ok, %{count: 1, validated: [%{type: "Topic", arn: ^arn, region: "us-west-2"}]}} =
             AWS.validate(
               "photos",
               %{
                 "TopicConfigurations" => [
                   %{"Id" => "images-topic", "Topic" => arn, "Events" => ["s3:ObjectCreated:Put"]}
                 ]
               },
               opts(self(),
                 bucket_region: "us-west-2",
                 response_body: sns_attributes(arn, policy)
               )
             )

    request = assert_request()
    assert request.method == :post
    assert request.url == "https://sns.us-west-2.amazonaws.com/"
    assert header(request, "x-amz-security-token") == "session-token"
    assert header(request, "authorization") =~ "us-west-2/sns/aws4_request"

    form = URI.decode_query(request.body)
    assert form["Action"] == "GetTopicAttributes"
    assert form["Version"] == "2010-03-31"
    assert form["TopicArn"] == arn

    publish = assert_request()
    assert publish.method == :post
    assert publish.url == "https://sns.us-west-2.amazonaws.com/"
    assert header(publish, "authorization") =~ "us-west-2/sns/aws4_request"

    publish_form = URI.decode_query(publish.body)
    assert publish_form["Action"] == "Publish"
    assert publish_form["Version"] == "2010-03-31"
    assert publish_form["TopicArn"] == arn

    assert %{
             "Service" => "Amazon S3",
             "Event" => "s3:TestEvent",
             "Bucket" => "photos",
             "Time" => "2026-06-28T12:00:00Z",
             "RequestId" => request_id,
             "HostId" => host_id
           } = Jason.decode!(publish_form["Message"])

    assert is_binary(request_id)
    assert is_binary(host_id)
  end

  test "validates SQS queue attributes with derived queue URL" do
    arn = "arn:aws:sqs:eu-central-1:123456789012:images-queue"
    policy = allow_policy("SQS:SendMessage", arn, source_arn: "arn:aws:s3:::photos")

    assert {:ok, %{count: 1, validated: [%{type: "Queue", arn: ^arn}]}} =
             AWS.validate(
               "photos",
               %{
                 "QueueConfigurations" => [
                   %{"Id" => "images-queue", "Queue" => arn, "Events" => ["s3:ObjectCreated:*"]}
                 ]
               },
               opts(self(),
                 bucket_region: "eu-central-1",
                 response_body:
                   Jason.encode!(%{
                     "Attributes" => %{"QueueArn" => arn, "Policy" => policy}
                   })
               )
             )

    request = assert_request()
    assert request.url == "https://sqs.eu-central-1.amazonaws.com/"
    assert header(request, "x-amz-target") == "AmazonSQS.GetQueueAttributes"
    assert header(request, "authorization") =~ "eu-central-1/sqs/aws4_request"

    assert {:ok, body} = Jason.decode(request.body)
    assert body["QueueUrl"] == "https://sqs.eu-central-1.amazonaws.com/123456789012/images-queue"
    assert body["AttributeNames"] == ["QueueArn", "Policy"]

    send_message = assert_request()
    assert send_message.url == "https://sqs.eu-central-1.amazonaws.com/"
    assert header(send_message, "x-amz-target") == "AmazonSQS.SendMessage"
    assert header(send_message, "authorization") =~ "eu-central-1/sqs/aws4_request"

    assert {:ok, sent_body} = Jason.decode(send_message.body)

    assert sent_body["QueueUrl"] ==
             "https://sqs.eu-central-1.amazonaws.com/123456789012/images-queue"

    assert %{
             "Service" => "Amazon S3",
             "Event" => "s3:TestEvent",
             "Bucket" => "photos",
             "Time" => "2026-06-28T12:00:00Z"
           } = Jason.decode!(sent_body["MessageBody"])
  end

  test "validates Lambda function policy" do
    arn = "arn:aws:lambda:ap-southeast-1:123456789012:function:ingest"
    policy = allow_policy("lambda:InvokeFunction", arn, source_arn: "arn:aws:s3:::photos")

    assert {:ok, %{count: 1, validated: [%{type: "LambdaFunction", arn: ^arn}]}} =
             AWS.validate(
               "photos",
               %{
                 "LambdaFunctionConfigurations" => [
                   %{
                     "Id" => "ingest",
                     "LambdaFunction" => arn,
                     "Events" => ["s3:ObjectCreated:Put"]
                   }
                 ]
               },
               opts(self(),
                 bucket_region: "ap-southeast-1",
                 response_body: Jason.encode!(%{"Policy" => policy})
               )
             )

    request = assert_request()
    assert request.method == :get

    assert request.url ==
             "https://lambda.ap-southeast-1.amazonaws.com/2015-03-31/functions/#{arn}/policy"

    assert request.body == ""
    assert header(request, "authorization") =~ "ap-southeast-1/lambda/aws4_request"
    refute_receive {:aws_destination_validation_request, _request}, 50
  end

  test "fails closed when SNS or SQS test message delivery fails" do
    topic_arn = "arn:aws:sns:us-east-1:123456789012:images"
    topic_policy = allow_policy("SNS:Publish", topic_arn, source_arn: "arn:aws:s3:::photos")

    assert {:error, {:aws_http_error, 500, "publish down"}} =
             AWS.validate(
               "photos",
               %{
                 "TopicConfigurations" => [
                   %{
                     "Id" => "images-topic",
                     "Topic" => topic_arn,
                     "Events" => ["s3:ObjectCreated:Put"]
                   }
                 ]
               },
               opts(self(),
                 http_client:
                   aws_validation_client(self(), fn request ->
                     form = URI.decode_query(request.body)

                     if form["Action"] == "Publish" do
                       %{status: 500, body: "publish down"}
                     else
                       %{status: 200, body: sns_attributes(topic_arn, topic_policy)}
                     end
                   end)
               )
             )

    _attributes = assert_request()
    _publish = assert_request()

    queue_arn = "arn:aws:sqs:us-east-1:123456789012:images"
    queue_policy = allow_policy("SQS:SendMessage", queue_arn, source_arn: "arn:aws:s3:::photos")

    assert {:error, {:aws_http_error, 500, "queue down"}} =
             AWS.validate(
               "photos",
               %{
                 "QueueConfigurations" => [
                   %{"Id" => "images", "Queue" => queue_arn, "Events" => ["s3:ObjectCreated:Put"]}
                 ]
               },
               opts(self(),
                 http_client:
                   aws_validation_client(self(), fn request ->
                     case header(request, "x-amz-target") do
                       "AmazonSQS.SendMessage" ->
                         %{status: 500, body: "queue down"}

                       _attributes ->
                         %{
                           status: 200,
                           body:
                             Jason.encode!(%{
                               "Attributes" => %{
                                 "QueueArn" => queue_arn,
                                 "Policy" => queue_policy
                               }
                             })
                         }
                     end
                   end)
               )
             )

    _attributes = assert_request()
    _send = assert_request()
  end

  test "fails closed when the destination policy does not allow this bucket source" do
    arn = "arn:aws:sns:us-west-2:123456789012:images"
    policy = allow_policy("SNS:Publish", arn, source_arn: "arn:aws:s3:::other-bucket")

    assert {:error, {:destination_policy_missing_allow, "Topic", ^arn}} =
             AWS.validate(
               "photos",
               %{
                 "TopicConfigurations" => [
                   %{"Id" => "images-topic", "Topic" => arn, "Events" => ["s3:ObjectCreated:Put"]}
                 ]
               },
               opts(self(),
                 bucket_region: "us-west-2",
                 response_body: sns_attributes(arn, policy)
               )
             )

    _request = assert_request()
  end

  test "fails closed when a matching deny statement has unsupported conditions" do
    arn = "arn:aws:sns:us-west-2:123456789012:images"

    policy =
      Jason.encode!(%{
        "Version" => "2012-10-17",
        "Statement" => [
          %{
            "Effect" => "Allow",
            "Principal" => %{"Service" => "s3.amazonaws.com"},
            "Action" => "SNS:Publish",
            "Resource" => arn,
            "Condition" => %{
              "ArnLike" => %{"aws:SourceArn" => "arn:aws:s3:::photos"},
              "StringEquals" => %{"aws:SourceAccount" => "000000000000"}
            }
          },
          %{
            "Effect" => "Deny",
            "Principal" => %{"Service" => "s3.amazonaws.com"},
            "Action" => "SNS:Publish",
            "Resource" => arn,
            "Condition" => %{"StringNotEquals" => %{"aws:SourceAccount" => "999999999999"}}
          }
        ]
      })

    assert {:error, {:destination_policy_explicit_deny, "Topic", ^arn}} =
             AWS.validate(
               "photos",
               %{
                 "TopicConfigurations" => [
                   %{"Id" => "images-topic", "Topic" => arn, "Events" => ["s3:ObjectCreated:Put"]}
                 ]
               },
               opts(self(),
                 bucket_region: "us-west-2",
                 response_body: sns_attributes(arn, policy)
               )
             )

    _request = assert_request()
  end

  test "fails closed when deny statements use negative selectors" do
    arn = "arn:aws:sqs:us-east-1:123456789012:images"

    for deny_statement <- [
          %{
            "Principal" => %{"Service" => "s3.amazonaws.com"},
            "NotAction" => "SQS:GetQueueAttributes",
            "Resource" => arn
          },
          %{
            "Principal" => %{"Service" => "s3.amazonaws.com"},
            "Action" => "SQS:SendMessage",
            "NotResource" => "arn:aws:sqs:us-east-1:123456789012:other"
          },
          %{
            "NotPrincipal" => %{"Service" => "lambda.amazonaws.com"},
            "Action" => "SQS:SendMessage",
            "Resource" => arn
          }
        ] do
      policy =
        Jason.encode!(%{
          "Version" => "2012-10-17",
          "Statement" => [
            %{
              "Effect" => "Allow",
              "Principal" => %{"Service" => "s3.amazonaws.com"},
              "Action" => "SQS:SendMessage",
              "Resource" => arn,
              "Condition" => %{
                "ArnLike" => %{"aws:SourceArn" => "arn:aws:s3:::photos"},
                "StringEquals" => %{"aws:SourceAccount" => "000000000000"}
              }
            },
            Map.merge(
              %{
                "Effect" => "Deny",
                "Condition" => %{
                  "ArnLike" => %{"aws:SourceArn" => "arn:aws:s3:::photos"},
                  "StringEquals" => %{"aws:SourceAccount" => "000000000000"}
                }
              },
              deny_statement
            )
          ]
        })

      assert {:error, {:destination_policy_explicit_deny, "Queue", ^arn}} =
               AWS.validate(
                 "photos",
                 %{
                   "QueueConfigurations" => [
                     %{"Id" => "images", "Queue" => arn, "Events" => ["s3:ObjectCreated:Put"]}
                   ]
                 },
                 opts(self(),
                   response_body:
                     Jason.encode!(%{"Attributes" => %{"QueueArn" => arn, "Policy" => policy}})
                 )
               )

      _request = assert_request()
    end
  end

  test "fails closed for mismatched region, FIFO direct destinations, and AWS HTTP errors" do
    queue_arn = "arn:aws:sqs:us-east-2:123456789012:images"

    assert {:error, {:destination_region_mismatch, "us-east-2", "us-east-1"}} =
             AWS.validate(
               "photos",
               %{
                 "QueueConfigurations" => [
                   %{
                     "Id" => "images",
                     "Queue" => queue_arn,
                     "Events" => ["s3:ObjectCreated:Put"]
                   }
                 ]
               },
               opts(self())
             )

    fifo_arn = "arn:aws:sqs:us-east-1:123456789012:images.fifo"

    assert {:error, :invalid_notification_configuration} =
             AWS.validate(
               "photos",
               %{
                 "QueueConfigurations" => [
                   %{"Id" => "fifo", "Queue" => fifo_arn, "Events" => ["s3:ObjectCreated:Put"]}
                 ]
               },
               opts(self())
             )

    topic_arn = "arn:aws:sns:us-east-1:123456789012:images"

    assert {:error, {:aws_http_error, 403, "denied"}} =
             AWS.validate(
               "photos",
               %{
                 "TopicConfigurations" => [
                   %{
                     "Id" => "images-topic",
                     "Topic" => topic_arn,
                     "Events" => ["s3:ObjectCreated:Put"]
                   }
                 ]
               },
               opts(self(), response_status: 403, response_body: "denied")
             )

    _request = assert_request()
  end

  defp opts(pid, overrides \\ []) do
    Keyword.merge(
      [
        credentials: @credentials,
        now: @now,
        http_client: fn request ->
          send(pid, {:aws_destination_validation_request, request})

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

  defp aws_validation_client(pid, responder) when is_function(responder, 1) do
    fn request ->
      send(pid, {:aws_destination_validation_request, request})
      {:ok, responder.(request)}
    end
  end

  defp assert_request do
    assert_receive {:aws_destination_validation_request, request}
    request
  end

  defp header(%{headers: headers}, name) do
    headers
    |> Enum.find_value(fn {key, value} ->
      if String.downcase(to_string(key)) == name, do: value
    end)
  end

  defp allow_policy(action, resource, opts) do
    source_arn = Keyword.fetch!(opts, :source_arn)
    source_account = Keyword.get(opts, :source_account, "000000000000")

    Jason.encode!(%{
      "Version" => "2012-10-17",
      "Statement" => [
        %{
          "Effect" => "Allow",
          "Principal" => %{"Service" => "s3.amazonaws.com"},
          "Action" => action,
          "Resource" => resource,
          "Condition" => %{
            "ArnLike" => %{"aws:SourceArn" => source_arn},
            "StringEquals" => %{"aws:SourceAccount" => source_account}
          }
        }
      ]
    })
  end

  defp sns_attributes(topic_arn, policy) do
    """
    <GetTopicAttributesResponse xmlns="https://sns.amazonaws.com/doc/2010-03-31/">
      <GetTopicAttributesResult>
        <Attributes>
          <entry><key>TopicArn</key><value>#{xml_escape(topic_arn)}</value></entry>
          <entry><key>Policy</key><value>#{xml_escape(policy)}</value></entry>
        </Attributes>
      </GetTopicAttributesResult>
    </GetTopicAttributesResponse>
    """
  end

  defp xml_escape(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end
end
