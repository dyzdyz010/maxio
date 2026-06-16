defmodule Maxio.BucketConfigsTest do
  use Maxio.DataCase, async: true
  alias Maxio.BucketConfigs
  alias Maxio.Cluster.Notify

  test "put/get/delete CORS（list）" do
    assert BucketConfigs.get("b1", :cors) == :none
    rules = [%{"allowed_methods" => ["GET"], "allowed_origins" => ["*"]}]
    assert :ok = BucketConfigs.put("b1", :cors, rules)
    assert {:ok, ^rules} = BucketConfigs.get("b1", :cors)
    assert :ok = BucketConfigs.delete("b1", :cors)
    assert BucketConfigs.get("b1", :cors) == :none
  end

  test "四类配置互不干扰（同桶不同列）" do
    assert :ok = BucketConfigs.put("b2", :cors, [%{"x" => 1}])
    assert :ok = BucketConfigs.put("b2", :encryption, %{"algorithm" => "AES256"})
    assert :ok = BucketConfigs.put("b2", :public_access_block, %{"BlockPublicAcls" => true})

    assert :ok =
             BucketConfigs.put("b2", :ownership_controls, %{"ObjectOwnership" => "ObjectWriter"})

    assert :ok =
             BucketConfigs.put("b2", :website, %{"index_document" => %{"suffix" => "index.html"}})

    assert :ok = BucketConfigs.put("b2", :request_payment, %{"Payer" => "Requester"})
    assert :ok = BucketConfigs.put("b2", :accelerate, %{"Status" => "Enabled"})

    assert :ok =
             BucketConfigs.put("b2", :logging, %{
               "LoggingEnabled" => %{"TargetBucket" => "logs", "TargetPrefix" => "access/"}
             })

    assert :ok =
             BucketConfigs.put("b2", :notification, %{
               "QueueConfigurations" => [
                 %{
                   "Queue" => "arn:aws:sqs:us-east-1:000000000000:events",
                   "Events" => ["s3:ObjectCreated:*"]
                 }
               ]
             })

    assert :ok =
             BucketConfigs.put("b2", :metrics, %{
               "Configurations" => [
                 %{"Id" => "daily", "Filter" => %{"Prefix" => "logs/"}}
               ]
             })

    assert {:ok, [%{"x" => 1}]} = BucketConfigs.get("b2", :cors)
    assert {:ok, %{"algorithm" => "AES256"}} = BucketConfigs.get("b2", :encryption)
    assert {:ok, %{"BlockPublicAcls" => true}} = BucketConfigs.get("b2", :public_access_block)

    assert {:ok, %{"ObjectOwnership" => "ObjectWriter"}} =
             BucketConfigs.get("b2", :ownership_controls)

    assert {:ok, %{"index_document" => %{"suffix" => "index.html"}}} =
             BucketConfigs.get("b2", :website)

    assert {:ok, %{"Payer" => "Requester"}} = BucketConfigs.get("b2", :request_payment)
    assert {:ok, %{"Status" => "Enabled"}} = BucketConfigs.get("b2", :accelerate)

    assert {:ok, %{"LoggingEnabled" => %{"TargetBucket" => "logs"}}} =
             BucketConfigs.get("b2", :logging)

    assert {:ok,
            %{
              "QueueConfigurations" => [
                %{"Queue" => "arn:aws:sqs:us-east-1:000000000000:events"}
              ]
            }} = BucketConfigs.get("b2", :notification)

    assert {:ok, %{"Configurations" => [%{"Id" => "daily"}]}} =
             BucketConfigs.get("b2", :metrics)

    assert BucketConfigs.get("b2", :lifecycle) == :none
  end

  test "put/delete broadcast bucket config invalidation" do
    :ok = Phoenix.PubSub.subscribe(Maxio.PubSub, Notify.topic())

    assert :ok = BucketConfigs.put("b-notify", :cors, [%{"x" => 1}])
    assert_receive {:bucket_config_changed, "b-notify", :cors}

    assert :ok = BucketConfigs.delete("b-notify", :cors)
    assert_receive {:bucket_config_changed, "b-notify", :cors}

    assert :ok =
             BucketConfigs.put("b-notify", :ownership_controls, %{
               "ObjectOwnership" => "BucketOwnerPreferred"
             })

    assert_receive {:bucket_config_changed, "b-notify", :ownership_controls}

    assert :ok =
             BucketConfigs.put("b-notify", :website, %{
               "index_document" => %{"suffix" => "index.html"}
             })

    assert_receive {:bucket_config_changed, "b-notify", :website}

    assert :ok = BucketConfigs.delete("b-notify", :website)
    assert_receive {:bucket_config_changed, "b-notify", :website}

    assert :ok = BucketConfigs.put("b-notify", :request_payment, %{"Payer" => "Requester"})
    assert_receive {:bucket_config_changed, "b-notify", :request_payment}

    assert :ok = BucketConfigs.put("b-notify", :accelerate, %{"Status" => "Enabled"})
    assert_receive {:bucket_config_changed, "b-notify", :accelerate}

    assert :ok =
             BucketConfigs.put("b-notify", :logging, %{
               "LoggingEnabled" => %{"TargetBucket" => "logs", "TargetPrefix" => "access/"}
             })

    assert_receive {:bucket_config_changed, "b-notify", :logging}

    assert :ok =
             BucketConfigs.put("b-notify", :notification, %{
               "EventBridgeConfiguration" => %{}
             })

    assert_receive {:bucket_config_changed, "b-notify", :notification}

    assert :ok =
             BucketConfigs.put("b-notify", :metrics, %{
               "Configurations" => [%{"Id" => "daily"}]
             })

    assert_receive {:bucket_config_changed, "b-notify", :metrics}

    assert :ok = BucketConfigs.delete("b-notify", :metrics)
    assert_receive {:bucket_config_changed, "b-notify", :metrics}
  end
end
