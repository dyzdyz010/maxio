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
    assert {:ok, [%{"x" => 1}]} = BucketConfigs.get("b2", :cors)
    assert {:ok, %{"algorithm" => "AES256"}} = BucketConfigs.get("b2", :encryption)
    assert {:ok, %{"BlockPublicAcls" => true}} = BucketConfigs.get("b2", :public_access_block)
    assert BucketConfigs.get("b2", :lifecycle) == :none
  end

  test "put/delete broadcast bucket config invalidation" do
    :ok = Phoenix.PubSub.subscribe(Maxio.PubSub, Notify.topic())

    assert :ok = BucketConfigs.put("b-notify", :cors, [%{"x" => 1}])
    assert_receive {:bucket_config_changed, "b-notify", :cors}

    assert :ok = BucketConfigs.delete("b-notify", :cors)
    assert_receive {:bucket_config_changed, "b-notify", :cors}
  end
end
