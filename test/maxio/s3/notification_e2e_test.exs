defmodule Maxio.S3.NotificationE2ETest do
  use Maxio.DataCase, async: false

  import Plug.Conn

  alias Maxio.Auth.CredentialStore
  alias Maxio.BucketConfigs
  alias Maxio.Policy.Store
  alias Maxio.S3.Endpoint
  alias Maxio.Test.SigV4Request

  @data_dir Path.join(System.tmp_dir!(), "maxio_notification_e2e")
  @alice_ak "AKIANOTIFICATION001"
  @alice_secret "notificationnotification1234"
  @alice_arn "arn:aws:iam:::user/" <> @alice_ak

  @empty """
  <NotificationConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/" />
  """

  @queue_config """
  <NotificationConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
    <QueueConfiguration>
      <Id>images</Id>
      <Queue>arn:aws:sqs:us-east-1:000000000000:images</Queue>
      <Event>s3:ObjectCreated:*</Event>
      <Filter>
        <S3Key>
          <FilterRule><Name>prefix</Name><Value>images/</Value></FilterRule>
          <FilterRule><Name>suffix</Name><Value>.jpg</Value></FilterRule>
        </S3Key>
      </Filter>
    </QueueConfiguration>
  </NotificationConfiguration>
  """

  @event_bridge """
  <NotificationConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
    <EventBridgeConfiguration />
  </NotificationConfiguration>
  """

  setup do
    File.rm_rf(@data_dir)
    File.mkdir_p!(@data_dir)
    prev = Application.get_env(:maxio, :s3)
    Application.put_env(:maxio, :s3, Keyword.put(prev, :data_dir, @data_dir))

    :ok =
      CredentialStore.put_access_key(%{
        access_key: @alice_ak,
        secret_key: @alice_secret,
        principal: %{type: :iam_user, access_key: @alice_ak, arn: @alice_arn}
      })

    on_exit(fn ->
      Application.put_env(:maxio, :s3, prev)
      File.rm_rf(@data_dir)
    end)

    :ok
  end

  defp call(conn), do: Endpoint.call(conn, Endpoint.init([]))

  defp alice(method, path, opts) do
    SigV4Request.signed_conn(
      method,
      path,
      Keyword.merge([access_key: @alice_ak, secret: @alice_secret], opts)
    )
  end

  defp create_bucket(bucket) do
    SigV4Request.signed_conn(:put, "/#{bucket}") |> call()
  end

  defp put_notification(bucket, body, opts \\ []) do
    headers = Keyword.get(opts, :headers, [])

    SigV4Request.signed_conn(:put, "/#{bucket}",
      query: %{"notification" => ""},
      body: body,
      headers: headers
    )
    |> call()
  end

  defp content_md5(body), do: :crypto.hash(:md5, body) |> Base.encode64()

  test "GetBucketNotification returns empty default and Put round-trips stored config" do
    assert create_bucket("notifycfg").status == 200

    default =
      SigV4Request.signed_conn(:get, "/notifycfg", query: %{"notification" => ""})
      |> call()

    assert default.status == 200
    assert get_resp_header(default, "content-type") |> hd() =~ "application/xml"
    assert default.resp_body =~ "<NotificationConfiguration"
    refute default.resp_body =~ "<QueueConfiguration>"
    assert BucketConfigs.get("notifycfg", :notification) == :none

    put =
      put_notification("notifycfg", @queue_config,
        headers: [{"x-amz-skip-destination-validation", "true"}]
      )

    assert put.status == 200
    assert put.resp_body == ""

    assert {:ok, %{"QueueConfigurations" => [%{"Queue" => queue}]}} =
             BucketConfigs.get("notifycfg", :notification)

    assert queue == "arn:aws:sqs:us-east-1:000000000000:images"

    get =
      SigV4Request.signed_conn(:get, "/notifycfg", query: %{"notification" => ""})
      |> call()

    assert get.status == 200
    assert get.resp_body =~ "<QueueConfiguration>"
    assert get.resp_body =~ "<Id>images</Id>"
    assert get.resp_body =~ "<Queue>arn:aws:sqs:us-east-1:000000000000:images</Queue>"
    assert get.resp_body =~ "<Event>s3:ObjectCreated:*</Event>"
    assert get.resp_body =~ "<Name>prefix</Name>"
    assert get.resp_body =~ "<Value>.jpg</Value>"
  end

  test "empty NotificationConfiguration disables and deletes config" do
    assert create_bucket("notifydisable").status == 200

    assert put_notification("notifydisable", @queue_config,
             headers: [{"x-amz-skip-destination-validation", "true"}]
           ).status == 200

    assert {:ok, _config} = BucketConfigs.get("notifydisable", :notification)

    disabled = put_notification("notifydisable", @empty)

    assert disabled.status == 200
    assert BucketConfigs.get("notifydisable", :notification) == :none
  end

  test "non-empty config requires skip destination validation until delivery is implemented" do
    assert create_bucket("notifydelivery").status == 200

    rejected = put_notification("notifydelivery", @queue_config)

    assert rejected.status == 501
    assert rejected.resp_body =~ "NotImplemented"
    assert BucketConfigs.get("notifydelivery", :notification) == :none

    accepted =
      put_notification("notifydelivery", @event_bridge,
        headers: [{"x-amz-skip-destination-validation", "true"}]
      )

    assert accepted.status == 200

    assert {:ok, %{"EventBridgeConfiguration" => %{}}} =
             BucketConfigs.get("notifydelivery", :notification)
  end

  test "missing bucket invalid XML and semantic errors fail closed without overwriting config" do
    missing = put_notification("missing-notify", @empty)

    assert missing.status == 404
    assert missing.resp_body =~ "NoSuchBucket"

    assert create_bucket("notifybad").status == 200

    assert put_notification("notifybad", @queue_config,
             headers: [{"x-amz-skip-destination-validation", "true"}]
           ).status == 200

    bad_xml =
      put_notification(
        "notifybad",
        "<NotificationConfiguration><QueueConfiguration /></NotificationConfiguration>",
        headers: [{"x-amz-skip-destination-validation", "true"}]
      )

    assert bad_xml.status == 400
    assert bad_xml.resp_body =~ "MalformedXML"

    bad_event =
      put_notification(
        "notifybad",
        """
        <NotificationConfiguration>
          <QueueConfiguration>
            <Queue>arn:aws:sqs:us-east-1:000000000000:images</Queue>
            <Event>s3:ObjectCreated:Typo</Event>
          </QueueConfiguration>
        </NotificationConfiguration>
        """,
        headers: [{"x-amz-skip-destination-validation", "true"}]
      )

    assert bad_event.status == 400
    assert bad_event.resp_body =~ "MalformedXML"

    assert {:ok, %{"QueueConfigurations" => [%{"Id" => "images"}]}} =
             BucketConfigs.get("notifybad", :notification)
  end

  test "invalid stored notification config fails closed instead of defaulting" do
    assert create_bucket("notifystored").status == 200

    assert :ok =
             BucketConfigs.put("notifystored", :notification, %{
               "QueueConfigurations" => [
                 %{"Queue" => "arn:aws:sqs:us-east-1:000000000000:q", "Events" => []}
               ]
             })

    get =
      SigV4Request.signed_conn(:get, "/notifystored", query: %{"notification" => ""})
      |> call()

    assert get.status == 500
    assert get.resp_body =~ "InternalError"
  end

  test "PutBucketNotification validates provided Content-MD5 and flexible checksum headers" do
    assert create_bucket("notifychecksum").status == 200

    no_md5 =
      put_notification("notifychecksum", @queue_config,
        headers: [{"x-amz-skip-destination-validation", "true"}]
      )

    assert no_md5.status == 200

    bad_md5 =
      put_notification("notifychecksum", @event_bridge,
        headers: [
          {"x-amz-skip-destination-validation", "true"},
          {"content-md5", content_md5("different")}
        ]
      )

    assert bad_md5.status == 400
    assert bad_md5.resp_body =~ "BadDigest"

    missing_value =
      put_notification("notifychecksum", @event_bridge,
        headers: [
          {"x-amz-skip-destination-validation", "true"},
          {"x-amz-sdk-checksum-algorithm", "SHA256"}
        ]
      )

    assert missing_value.status == 400
    assert missing_value.resp_body =~ "InvalidRequest"

    ok_sha256 =
      put_notification("notifychecksum", @event_bridge,
        headers: [
          {"x-amz-skip-destination-validation", "true"},
          {"x-amz-sdk-checksum-algorithm", "SHA256"},
          {"x-amz-checksum-sha256", :crypto.hash(:sha256, @event_bridge) |> Base.encode64()}
        ]
      )

    assert ok_sha256.status == 200
  end

  test "checksum trailers and aws-chunked XML bodies are rejected before storing config" do
    assert create_bucket("notifychunked").status == 200

    trailer =
      put_notification("notifychunked", @event_bridge,
        headers: [
          {"x-amz-skip-destination-validation", "true"},
          {"x-amz-sdk-checksum-algorithm", "SHA256"},
          {"x-amz-trailer", "x-amz-checksum-sha256"}
        ]
      )

    assert trailer.status == 501
    assert trailer.resp_body =~ "NotImplemented"
    assert BucketConfigs.get("notifychunked", :notification) == :none

    conn =
      SigV4Request.signed_chunked_conn(:put, "/notifychunked", @event_bridge,
        query: %{"notification" => ""},
        headers: [{"x-amz-skip-destination-validation", "true"}]
      )

    rejected = call(conn)

    assert rejected.status == 501
    assert rejected.resp_body =~ "NotImplemented"
    assert BucketConfigs.get("notifychunked", :notification) == :none
  end

  test "x-amz-expected-bucket-owner is enforced on Get and Put" do
    assert create_bucket("notifyowner").status == 200

    wrong_get =
      SigV4Request.signed_conn(:get, "/notifyowner",
        query: %{"notification" => ""},
        headers: [{"x-amz-expected-bucket-owner", "999999999999"}]
      )
      |> call()

    assert wrong_get.status == 403
    assert wrong_get.resp_body =~ "AccessDenied"

    wrong_put =
      put_notification("notifyowner", @empty,
        headers: [{"x-amz-expected-bucket-owner", "999999999999"}]
      )

    assert wrong_put.status == 403
    assert wrong_put.resp_body =~ "AccessDenied"

    correct_get =
      SigV4Request.signed_conn(:get, "/notifyowner",
        query: %{"notification" => ""},
        headers: [{"x-amz-expected-bucket-owner", "000000000000"}]
      )
      |> call()

    assert correct_get.status == 200
  end

  test "object-level notification subresource and unsupported methods are method not allowed" do
    assert create_bucket("notifymethod").status == 200

    object_get =
      SigV4Request.signed_conn(:get, "/notifymethod/object.txt", query: %{"notification" => ""})
      |> call()

    assert object_get.status == 405
    assert object_get.resp_body =~ "MethodNotAllowed"

    delete =
      SigV4Request.signed_conn(:delete, "/notifymethod", query: %{"notification" => ""})
      |> call()

    assert delete.status == 405
    assert delete.resp_body =~ "MethodNotAllowed"
  end

  test "GetBucketNotification and PutBucketNotification use distinct IAM actions" do
    assert create_bucket("notifyauthz").status == 200

    get_policy =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:GetBucketNotification","Resource":"arn:aws:s3:::notifyauthz"}})

    assert :ok = Store.put_principal_policy(@alice_arn, "get-notification-only", get_policy)

    get = alice(:get, "/notifyauthz", query: %{"notification" => ""}) |> call()
    assert get.status == 200

    denied =
      alice(:put, "/notifyauthz",
        query: %{"notification" => ""},
        body: @empty
      )
      |> call()

    assert denied.status == 403
    assert denied.resp_body =~ "AccessDenied"

    put_policy =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:PutBucketNotification","Resource":"arn:aws:s3:::notifyauthz"}})

    assert :ok = Store.put_principal_policy(@alice_arn, "put-notification", put_policy)

    allowed =
      alice(:put, "/notifyauthz",
        query: %{"notification" => ""},
        body: @empty
      )
      |> call()

    assert allowed.status == 200
  end

  test "bucket resource tag condition does not grant notification actions" do
    assert create_bucket("notifynotagcond").status == 200

    tag_xml = """
    <Tagging><TagSet><Tag><Key>env</Key><Value>prod</Value></Tag></TagSet></Tagging>
    """

    assert (SigV4Request.signed_conn(:put, "/notifynotagcond",
              query: %{"tagging" => ""},
              body: tag_xml
            )
            |> call()).status == 204

    policy =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:GetBucketNotification","Resource":"arn:aws:s3:::notifynotagcond","Condition":{"StringEquals":{"aws:ResourceTag/env":"prod"}}}})

    assert :ok = Store.put_principal_policy(@alice_arn, "get-notification-resource-tag", policy)

    denied = alice(:get, "/notifynotagcond", query: %{"notification" => ""}) |> call()
    assert denied.status == 403
    assert denied.resp_body =~ "AccessDenied"
  end
end
