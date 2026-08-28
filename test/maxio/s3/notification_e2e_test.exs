defmodule Maxio.S3.NotificationE2ETest do
  use Maxio.DataCase, async: false

  import ExUnit.CaptureLog
  import Plug.Conn

  alias Maxio.Auth.CredentialStore
  alias Maxio.BucketConfigs
  alias Maxio.Policy.Store
  alias Maxio.Repo
  alias Maxio.Objects
  alias Maxio.Sidecar
  alias Maxio.Storage
  alias Maxio.Storage.Scanner
  alias Maxio.S3.{Endpoint, NotificationDelivery, NotificationOutbox, RestoreExpiry}
  alias Maxio.S3.NotificationOutbox.Event
  alias Maxio.Test.SigV4Request

  @data_dir Path.join(System.tmp_dir!(), "maxio_notification_e2e")
  @alice_ak "AKIANOTIFICATION001"
  @alice_secret "notificationnotification1234"
  @alice_arn "arn:aws:iam:::user/" <> @alice_ak
  @aws_now ~U[2026-06-28 12:00:00Z]
  @aws_credentials [
    access_key_id: "AKIAIOSFODNN7EXAMPLE",
    secret_access_key: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
  ]

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

  @mixed_event_bridge_queue """
  <NotificationConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
    <EventBridgeConfiguration />
    <QueueConfiguration>
      <Id>mixed-images</Id>
      <Queue>arn:aws:sqs:us-east-1:000000000000:mixed-images</Queue>
      <Event>s3:ObjectCreated:Put</Event>
    </QueueConfiguration>
  </NotificationConfiguration>
  """

  @remove_config """
  <NotificationConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
    <QueueConfiguration>
      <Id>removed</Id>
      <Queue>arn:aws:sqs:us-east-1:000000000000:removed</Queue>
      <Event>s3:ObjectRemoved:*</Event>
    </QueueConfiguration>
  </NotificationConfiguration>
  """

  @restore_config """
  <NotificationConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
    <QueueConfiguration>
      <Id>restore</Id>
      <Queue>arn:aws:sqs:us-east-1:000000000000:restore</Queue>
      <Event>s3:ObjectRestore:*</Event>
    </QueueConfiguration>
  </NotificationConfiguration>
  """

  setup do
    %{user_arn: @alice_arn} =
      create_user_with_access_key!(
        user_name: @alice_ak,
        access_key_id: @alice_ak,
        secret_key: @alice_secret
      )

    File.rm_rf(@data_dir)
    File.mkdir_p!(@data_dir)
    prev = Application.get_env(:maxio, :s3)
    prev_backend = Application.get_env(:maxio, :storage_backend)
    prev_notification_delivery = Application.get_env(:maxio, :notification_delivery)
    prev_authoritative_source = Application.get_env(:maxio, :authoritative_source)

    prev_notification_destination_validator =
      Application.get_env(:maxio, :notification_destination_validator)

    prev_min_part_size = Application.get_env(:maxio, :multipart_min_part_size)

    prev_notification_ledger_delete_mode =
      Application.get_env(:maxio, :notification_ledger_delete_mode)

    Application.put_env(:maxio, :s3, Keyword.put(prev, :data_dir, @data_dir))
    Application.put_env(:maxio, :authoritative_source, read: :pg, list: :pg, write: :pg)
    Application.put_env(:maxio, :multipart_min_part_size, 1)
    Application.delete_env(:maxio, :notification_delivery)
    Application.delete_env(:maxio, :notification_destination_validator)

    :ok =
      CredentialStore.put_access_key(%{
        access_key: @alice_ak,
        secret_key: @alice_secret,
        principal: %{type: :iam_user, access_key: @alice_ak, arn: @alice_arn}
      })

    on_exit(fn ->
      Application.put_env(:maxio, :s3, prev)
      restore_env(:storage_backend, prev_backend)
      restore_env(:authoritative_source, prev_authoritative_source)
      restore_env(:notification_delivery, prev_notification_delivery)
      restore_env(:notification_destination_validator, prev_notification_destination_validator)
      restore_env(:multipart_min_part_size, prev_min_part_size)
      restore_env(:notification_ledger_delete_mode, prev_notification_ledger_delete_mode)
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

  defp restore_env(key, nil), do: Application.delete_env(:maxio, key)
  defp restore_env(key, value), do: Application.put_env(:maxio, key, value)

  defp enable_notification_delivery!(pid \\ self(), opts \\ []) do
    Application.put_env(
      :maxio,
      :notification_delivery,
      [deliverer: {Maxio.Test.NotificationDeliverer, pid}, async?: false]
      |> Keyword.merge(opts)
    )
  end

  defp put_object(bucket, key, body, headers \\ []) do
    SigV4Request.signed_conn(:put, object_path(bucket, key), body: body, headers: headers)
    |> call()
  end

  defp copy_object(bucket, source_key, dest_key) do
    SigV4Request.signed_conn(:put, object_path(bucket, dest_key),
      headers: [{"x-amz-copy-source", "/#{bucket}/#{source_key}"}]
    )
    |> call()
  end

  defp delete_object(bucket, key, query \\ %{}) do
    SigV4Request.signed_conn(:delete, object_path(bucket, key), query: query)
    |> call()
  end

  defp restore_object(bucket, key, query \\ %{}) do
    body =
      ~s(<RestoreRequest><Days>3</Days><GlacierJobParameters><Tier>Standard</Tier></GlacierJobParameters></RestoreRequest>)

    SigV4Request.signed_conn(:post, object_path(bucket, key),
      query: Map.merge(%{"restore" => ""}, query),
      body: body
    )
    |> call()
  end

  defp expire_restore_now!(bucket, key) do
    {:ok, object} = Objects.get_metadata(bucket, key)
    attrs = %{restore_status: "restored", restore_expiry: ~U[2026-06-01 00:00:00Z]}

    case Application.get_env(:maxio, :authoritative_source, [])[:write] do
      :sidecar ->
        {:ok, generation} =
          Maxio.ObjectRestoreSidecar.update(bucket, key, object.version_id, attrs)

        {:ok, _object} =
          Objects.put_restore_state(bucket, key, object.version_id, attrs, generation)

      _pg ->
        {:ok, _object} = Objects.put_restore_state(bucket, key, object.version_id, attrs)
    end

    :ok
  end

  defp object_path(bucket, key), do: "/#{bucket}/#{encode_key_path(key)}"

  defp fs_sidecar(bucket, key, version_id) do
    {:ok, rel} = Maxio.Cluster.Paths.object_rel(bucket, key, version_id)

    [@data_dir, rel, "meta.json"]
    |> Path.join()
    |> File.read!()
    |> Sidecar.decode!()
  end

  defp use_fs_sidecar_write_authority! do
    Application.put_env(:maxio, :storage_backend, Maxio.Storage.FS)
    Application.put_env(:maxio, :authoritative_source, read: :pg, list: :pg, write: :sidecar)
  end

  defp assert_sidecar_ledger(bucket, key, version_id, outbox_id, event_name) do
    [entry] = fs_sidecar(bucket, key, version_id)["versions"]
    assert [%{"id" => ^outbox_id, "payload" => payload}] = entry["notification_outbox"]
    assert payload["bucket"] == bucket
    assert payload["key"] == key
    assert payload["event_name"] == event_name
    payload
  end

  defp assert_sidecar_ledger_events(bucket, key, version_id, event_names) do
    [entry] = fs_sidecar(bucket, key, version_id)["versions"]
    ledger = entry["notification_outbox"]
    assert Enum.map(ledger, &get_in(&1, ["payload", "event_name"])) == event_names
    ledger
  end

  defp encode_key_path(key) do
    key
    |> String.split("/", trim: false)
    |> Enum.map_join("/", fn segment -> URI.encode(segment, &URI.char_unreserved?/1) end)
  end

  defp delete_objects(bucket, keys) do
    objects =
      Enum.map(keys, fn key ->
        case key do
          {key, version_id} ->
            ["<Object><Key>", key, "</Key><VersionId>", version_id, "</VersionId></Object>"]

          key ->
            ["<Object><Key>", key, "</Key></Object>"]
        end
      end)

    body = IO.iodata_to_binary(["<Delete>", objects, "</Delete>"])

    SigV4Request.signed_conn(:post, "/#{bucket}", query: %{"delete" => ""}, body: body)
    |> call()
  end

  defp enable_versioning(bucket) do
    body = ~s(<VersioningConfiguration><Status>Enabled</Status></VersioningConfiguration>)

    SigV4Request.signed_conn(:put, "/#{bucket}", query: %{"versioning" => ""}, body: body)
    |> call()
  end

  defp suspend_versioning(bucket) do
    body = ~s(<VersioningConfiguration><Status>Suspended</Status></VersioningConfiguration>)

    SigV4Request.signed_conn(:put, "/#{bucket}", query: %{"versioning" => ""}, body: body)
    |> call()
  end

  defp upload_id(xml) do
    [_, rest] = String.split(xml, "<UploadId>")
    [id, _] = String.split(rest, "</UploadId>")
    id
  end

  defp initiate_upload(bucket, key) do
    init =
      SigV4Request.signed_conn(:post, "/#{bucket}/#{key}", query: %{"uploads" => ""})
      |> call()

    assert init.status == 200
    upload_id(init.resp_body)
  end

  defp upload_part(bucket, key, upload_id, part_number, body) do
    SigV4Request.signed_conn(:put, "/#{bucket}/#{key}",
      query: %{"uploadId" => upload_id, "partNumber" => Integer.to_string(part_number)},
      body: body
    )
    |> call()
  end

  defp complete_upload(bucket, key, upload_id, etags) do
    parts =
      etags
      |> Enum.with_index(1)
      |> Enum.map(fn {etag, part_number} ->
        "<Part><PartNumber>#{part_number}</PartNumber><ETag>#{etag}</ETag></Part>"
      end)

    body = IO.iodata_to_binary(["<CompleteMultipartUpload>", parts, "</CompleteMultipartUpload>"])

    SigV4Request.signed_conn(:post, "/#{bucket}/#{key}",
      query: %{"uploadId" => upload_id},
      body: body
    )
    |> call()
  end

  defp assert_object_event(event, bucket, key, event_name) do
    assert %{destination: destination, record: record, message: %{"Records" => [message_record]}} =
             event

    assert message_record == record
    assert record["eventName"] == event_name
    assert record["eventSource"] == "aws:s3"
    assert record["eventVersion"] == "2.1"
    assert record["s3"]["bucket"]["name"] == bucket
    assert record["s3"]["object"]["key"] == URI.encode_www_form(key)
    assert is_binary(record["s3"]["object"]["sequencer"])
    {destination, record}
  end

  defp assert_eventbridge_event(event, bucket, key, detail_type, reason) do
    assert %{destination: destination, message: message, record: record} = event
    assert message == record
    assert destination.type == "EventBridge"
    assert message["version"] == "0"
    assert message["source"] == "aws.s3"
    assert message["detail-type"] == detail_type
    assert message["resources"] == ["arn:aws:s3:::#{bucket}"]
    assert message["detail"]["bucket"]["name"] == bucket
    assert message["detail"]["object"]["key"] == key
    assert message["detail"]["reason"] == reason
    assert is_binary(message["detail"]["object"]["sequencer"])
    {destination, message}
  end

  defp content_md5(body), do: :crypto.hash(:md5, body) |> Base.encode64()

  defp aws_allow_policy(action, resource, source_arn) do
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
            "StringEquals" => %{"aws:SourceAccount" => "000000000000"}
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

  defp sns_publish_response(message_id) do
    """
    <PublishResponse xmlns="https://sns.amazonaws.com/doc/2010-03-31/">
      <PublishResult><MessageId>#{xml_escape(message_id)}</MessageId></PublishResult>
    </PublishResponse>
    """
  end

  defp xml_escape(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

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

  test "PutObject emits matching ObjectCreated notifications and filters non-matching keys" do
    assert create_bucket("notifyputevent").status == 200

    assert put_notification("notifyputevent", @queue_config,
             headers: [{"x-amz-skip-destination-validation", "true"}]
           ).status == 200

    enable_notification_delivery!()

    assert put_object("notifyputevent", "images/cat photo.jpg", "cat").status == 200

    assert_receive {:maxio_notification, event}

    {destination, record} =
      assert_object_event(event, "notifyputevent", "images/cat photo.jpg", "ObjectCreated:Put")

    assert destination.type == "Queue"
    assert destination.id == "images"
    assert destination.arn == "arn:aws:sqs:us-east-1:000000000000:images"
    assert record["s3"]["configurationId"] == "images"
    assert record["s3"]["object"]["size"] == 3
    assert is_binary(record["s3"]["object"]["eTag"])
    assert record["s3"]["object"]["key"] == "images%2Fcat+photo.jpg"

    assert put_object("notifyputevent", "docs/cat.jpg", "cat").status == 200
    refute_receive {:maxio_notification, _event}, 50
  end

  test "notifications persist to outbox and drain later when no deliverer is configured" do
    assert create_bucket("notifyoutbox").status == 200

    assert put_notification("notifyoutbox", @queue_config,
             headers: [{"x-amz-skip-destination-validation", "true"}]
           ).status == 200

    assert put_object("notifyoutbox", "images/outbox.jpg", "queued").status == 200
    refute_receive {:maxio_notification, _event}, 50

    assert [
             %{
               bucket: "notifyoutbox",
               object_key: "images/outbox.jpg",
               event_name: "s3:ObjectCreated:Put",
               destination_type: "Queue",
               status: "pending",
               attempts: 0
             } = row
           ] = NotificationOutbox.list(status: "pending")

    enable_notification_delivery!()

    assert {:ok, %{claimed: 1, delivered: 1, failed: 0}} = NotificationDelivery.drain()
    assert_receive {:maxio_notification, event}

    {_destination, record} =
      assert_object_event(event, "notifyoutbox", "images/outbox.jpg", "ObjectCreated:Put")

    assert record["s3"]["object"]["size"] == byte_size("queued")

    delivered = NotificationOutbox.get!(row.id)
    assert delivered.status == "delivered"
    assert delivered.attempts == 1
    assert delivered.delivered_at
  end

  test "sidecar write authority stores notification ledger and scanner replays deleted outbox row" do
    use_fs_sidecar_write_authority!()

    bucket = "notifysidecarledger"
    key = "images/ledger.jpg"

    assert create_bucket(bucket).status == 200

    assert put_notification(bucket, @queue_config,
             headers: [{"x-amz-skip-destination-validation", "true"}]
           ).status == 200

    assert put_object(bucket, key, "sidecar notification").status == 200

    assert [
             %{
               id: outbox_id,
               bucket: ^bucket,
               object_key: ^key,
               event_name: "s3:ObjectCreated:Put",
               status: "pending"
             }
           ] = NotificationOutbox.list(status: "pending")

    assert_sidecar_ledger(bucket, key, "null", outbox_id, "s3:ObjectCreated:Put")

    {1, _} = Repo.delete_all(Event)
    assert NotificationOutbox.list(status: "pending") == []

    assert {:ok, report} = Scanner.run_once(bucket: bucket)
    assert report.status == :ok
    assert report.notification_replayed == 1
    assert report.notification_replay_failed == 0

    assert [%{id: ^outbox_id, status: "pending"}] = NotificationOutbox.list(status: "pending")
  end

  test "sidecar write authority stores CopyObject ledger and replays it online" do
    use_fs_sidecar_write_authority!()

    bucket = "notifysidecarcopy"
    key = "images/copy.jpg"

    assert create_bucket(bucket).status == 200
    assert put_object(bucket, "src.txt", "copy source").status == 200

    assert put_notification(bucket, @queue_config,
             headers: [{"x-amz-skip-destination-validation", "true"}]
           ).status == 200

    assert copy_object(bucket, "src.txt", key).status == 200

    assert [
             %{
               id: outbox_id,
               bucket: ^bucket,
               object_key: ^key,
               event_name: "s3:ObjectCreated:Copy",
               status: "pending"
             }
           ] = NotificationOutbox.list(status: "pending")

    assert_sidecar_ledger(bucket, key, "null", outbox_id, "s3:ObjectCreated:Copy")
  end

  test "sidecar write authority stores CompleteMultipartUpload ledger and replays it online" do
    use_fs_sidecar_write_authority!()

    bucket = "notifysidecarmpu"
    key = "images/big.jpg"

    assert create_bucket(bucket).status == 200

    assert put_notification(bucket, @queue_config,
             headers: [{"x-amz-skip-destination-validation", "true"}]
           ).status == 200

    upload_id = initiate_upload(bucket, key)
    part = upload_part(bucket, key, upload_id, 1, "multipart sidecar bytes")
    assert part.status == 200
    [etag] = get_resp_header(part, "etag")

    complete = complete_upload(bucket, key, upload_id, [etag])
    assert complete.status == 200

    assert [
             %{
               id: outbox_id,
               bucket: ^bucket,
               object_key: ^key,
               event_name: "s3:ObjectCreated:CompleteMultipartUpload",
               status: "pending"
             }
           ] = NotificationOutbox.list(status: "pending")

    assert_sidecar_ledger(
      bucket,
      key,
      "null",
      outbox_id,
      "s3:ObjectCreated:CompleteMultipartUpload"
    )
  end

  test "sidecar write authority stores DeleteMarkerCreated ledger and replays it online" do
    use_fs_sidecar_write_authority!()

    bucket = "notifysidecardm"
    key = "doc.txt"

    assert create_bucket(bucket).status == 200
    assert enable_versioning(bucket).status == 200
    assert put_object(bucket, key, "old bytes").status == 200

    assert put_notification(bucket, @remove_config,
             headers: [{"x-amz-skip-destination-validation", "true"}]
           ).status == 200

    delete = delete_object(bucket, key)
    assert delete.status == 204
    [marker_version_id] = get_resp_header(delete, "x-amz-version-id")

    assert [
             %{
               id: outbox_id,
               bucket: ^bucket,
               object_key: ^key,
               event_name: "s3:ObjectRemoved:DeleteMarkerCreated",
               status: "pending"
             }
           ] = NotificationOutbox.list(status: "pending")

    assert_sidecar_ledger(
      bucket,
      key,
      marker_version_id,
      outbox_id,
      "s3:ObjectRemoved:DeleteMarkerCreated"
    )
  end

  test "failed outbox deliveries remain retryable and can drain successfully later" do
    assert create_bucket("notifyretry").status == 200

    assert put_notification("notifyretry", @queue_config,
             headers: [{"x-amz-skip-destination-validation", "true"}]
           ).status == 200

    assert put_object("notifyretry", "images/retry.jpg", "retry").status == 200
    assert [%{status: "pending"} = row] = NotificationOutbox.list(status: "pending")

    pid = self()

    Application.put_env(:maxio, :notification_delivery,
      deliverer: fn event ->
        send(pid, {:maxio_notification_attempt, event})
        {:error, :destination_down}
      end
    )

    assert {:ok, %{claimed: 1, delivered: 0, failed: 1}} =
             NotificationDelivery.drain(failure_backoff_ms: 0)

    assert_receive {:maxio_notification_attempt, failed_event}

    {_destination, _record} =
      assert_object_event(failed_event, "notifyretry", "images/retry.jpg", "ObjectCreated:Put")

    failed = NotificationOutbox.get!(row.id)
    assert failed.status == "failed"
    assert failed.attempts == 1
    assert failed.error_reason =~ "destination_down"

    enable_notification_delivery!()

    assert {:ok, %{claimed: 1, delivered: 1, failed: 0}} = NotificationDelivery.drain()
    assert_receive {:maxio_notification, retried_event}

    {_destination, _record} =
      assert_object_event(retried_event, "notifyretry", "images/retry.jpg", "ObjectCreated:Put")

    delivered = NotificationOutbox.get!(row.id)
    assert delivered.status == "delivered"
    assert delivered.attempts == 2
    assert delivered.delivered_at
  end

  # `Task.start/1` 永远不会返回 {:error, _}：启动失败（进程表打满）只走异常通道，实测抛
  # SystemLimitError。事件此刻已经落进 outbox，按本模块契约这类失败只应记账 + 交给 drain/1
  # 重投——绝不能穿透 deliver_enqueued/1 的 :ok 契约，把一个已经提交的对象写请求炸成 500，
  # 也绝不能被静默吞掉（AGENTS.md §3）。
  test "async delivery start failure is logged and leaves the outbox row drainable" do
    assert create_bucket("notifyasyncfail").status == 200

    assert put_notification("notifyasyncfail", @queue_config,
             headers: [{"x-amz-skip-destination-validation", "true"}]
           ).status == 200

    enable_notification_delivery!(self(),
      async?: true,
      async_start_failure_fun: fn -> raise SystemLimitError end
    )

    log =
      capture_log([level: :warning], fn ->
        # 写请求本身必须照常 200：字节和 outbox 行都已提交，投递侧失败不回滚已提交的写。
        assert put_object("notifyasyncfail", "images/async.jpg", "async").status == 200
      end)

    # 失败必须留痕，且带上真实的异常原因（结构化 reason 元数据）。
    assert log =~ "bucket notification delivery failed"
    assert log =~ "SystemLimitError"

    # 行仍是 pending，投递债务没有被吞掉，drain/1 能把它收敛掉。
    assert [%{status: "pending"} = row] = NotificationOutbox.list(status: "pending")

    enable_notification_delivery!()

    assert {:ok, %{claimed: 1, delivered: 1, failed: 0}} = NotificationDelivery.drain()
    assert_receive {:maxio_notification, event}

    {_destination, _record} =
      assert_object_event(event, "notifyasyncfail", "images/async.jpg", "ObjectCreated:Put")

    assert NotificationOutbox.get!(row.id).status == "delivered"
  end

  test "CopyObject emits ObjectCreated Copy notifications through EventBridge config" do
    assert create_bucket("notifycopyevent").status == 200
    assert put_object("notifycopyevent", "src.txt", "copy source").status == 200

    assert put_notification("notifycopyevent", @event_bridge,
             headers: [{"x-amz-skip-destination-validation", "true"}]
           ).status == 200

    enable_notification_delivery!()

    assert copy_object("notifycopyevent", "src.txt", "copy.txt").status == 200

    assert_receive {:maxio_notification, event}

    {destination, message} =
      assert_eventbridge_event(
        event,
        "notifycopyevent",
        "copy.txt",
        "Object Created",
        "CopyObject"
      )

    assert destination.arn == nil
    assert message["detail"]["object"]["size"] == byte_size("copy source")
  end

  test "CompleteMultipartUpload emits ObjectCreated CompleteMultipartUpload notification" do
    assert create_bucket("notifympuevent").status == 200

    assert put_notification("notifympuevent", @event_bridge,
             headers: [{"x-amz-skip-destination-validation", "true"}]
           ).status == 200

    enable_notification_delivery!()

    upload_id = initiate_upload("notifympuevent", "big.bin")
    part = upload_part("notifympuevent", "big.bin", upload_id, 1, "multipart notification")

    assert part.status == 200

    etag = part |> get_resp_header("etag") |> hd()

    complete = complete_upload("notifympuevent", "big.bin", upload_id, [etag])
    assert complete.status == 200

    assert_receive {:maxio_notification, event}

    {destination, message} =
      assert_eventbridge_event(
        event,
        "notifympuevent",
        "big.bin",
        "Object Created",
        "CompleteMultipartUpload"
      )

    assert destination.type == "EventBridge"
    assert message["detail"]["object"]["size"] == byte_size("multipart notification")
  end

  test "DeleteObject emits ObjectRemoved Delete only when an object existed" do
    assert create_bucket("notifydeleteevent").status == 200
    assert put_object("notifydeleteevent", "old.txt", "old").status == 200

    assert put_notification("notifydeleteevent", @remove_config,
             headers: [{"x-amz-skip-destination-validation", "true"}]
           ).status == 200

    enable_notification_delivery!()

    assert delete_object("notifydeleteevent", "old.txt").status == 204

    assert_receive {:maxio_notification, event}

    {destination, record} =
      assert_object_event(event, "notifydeleteevent", "old.txt", "ObjectRemoved:Delete")

    assert destination.type == "Queue"
    assert destination.id == "removed"
    assert record["s3"]["configurationId"] == "removed"
    assert record["s3"]["object"]["size"] == 3

    assert delete_object("notifydeleteevent", "missing.txt").status == 204
    refute_receive {:maxio_notification, _event}, 50
  end

  test "versioned DeleteObject emits DeleteMarkerCreated and version delete emits Delete" do
    assert create_bucket("notifyversiondelete").status == 200
    assert enable_versioning("notifyversiondelete").status == 200
    assert put_object("notifyversiondelete", "doc.txt", "doc").status == 200

    assert put_notification("notifyversiondelete", @remove_config,
             headers: [{"x-amz-skip-destination-validation", "true"}]
           ).status == 200

    enable_notification_delivery!()

    marker = delete_object("notifyversiondelete", "doc.txt")
    assert marker.status == 204
    [marker_version_id] = get_resp_header(marker, "x-amz-version-id")

    assert_receive {:maxio_notification, marker_event}

    {_destination, marker_record} =
      assert_object_event(
        marker_event,
        "notifyversiondelete",
        "doc.txt",
        "ObjectRemoved:DeleteMarkerCreated"
      )

    assert marker_record["s3"]["object"]["versionId"] == marker_version_id

    deleted_marker =
      delete_object("notifyversiondelete", "doc.txt", %{"versionId" => marker_version_id})

    assert deleted_marker.status == 204

    assert_receive {:maxio_notification, delete_event}

    {_destination, delete_record} =
      assert_object_event(delete_event, "notifyversiondelete", "doc.txt", "ObjectRemoved:Delete")

    assert delete_record["s3"]["object"]["versionId"] == marker_version_id
  end

  test "DeleteObjects emits ObjectRemoved only for keys actually deleted" do
    assert create_bucket("notifybatchdelete").status == 200
    assert put_object("notifybatchdelete", "present.txt", "present").status == 200

    assert put_notification("notifybatchdelete", @remove_config,
             headers: [{"x-amz-skip-destination-validation", "true"}]
           ).status == 200

    enable_notification_delivery!()

    deleted = delete_objects("notifybatchdelete", ["present.txt", "missing.txt"])
    assert deleted.status == 200

    assert_receive {:maxio_notification, event}

    {_destination, record} =
      assert_object_event(event, "notifybatchdelete", "present.txt", "ObjectRemoved:Delete")

    assert record["s3"]["object"]["size"] == byte_size("present")
    refute_receive {:maxio_notification, _event}, 50
  end

  test "DeleteObjects uses PG delete target for notifications under split read/write authority" do
    assert create_bucket("notifysplitbatch").status == 200
    assert put_object("notifysplitbatch", "stale.txt", "stale").status == 200
    assert put_object("notifysplitbatch", "fresh.txt", "fresh").status == 200

    assert put_notification("notifysplitbatch", @remove_config,
             headers: [{"x-amz-skip-destination-validation", "true"}]
           ).status == 200

    enable_notification_delivery!()
    assert :ok = Storage.delete("notifysplitbatch", "stale.txt", "null", [])
    Application.put_env(:maxio, :authoritative_source, read: :sidecar, list: :pg, write: :pg)

    deleted = delete_objects("notifysplitbatch", ["stale.txt", "fresh.txt"])
    assert deleted.status == 200
    assert deleted.resp_body =~ "<Key>stale.txt</Key>"
    assert deleted.resp_body =~ "<Key>fresh.txt</Key>"

    assert_receive {:maxio_notification, event1}
    assert_receive {:maxio_notification, event2}

    assert %{record: record1} = event1
    assert %{record: record2} = event2
    assert record1["eventName"] == "ObjectRemoved:Delete"
    assert record2["eventName"] == "ObjectRemoved:Delete"
    assert record1["s3"]["bucket"]["name"] == "notifysplitbatch"
    assert record2["s3"]["bucket"]["name"] == "notifysplitbatch"

    assert MapSet.new([record1["s3"]["object"]["key"], record2["s3"]["object"]["key"]]) ==
             MapSet.new(["stale.txt", "fresh.txt"])
  end

  test "version delete uses PG version target for notifications under split read/write authority" do
    assert create_bucket("notifysplitversion").status == 200
    assert enable_versioning("notifysplitversion").status == 200

    put = put_object("notifysplitversion", "doc.txt", "version bytes")
    assert put.status == 200
    [version_id] = get_resp_header(put, "x-amz-version-id")

    assert put_notification("notifysplitversion", @remove_config,
             headers: [{"x-amz-skip-destination-validation", "true"}]
           ).status == 200

    enable_notification_delivery!()
    assert :ok = Storage.delete("notifysplitversion", "doc.txt", version_id, [])
    Application.put_env(:maxio, :authoritative_source, read: :sidecar, list: :pg, write: :pg)

    delete = delete_object("notifysplitversion", "doc.txt", %{"versionId" => version_id})
    assert delete.status == 204

    assert_receive {:maxio_notification, event}

    {_destination, record} =
      assert_object_event(event, "notifysplitversion", "doc.txt", "ObjectRemoved:Delete")

    assert record["s3"]["object"]["versionId"] == version_id

    assert Objects.get_version("notifysplitversion", "doc.txt", version_id) ==
             {:error, :not_found}
  end

  test "EventBridge ObjectRemoved events include deletion detail fields" do
    assert create_bucket("notifyeventbridgedelete").status == 200
    assert put_object("notifyeventbridgedelete", "old.txt", "old").status == 200

    assert put_notification("notifyeventbridgedelete", @event_bridge,
             headers: [{"x-amz-skip-destination-validation", "true"}]
           ).status == 200

    enable_notification_delivery!()

    assert delete_object("notifyeventbridgedelete", "old.txt").status == 204

    assert_receive {:maxio_notification, hard_delete_event}

    {_destination, hard_delete_message} =
      assert_eventbridge_event(
        hard_delete_event,
        "notifyeventbridgedelete",
        "old.txt",
        "Object Deleted",
        "DeleteObject"
      )

    assert hard_delete_message["detail"]["deletion-type"] == "Permanently Deleted"

    assert create_bucket("notifyeventbridgemarker").status == 200
    assert enable_versioning("notifyeventbridgemarker").status == 200
    assert put_object("notifyeventbridgemarker", "doc.txt", "doc").status == 200

    assert put_notification("notifyeventbridgemarker", @event_bridge,
             headers: [{"x-amz-skip-destination-validation", "true"}]
           ).status == 200

    marker = delete_object("notifyeventbridgemarker", "doc.txt")
    assert marker.status == 204

    assert_receive {:maxio_notification, marker_event}

    {_destination, marker_message} =
      assert_eventbridge_event(
        marker_event,
        "notifyeventbridgemarker",
        "doc.txt",
        "Object Deleted",
        "DeleteObject"
      )

    assert marker_message["detail"]["deletion-type"] == "Delete Marker Created"
  end

  test "RestoreObject emits ObjectRestore Post and Completed notifications" do
    bucket = "notifyrestore"
    key = "cold.txt"

    assert create_bucket(bucket).status == 200

    assert put_notification(bucket, @restore_config,
             headers: [{"x-amz-skip-destination-validation", "true"}]
           ).status == 200

    enable_notification_delivery!()

    assert put_object(bucket, key, "cold bytes", [{"x-amz-storage-class", "GLACIER"}]).status ==
             200

    restore = restore_object(bucket, key)
    assert restore.status == 202

    assert_receive {:maxio_notification, post_event}

    {_destination, post_record} =
      assert_object_event(post_event, bucket, key, "ObjectRestore:Post")

    assert post_record["s3"]["object"]["size"] == byte_size("cold bytes")

    assert_receive {:maxio_notification, completed_event}

    {_destination, completed_record} =
      assert_object_event(completed_event, bucket, key, "ObjectRestore:Completed")

    assert completed_record["s3"]["object"]["eTag"]

    second = restore_object(bucket, key)
    assert second.status == 200

    assert_receive {:maxio_notification, second_post_event}
    assert_object_event(second_post_event, bucket, key, "ObjectRestore:Post")
    refute_receive {:maxio_notification, _event}, 50
  end

  test "RestoreObject emits EventBridge restore detail mapping" do
    bucket = "notifyrestorebridge"
    key = "archive/cold.txt"

    assert create_bucket(bucket).status == 200

    assert put_object(bucket, key, "cold bytes", [{"x-amz-storage-class", "DEEP_ARCHIVE"}]).status ==
             200

    assert put_notification(bucket, @event_bridge).status == 200
    enable_notification_delivery!()

    restore = restore_object(bucket, key)
    assert restore.status == 202

    assert_receive {:maxio_notification, post_event}

    {_destination, post_message} =
      assert_eventbridge_event(
        post_event,
        bucket,
        key,
        "Object Restore Initiated",
        "RestoreObject"
      )

    refute Map.has_key?(post_message["detail"], "restore-expiry-time")
    assert post_message["detail"]["source-storage-class"] == "DEEP_ARCHIVE"

    assert_receive {:maxio_notification, completed_event}

    {_destination, completed_message} =
      assert_eventbridge_event(
        completed_event,
        bucket,
        key,
        "Object Restore Completed",
        nil
      )

    assert completed_message["detail"]["restore-expiry-time"]
    assert completed_message["detail"]["source-storage-class"] == "DEEP_ARCHIVE"
  end

  test "restore expiry emits ObjectRestore Delete notifications" do
    bucket = "notifyrestoreexpire"
    key = "cold.txt"

    assert create_bucket(bucket).status == 200

    assert put_notification(bucket, @restore_config,
             headers: [{"x-amz-skip-destination-validation", "true"}]
           ).status == 200

    assert put_object(bucket, key, "cold bytes", [{"x-amz-storage-class", "GLACIER"}]).status ==
             200

    assert restore_object(bucket, key).status == 202
    expire_restore_now!(bucket, key)

    enable_notification_delivery!()
    summary = RestoreExpiry.run(bucket: bucket, now: ~U[2026-06-28 00:00:00Z])
    assert %{scanned: 1, expired: 1, failed: 0} = summary

    assert_receive {:maxio_notification, event}

    {_destination, record} =
      assert_object_event(event, bucket, key, "ObjectRestore:Delete")

    assert record["s3"]["object"]["eTag"]
  end

  test "restore expiry emits EventBridge Object Restore Expired detail" do
    bucket = "notifyrestoreexpirebridge"
    key = "archive/cold.txt"

    assert create_bucket(bucket).status == 200

    assert put_object(bucket, key, "cold bytes", [{"x-amz-storage-class", "DEEP_ARCHIVE"}]).status ==
             200

    assert put_notification(bucket, @event_bridge).status == 200
    assert restore_object(bucket, key).status == 202
    expire_restore_now!(bucket, key)

    enable_notification_delivery!()
    summary = RestoreExpiry.run(bucket: bucket, now: ~U[2026-06-28 00:00:00Z])
    assert %{scanned: 1, expired: 1, failed: 0} = summary

    assert_receive {:maxio_notification, event}

    {_destination, message} =
      assert_eventbridge_event(event, bucket, key, "Object Restore Expired", nil)

    refute Map.has_key?(message["detail"], "source-storage-class")
    refute Map.has_key?(message["detail"], "restore-expiry-time")
  end

  test "sidecar write authority stores RestoreObject notification ledger and replays it online" do
    use_fs_sidecar_write_authority!()

    bucket = "notifysidecarrestore"
    key = "cold.txt"

    assert create_bucket(bucket).status == 200

    assert put_notification(bucket, @restore_config,
             headers: [{"x-amz-skip-destination-validation", "true"}]
           ).status == 200

    assert put_object(bucket, key, "cold bytes", [{"x-amz-storage-class", "GLACIER"}]).status ==
             200

    restore = restore_object(bucket, key)
    assert restore.status == 202

    pending = NotificationOutbox.list(status: "pending")

    assert Enum.sort(Enum.map(pending, & &1.event_name)) == [
             "s3:ObjectRestore:Completed",
             "s3:ObjectRestore:Post"
           ]

    assert_sidecar_ledger_events(bucket, key, "null", [
      "s3:ObjectRestore:Post",
      "s3:ObjectRestore:Completed"
    ])
  end

  test "sidecar write authority expires RestoreObject state and emits Delete notification" do
    use_fs_sidecar_write_authority!()

    bucket = "notifysidecarrestoreexpire"
    key = "cold.txt"

    assert create_bucket(bucket).status == 200

    assert put_notification(bucket, @restore_config,
             headers: [{"x-amz-skip-destination-validation", "true"}]
           ).status == 200

    assert put_object(bucket, key, "cold bytes", [{"x-amz-storage-class", "GLACIER"}]).status ==
             200

    assert restore_object(bucket, key).status == 202
    expire_restore_now!(bucket, key)
    {2, _} = Repo.delete_all(Event)

    summary = RestoreExpiry.run(bucket: bucket, now: ~U[2026-06-28 00:00:00Z])
    assert %{scanned: 1, expired: 1, stale: 0, failed: 0} = summary

    assert [%{event_name: "s3:ObjectRestore:Delete", status: "pending", payload: payload}] =
             NotificationOutbox.list()

    event = NotificationOutbox.payload_to_event(payload)
    assert_object_event(event, bucket, key, "ObjectRestore:Delete")

    assert_sidecar_ledger_events(bucket, key, "null", [
      "s3:ObjectRestore:Post",
      "s3:ObjectRestore:Completed",
      "s3:ObjectRestore:Delete"
    ])

    {:ok, object} = Objects.get_metadata(bucket, key)
    assert object.restore_status == nil
    assert object.restore_expiry == nil
  end

  test "sidecar restore expiry scans sidecar authority when PG restore index is stale" do
    use_fs_sidecar_write_authority!()

    bucket = "notifysidecarrestorestalepg"
    key = "cold.txt"

    assert create_bucket(bucket).status == 200

    assert put_notification(bucket, @restore_config,
             headers: [{"x-amz-skip-destination-validation", "true"}]
           ).status == 200

    assert put_object(bucket, key, "cold bytes", [{"x-amz-storage-class", "GLACIER"}]).status ==
             200

    assert restore_object(bucket, key).status == 202
    expire_restore_now!(bucket, key)

    {:ok, object} = Objects.get_metadata(bucket, key)

    {:ok, _object} =
      Objects.put_restore_state(bucket, key, object.version_id, %{
        restore_status: "restored",
        restore_expiry: ~U[2026-07-01 00:00:00Z]
      })

    {2, _} = Repo.delete_all(Event)

    summary = RestoreExpiry.run(bucket: bucket, now: ~U[2026-06-28 00:00:00Z])
    assert %{scanned: 1, expired: 1, stale: 0, failed: 0} = summary

    assert [%{event_name: "s3:ObjectRestore:Delete", status: "pending"}] =
             NotificationOutbox.list()

    {:ok, object} = Objects.get_metadata(bucket, key)
    assert object.restore_status == nil
    assert object.restore_expiry == nil
  end

  test "restore expiry retained pass replays Delete notification after sidecar state is clear" do
    use_fs_sidecar_write_authority!()

    bucket = "notifysidecarrestoreexpirekeep"
    key = "cold.txt"

    assert create_bucket(bucket).status == 200

    assert put_notification(bucket, @restore_config,
             headers: [{"x-amz-skip-destination-validation", "true"}]
           ).status == 200

    assert put_object(bucket, key, "cold bytes", [{"x-amz-storage-class", "GLACIER"}]).status ==
             200

    assert restore_object(bucket, key).status == 202
    expire_restore_now!(bucket, key)
    {2, _} = Repo.delete_all(Event)

    Application.put_env(:maxio, :storage_backend, Maxio.Test.StoragePruneFailFS)
    Application.put_env(:maxio, :notification_ledger_delete_mode, :fail)

    first = RestoreExpiry.run(bucket: bucket, now: ~U[2026-06-28 00:00:00Z])
    assert %{scanned: 1, expired: 1, stale: 0, failed: 0} = first

    assert [%{event_name: "s3:ObjectRestore:Delete", status: "pending"}] =
             NotificationOutbox.list()

    assert {:ok, retained} = Storage.list_notification_ledgers(bucket, key, [])
    assert Enum.map(retained, & &1["event_name"]) == ["s3:ObjectRestore:Delete"]

    {1, _} = Repo.delete_all(Event)
    assert NotificationOutbox.list(status: "pending") == []

    Application.put_env(:maxio, :notification_ledger_delete_mode, :delegate)

    second = RestoreExpiry.run(bucket: bucket, now: ~U[2026-06-28 00:00:00Z])
    assert %{scanned: 0, expired: 0, stale: 0, failed: 0} = second

    assert [%{event_name: "s3:ObjectRestore:Delete", status: "pending"}] =
             NotificationOutbox.list()

    assert {:ok, []} = Storage.list_notification_ledgers(bucket, key, [])
  end

  test "sidecar RestoreObject retained ledger survives prune failure and scanner replays outbox loss" do
    use_fs_sidecar_write_authority!()
    Application.put_env(:maxio, :storage_backend, Maxio.Test.StoragePruneFailFS)
    Application.put_env(:maxio, :notification_ledger_delete_mode, :fail)

    bucket = "notifysidecarrestorekeep"
    key = "cold.txt"

    assert create_bucket(bucket).status == 200

    assert put_notification(bucket, @restore_config,
             headers: [{"x-amz-skip-destination-validation", "true"}]
           ).status == 200

    assert put_object(bucket, key, "cold bytes", [{"x-amz-storage-class", "GLACIER"}]).status ==
             200

    restore = restore_object(bucket, key)
    assert restore.status == 202

    pending = NotificationOutbox.list(status: "pending")

    assert Enum.sort(Enum.map(pending, & &1.event_name)) == [
             "s3:ObjectRestore:Completed",
             "s3:ObjectRestore:Post"
           ]

    assert {:ok, retained} = Storage.list_notification_ledgers(bucket, key, [])

    assert Enum.sort(Enum.map(retained, & &1["event_name"])) == [
             "s3:ObjectRestore:Completed",
             "s3:ObjectRestore:Post"
           ]

    assert Enum.all?(retained, fn entry ->
             get_in(entry, ["commit_predicate", "type"]) == "restore_state_transition"
           end)

    assert MapSet.new(Enum.map(retained, & &1["id"])) == MapSet.new(Enum.map(pending, & &1.id))

    {2, _} = Repo.delete_all(Event)
    assert NotificationOutbox.list(status: "pending") == []

    Application.put_env(:maxio, :notification_ledger_delete_mode, :delegate)

    assert {:ok, report} = Scanner.run_once(bucket: bucket)
    assert report.notification_retained_scanned == 2
    assert report.notification_retained_pruned == 2
    assert report.notification_retained_ambiguous == 0
    assert report.notification_replay_failed == 0
    assert report.notification_replayed >= 2

    assert Enum.sort(Enum.map(NotificationOutbox.list(status: "pending"), & &1.event_name)) == [
             "s3:ObjectRestore:Completed",
             "s3:ObjectRestore:Post"
           ]

    assert {:ok, []} = Storage.list_notification_ledgers(bucket, key, [])
  end

  test "notification deliverer failures do not fail committed object writes" do
    assert create_bucket("notifydeliverfail").status == 200

    assert put_notification("notifydeliverfail", @queue_config,
             headers: [{"x-amz-skip-destination-validation", "true"}]
           ).status == 200

    Application.put_env(:maxio, :notification_delivery,
      deliverer: fn _event -> {:error, :destination_down} end,
      async?: false,
      failure_backoff_ms: 0
    )

    assert put_object("notifydeliverfail", "images/cat.jpg", "cat").status == 200

    assert [%{status: "failed", attempts: 1, error_reason: reason}] =
             NotificationOutbox.list(status: "failed")

    assert reason =~ "destination_down"
  end

  test "direct notification destinations require skip or a configured validator" do
    assert create_bucket("notifydelivery").status == 200

    rejected = put_notification("notifydelivery", @queue_config)

    assert rejected.status == 501
    assert rejected.resp_body =~ "NotImplemented"
    assert BucketConfigs.get("notifydelivery", :notification) == :none

    Application.put_env(:maxio, :notification_destination_validator,
      validator: {Maxio.Test.NotificationDestinationValidator, self()}
    )

    validated = put_notification("notifydelivery", @queue_config)

    assert validated.status == 200

    assert_receive {:maxio_notification_destination_validation, "notifydelivery", config}

    assert [%{"Queue" => "arn:aws:sqs:us-east-1:000000000000:images"}] =
             config["QueueConfigurations"]

    assert {:ok, %{"QueueConfigurations" => [%{"Id" => "images"}]}} =
             BucketConfigs.get("notifydelivery", :notification)
  end

  test "built-in AWS destination validator allows direct queue config without skip" do
    assert create_bucket("notifyawsvalidator").status == 200

    queue_arn = "arn:aws:sqs:us-east-1:000000000000:images"
    policy = aws_allow_policy("SQS:SendMessage", queue_arn, "arn:aws:s3:::notifyawsvalidator")
    pid = self()

    Application.put_env(:maxio, :notification_destination_validator,
      validator:
        {Maxio.S3.NotificationDestinationValidator.AWS,
         [
           credentials: @aws_credentials,
           now: @aws_now,
           bucket_region: "us-east-1",
           http_client: fn request ->
             send(pid, {:aws_destination_validation_request, request})

             {:ok,
              %{
                status: 200,
                body:
                  Jason.encode!(%{
                    "Attributes" => %{
                      "QueueArn" => queue_arn,
                      "Policy" => policy
                    }
                  })
              }}
           end
         ]}
    )

    accepted = put_notification("notifyawsvalidator", @queue_config)

    assert accepted.status == 200
    assert_receive {:aws_destination_validation_request, request}
    assert request.url == "https://sqs.us-east-1.amazonaws.com/"

    assert {:ok, body} = Jason.decode(request.body)
    assert body["QueueUrl"] == "https://sqs.us-east-1.amazonaws.com/000000000000/images"
    assert body["AttributeNames"] == ["QueueArn", "Policy"]

    assert_receive {:aws_destination_validation_request, test_request}
    assert test_request.url == "https://sqs.us-east-1.amazonaws.com/"
    assert Enum.any?(test_request.headers, &(&1 == {"x-amz-target", "AmazonSQS.SendMessage"}))

    assert {:ok, sent_body} = Jason.decode(test_request.body)
    assert sent_body["QueueUrl"] == "https://sqs.us-east-1.amazonaws.com/000000000000/images"

    assert %{
             "Service" => "Amazon S3",
             "Event" => "s3:TestEvent",
             "Bucket" => "notifyawsvalidator"
           } = Jason.decode!(sent_body["MessageBody"])

    assert NotificationOutbox.list() == []

    assert {:ok, %{"QueueConfigurations" => [%{"Id" => "images"}]}} =
             BucketConfigs.get("notifyawsvalidator", :notification)
  end

  test "built-in AWS validator test message failure preserves existing config" do
    assert create_bucket("notifyawstestfail").status == 200

    accepted = put_notification("notifyawstestfail", @event_bridge)
    assert accepted.status == 200

    queue_arn = "arn:aws:sqs:us-east-1:000000000000:images"
    policy = aws_allow_policy("SQS:SendMessage", queue_arn, "arn:aws:s3:::notifyawstestfail")
    pid = self()

    Application.put_env(:maxio, :notification_destination_validator,
      validator:
        {Maxio.S3.NotificationDestinationValidator.AWS,
         [
           credentials: @aws_credentials,
           now: @aws_now,
           bucket_region: "us-east-1",
           http_client: fn request ->
             send(pid, {:aws_destination_validation_request, request})

             case Enum.find_value(request.headers, fn {key, value} ->
                    if String.downcase(to_string(key)) == "x-amz-target", do: value
                  end) do
               "AmazonSQS.SendMessage" ->
                 {:ok, %{status: 500, body: "queue down"}}

               _attributes ->
                 {:ok,
                  %{
                    status: 200,
                    body:
                      Jason.encode!(%{
                        "Attributes" => %{"QueueArn" => queue_arn, "Policy" => policy}
                      })
                  }}
             end
           end
         ]}
    )

    rejected = put_notification("notifyawstestfail", @queue_config)

    assert rejected.status == 400
    assert rejected.resp_body =~ "InvalidArgument"
    assert_receive {:aws_destination_validation_request, _attributes}
    assert_receive {:aws_destination_validation_request, _test_message}

    assert NotificationOutbox.list() == []

    assert {:ok, %{"EventBridgeConfiguration" => %{}}} =
             BucketConfigs.get("notifyawstestfail", :notification)
  end

  test "single reduced redundancy topic returns SNS test message id header" do
    assert create_bucket("notifysnstestheader").status == 200

    topic_arn = "arn:aws:sns:us-east-1:000000000000:rrs"
    policy = aws_allow_policy("SNS:Publish", topic_arn, "arn:aws:s3:::notifysnstestheader")
    message_id = "11111111-2222-3333-4444-555555555555"
    pid = self()

    Application.put_env(:maxio, :notification_destination_validator,
      validator:
        {Maxio.S3.NotificationDestinationValidator.AWS,
         [
           credentials: @aws_credentials,
           now: @aws_now,
           bucket_region: "us-east-1",
           http_client: fn request ->
             send(pid, {:aws_destination_validation_request, request})
             form = URI.decode_query(request.body)

             if form["Action"] == "Publish" do
               {:ok, %{status: 200, body: sns_publish_response(message_id)}}
             else
               {:ok, %{status: 200, body: sns_attributes(topic_arn, policy)}}
             end
           end
         ]}
    )

    body = """
    <NotificationConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
      <TopicConfiguration>
        <Id>rrs</Id>
        <Topic>#{topic_arn}</Topic>
        <Event>s3:ReducedRedundancyLostObject</Event>
      </TopicConfiguration>
    </NotificationConfiguration>
    """

    accepted = put_notification("notifysnstestheader", body)

    assert accepted.status == 200
    assert get_resp_header(accepted, "x-amz-sns-test-message-id") == [message_id]
    assert_receive {:aws_destination_validation_request, _attributes}
    assert_receive {:aws_destination_validation_request, publish}

    form = URI.decode_query(publish.body)
    assert form["Action"] == "Publish"

    assert %{
             "Service" => "Amazon S3",
             "Event" => "s3:TestEvent",
             "Bucket" => "notifysnstestheader"
           } = Jason.decode!(form["Message"])

    assert NotificationOutbox.list() == []
  end

  test "EventBridge-only notification config does not require destination validation" do
    assert create_bucket("notifyeventbridgeconfig").status == 200

    Application.put_env(:maxio, :notification_destination_validator,
      validator: {Maxio.Test.NotificationDestinationValidator, self()}
    )

    accepted = put_notification("notifyeventbridgeconfig", @event_bridge)

    assert accepted.status == 200
    refute_receive {:maxio_notification_destination_validation, _, _}, 50

    assert {:ok, %{"EventBridgeConfiguration" => %{}}} =
             BucketConfigs.get("notifyeventbridgeconfig", :notification)
  end

  test "mixed EventBridge and direct destinations still validate direct destinations" do
    assert create_bucket("notifymixedvalidation").status == 200

    rejected = put_notification("notifymixedvalidation", @mixed_event_bridge_queue)

    assert rejected.status == 501
    assert rejected.resp_body =~ "NotImplemented"
    assert BucketConfigs.get("notifymixedvalidation", :notification) == :none

    Application.put_env(:maxio, :notification_destination_validator,
      validator: {Maxio.Test.NotificationDestinationValidator, self()}
    )

    accepted = put_notification("notifymixedvalidation", @mixed_event_bridge_queue)

    assert accepted.status == 200
    assert_receive {:maxio_notification_destination_validation, "notifymixedvalidation", config}
    assert config["EventBridgeConfiguration"] == %{}
    assert [%{"Id" => "mixed-images"}] = config["QueueConfigurations"]
  end

  test "destination validator failure does not overwrite existing notification config" do
    assert create_bucket("notifyvalidationfail").status == 200

    accepted =
      put_notification("notifyvalidationfail", @event_bridge)

    assert accepted.status == 200

    assert {:ok, %{"EventBridgeConfiguration" => %{}}} =
             BucketConfigs.get("notifyvalidationfail", :notification)

    Application.put_env(:maxio, :notification_destination_validator,
      validator:
        {Maxio.Test.NotificationDestinationValidator, [pid: self(), result: {:error, :denied}]}
    )

    rejected = put_notification("notifyvalidationfail", @queue_config)

    assert rejected.status == 400
    assert rejected.resp_body =~ "InvalidArgument"
    assert rejected.resp_body =~ "Unable to validate"
    assert_receive {:maxio_notification_destination_validation, "notifyvalidationfail", _config}

    assert {:ok, %{"EventBridgeConfiguration" => %{}}} =
             BucketConfigs.get("notifyvalidationfail", :notification)
  end

  test "skip destination validation bypasses configured validator" do
    assert create_bucket("notifyskipvalidator").status == 200

    Application.put_env(:maxio, :notification_destination_validator,
      validator:
        {Maxio.Test.NotificationDestinationValidator, [pid: self(), result: {:error, :denied}]}
    )

    accepted =
      put_notification("notifyskipvalidator", @queue_config,
        headers: [{"x-amz-skip-destination-validation", "true"}]
      )

    assert accepted.status == 200
    refute_receive {:maxio_notification_destination_validation, _, _}, 50

    assert {:ok, %{"QueueConfigurations" => [%{"Id" => "images"}]}} =
             BucketConfigs.get("notifyskipvalidator", :notification)
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

    too_long_filter_value = String.duplicate("a", 1025)

    invalid_configs = [
      """
      <NotificationConfiguration>
        <QueueConfiguration>
          <Queue>not-an-arn</Queue>
          <Event>s3:ObjectCreated:*</Event>
        </QueueConfiguration>
      </NotificationConfiguration>
      """,
      """
      <NotificationConfiguration>
        <QueueConfiguration>
          <Queue>arn:aws:sqs:us-east-1:000000000000:images.fifo</Queue>
          <Event>s3:ObjectCreated:*</Event>
        </QueueConfiguration>
      </NotificationConfiguration>
      """,
      """
      <NotificationConfiguration>
        <QueueConfiguration>
          <Queue>arn:aws:sqs:us-east-1:000000000000:images</Queue>
          <Event>s3:ObjectCreated:Put</Event>
          <Event>s3:ObjectCreated:Put</Event>
        </QueueConfiguration>
      </NotificationConfiguration>
      """,
      """
      <NotificationConfiguration>
        <QueueConfiguration>
          <Queue><Arn>arn:aws:sqs:us-east-1:000000000000:images</Arn></Queue>
          <Event>s3:ObjectCreated:*</Event>
        </QueueConfiguration>
      </NotificationConfiguration>
      """,
      """
      <NotificationConfiguration>
        <EventBridgeConfiguration>
          <Event>s3:ObjectCreated:*</Event>
        </EventBridgeConfiguration>
      </NotificationConfiguration>
      """,
      """
      <NotificationConfiguration>
        <QueueConfiguration>
          <Queue>arn:aws:sqs:us-east-1:000000000000:images</Queue>
          <Event>s3:ObjectCreated:*</Event>
          <Filter>
            <S3Key>
              <FilterRule><Name>prefix</Name><Value>#{too_long_filter_value}</Value></FilterRule>
            </S3Key>
          </Filter>
        </QueueConfiguration>
      </NotificationConfiguration>
      """
    ]

    Enum.each(invalid_configs, fn xml ->
      rejected =
        put_notification("notifybad", xml,
          headers: [{"x-amz-skip-destination-validation", "true"}]
        )

      assert rejected.status == 400
      assert rejected.resp_body =~ "MalformedXML"

      assert {:ok, %{"QueueConfigurations" => [%{"Id" => "images"}]}} =
               BucketConfigs.get("notifybad", :notification)
    end)
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

  test "ObjectCreated delivery fails closed when stored notification config is invalid" do
    assert create_bucket("notifystoredemit").status == 200

    assert :ok =
             BucketConfigs.put("notifystoredemit", :notification, %{
               "QueueConfigurations" => [
                 %{"Queue" => "arn:aws:sqs:us-east-1:000000000000:q", "Events" => []}
               ]
             })

    put = put_object("notifystoredemit", "images/cat.jpg", "cat")

    assert put.status == 500
    assert put.resp_body =~ "InternalError"
    assert NotificationOutbox.list() == []
    assert Objects.get_metadata("notifystoredemit", "images/cat.jpg") == {:error, :not_found}
  end

  test "CopyObject delivery fails closed before committing copied object when stored config is invalid" do
    assert create_bucket("notifystoredcopy").status == 200
    assert put_object("notifystoredcopy", "src.txt", "copy source").status == 200

    assert :ok =
             BucketConfigs.put("notifystoredcopy", :notification, %{
               "QueueConfigurations" => [
                 %{"Queue" => "arn:aws:sqs:us-east-1:000000000000:q", "Events" => []}
               ]
             })

    copy = copy_object("notifystoredcopy", "src.txt", "copy.txt")

    assert copy.status == 500
    assert copy.resp_body =~ "InternalError"
    assert NotificationOutbox.list() == []
    assert Objects.get_metadata("notifystoredcopy", "copy.txt") == {:error, :not_found}

    source = SigV4Request.signed_conn(:get, "/notifystoredcopy/src.txt") |> call()
    assert source.status == 200
    assert source.resp_body == "copy source"

    copied = SigV4Request.signed_conn(:get, "/notifystoredcopy/copy.txt") |> call()
    assert copied.status == 404
  end

  test "CompleteMultipartUpload delivery fails closed before committing object when stored config is invalid" do
    assert create_bucket("notifystoredmpu").status == 200

    upload_id = initiate_upload("notifystoredmpu", "big.bin")
    part = upload_part("notifystoredmpu", "big.bin", upload_id, 1, "multipart bytes")

    assert part.status == 200
    [etag] = get_resp_header(part, "etag")

    assert :ok =
             BucketConfigs.put("notifystoredmpu", :notification, %{
               "QueueConfigurations" => [
                 %{"Queue" => "arn:aws:sqs:us-east-1:000000000000:q", "Events" => []}
               ]
             })

    complete = complete_upload("notifystoredmpu", "big.bin", upload_id, [etag])

    assert complete.status == 500
    assert complete.resp_body =~ "InternalError"
    assert NotificationOutbox.list() == []
    assert Objects.get_metadata("notifystoredmpu", "big.bin") == {:error, :not_found}

    get = SigV4Request.signed_conn(:get, "/notifystoredmpu/big.bin") |> call()
    assert get.status == 404
  end

  test "DeleteMarkerCreated delivery fails closed before committing delete marker when stored config is invalid" do
    assert create_bucket("notifystoreddelete").status == 200
    assert enable_versioning("notifystoreddelete").status == 200

    put = put_object("notifystoreddelete", "doc.txt", "doc")
    assert put.status == 200
    [original_version_id] = get_resp_header(put, "x-amz-version-id")

    assert :ok =
             BucketConfigs.put("notifystoreddelete", :notification, %{
               "QueueConfigurations" => [
                 %{"Queue" => "arn:aws:sqs:us-east-1:000000000000:q", "Events" => []}
               ]
             })

    delete = delete_object("notifystoreddelete", "doc.txt")

    assert delete.status == 500
    assert delete.resp_body =~ "InternalError"
    assert NotificationOutbox.list() == []

    assert {:ok, object} = Objects.get_metadata("notifystoreddelete", "doc.txt")
    refute object.is_delete_marker
    assert object.version_id == original_version_id
  end

  test "Suspended DeleteMarkerCreated failure preserves null version bytes when stored config is invalid" do
    assert create_bucket("notifystoredsuspend").status == 200
    assert suspend_versioning("notifystoredsuspend").status == 200

    put = put_object("notifystoredsuspend", "doc.txt", "alive bytes")
    assert put.status == 200
    assert get_resp_header(put, "x-amz-version-id") == []

    assert :ok =
             BucketConfigs.put("notifystoredsuspend", :notification, %{
               "QueueConfigurations" => [
                 %{"Queue" => "arn:aws:sqs:us-east-1:000000000000:q", "Events" => []}
               ]
             })

    delete = delete_object("notifystoredsuspend", "doc.txt")

    assert delete.status == 500
    assert delete.resp_body =~ "InternalError"
    assert NotificationOutbox.list() == []

    assert {:ok, object} = Objects.get_version("notifystoredsuspend", "doc.txt", "null")
    refute object.is_delete_marker
    assert object.is_latest

    get = SigV4Request.signed_conn(:get, "/notifystoredsuspend/doc.txt") |> call()
    assert get.status == 200
    assert get.resp_body == "alive bytes"
  end

  test "version delete delivery fails closed before deleting object version when stored config is invalid" do
    assert create_bucket("notifystoredversiondelete").status == 200
    assert enable_versioning("notifystoredversiondelete").status == 200

    put = put_object("notifystoredversiondelete", "doc.txt", "version bytes")
    assert put.status == 200
    [version_id] = get_resp_header(put, "x-amz-version-id")

    assert :ok =
             BucketConfigs.put("notifystoredversiondelete", :notification, %{
               "QueueConfigurations" => [
                 %{"Queue" => "arn:aws:sqs:us-east-1:000000000000:q", "Events" => []}
               ]
             })

    delete = delete_object("notifystoredversiondelete", "doc.txt", %{"versionId" => version_id})

    assert delete.status == 500
    assert delete.resp_body =~ "InternalError"
    assert NotificationOutbox.list() == []

    assert {:ok, object} = Objects.get_version("notifystoredversiondelete", "doc.txt", version_id)
    refute object.is_delete_marker
    assert object.is_latest

    get =
      SigV4Request.signed_conn(:get, "/notifystoredversiondelete/doc.txt",
        query: %{"versionId" => version_id}
      )
      |> call()

    assert get.status == 200
    assert get.resp_body == "version bytes"
  end

  test "delete-marker version delete failure preserves current marker when stored config is invalid" do
    assert create_bucket("notifystoredmarkerdelete").status == 200
    assert enable_versioning("notifystoredmarkerdelete").status == 200
    assert put_object("notifystoredmarkerdelete", "doc.txt", "old bytes").status == 200

    marker = delete_object("notifystoredmarkerdelete", "doc.txt")
    assert marker.status == 204
    [marker_version_id] = get_resp_header(marker, "x-amz-version-id")

    assert :ok =
             BucketConfigs.put("notifystoredmarkerdelete", :notification, %{
               "QueueConfigurations" => [
                 %{"Queue" => "arn:aws:sqs:us-east-1:000000000000:q", "Events" => []}
               ]
             })

    delete =
      delete_object("notifystoredmarkerdelete", "doc.txt", %{"versionId" => marker_version_id})

    assert delete.status == 500
    assert delete.resp_body =~ "InternalError"
    assert NotificationOutbox.list() == []

    assert {:ok, marker_row} =
             Objects.get_version("notifystoredmarkerdelete", "doc.txt", marker_version_id)

    assert marker_row.is_delete_marker
    assert marker_row.is_latest

    get = SigV4Request.signed_conn(:get, "/notifystoredmarkerdelete/doc.txt") |> call()
    assert get.status == 404
    assert get_resp_header(get, "x-amz-delete-marker") == ["true"]
  end

  test "DeleteObjects hard delete failure preserves object when stored config is invalid" do
    assert create_bucket("notifystoredbatchhard").status == 200
    assert put_object("notifystoredbatchhard", "doc.txt", "batch bytes").status == 200

    assert :ok =
             BucketConfigs.put("notifystoredbatchhard", :notification, %{
               "QueueConfigurations" => [
                 %{"Queue" => "arn:aws:sqs:us-east-1:000000000000:q", "Events" => []}
               ]
             })

    delete = delete_objects("notifystoredbatchhard", ["doc.txt"])

    assert delete.status == 200
    assert delete.resp_body =~ "<Error>"
    assert delete.resp_body =~ "<Key>doc.txt</Key>"
    assert delete.resp_body =~ "<Code>InternalError</Code>"
    assert NotificationOutbox.list() == []

    assert {:ok, object} = Objects.get_metadata("notifystoredbatchhard", "doc.txt")
    refute object.is_delete_marker

    get = SigV4Request.signed_conn(:get, "/notifystoredbatchhard/doc.txt") |> call()
    assert get.status == 200
    assert get.resp_body == "batch bytes"
  end

  test "DeleteObjects delete-marker failure preserves current object when stored config is invalid" do
    assert create_bucket("notifystoredbatchmarker").status == 200
    assert enable_versioning("notifystoredbatchmarker").status == 200

    put = put_object("notifystoredbatchmarker", "doc.txt", "old bytes")
    assert put.status == 200
    [original_version_id] = get_resp_header(put, "x-amz-version-id")

    assert :ok =
             BucketConfigs.put("notifystoredbatchmarker", :notification, %{
               "QueueConfigurations" => [
                 %{"Queue" => "arn:aws:sqs:us-east-1:000000000000:q", "Events" => []}
               ]
             })

    delete = delete_objects("notifystoredbatchmarker", ["doc.txt"])

    assert delete.status == 200
    assert delete.resp_body =~ "<Error>"
    assert delete.resp_body =~ "<Code>InternalError</Code>"
    assert NotificationOutbox.list() == []

    assert {:ok, object} = Objects.get_metadata("notifystoredbatchmarker", "doc.txt")
    refute object.is_delete_marker
    assert object.version_id == original_version_id

    get = SigV4Request.signed_conn(:get, "/notifystoredbatchmarker/doc.txt") |> call()
    assert get.status == 200
    assert get.resp_body == "old bytes"
  end

  test "DeleteObjects version delete failure preserves version when stored config is invalid" do
    assert create_bucket("notifystoredbatchversion").status == 200
    assert enable_versioning("notifystoredbatchversion").status == 200

    put = put_object("notifystoredbatchversion", "doc.txt", "version bytes")
    assert put.status == 200
    [version_id] = get_resp_header(put, "x-amz-version-id")

    assert :ok =
             BucketConfigs.put("notifystoredbatchversion", :notification, %{
               "QueueConfigurations" => [
                 %{"Queue" => "arn:aws:sqs:us-east-1:000000000000:q", "Events" => []}
               ]
             })

    delete = delete_objects("notifystoredbatchversion", [{"doc.txt", version_id}])

    assert delete.status == 200
    assert delete.resp_body =~ "<Error>"
    assert delete.resp_body =~ "<VersionId>#{version_id}</VersionId>"
    assert delete.resp_body =~ "<Code>InternalError</Code>"
    assert NotificationOutbox.list() == []

    assert {:ok, object} = Objects.get_version("notifystoredbatchversion", "doc.txt", version_id)
    refute object.is_delete_marker
    assert object.is_latest

    get =
      SigV4Request.signed_conn(:get, "/notifystoredbatchversion/doc.txt",
        query: %{"versionId" => version_id}
      )
      |> call()

    assert get.status == 200
    assert get.resp_body == "version bytes"
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

  test "checksum trailers and aws-chunked XML bodies are validated before storing config" do
    assert create_bucket("notifychunked").status == 200

    plain_trailer =
      put_notification("notifychunked", @event_bridge,
        headers: [
          {"x-amz-skip-destination-validation", "true"},
          {"x-amz-sdk-checksum-algorithm", "SHA256"},
          {"x-amz-trailer", "x-amz-checksum-sha256"}
        ]
      )

    assert plain_trailer.status == 400
    assert plain_trailer.resp_body =~ "InvalidRequest"
    assert BucketConfigs.get("notifychunked", :notification) == :none

    bad =
      SigV4Request.signed_chunked_conn(:put, "/notifychunked", @event_bridge,
        query: %{"notification" => ""},
        headers: [
          {"x-amz-skip-destination-validation", "true"},
          {"x-amz-sdk-checksum-algorithm", "SHA256"}
        ],
        trailer_headers: [
          {"x-amz-checksum-sha256", :crypto.hash(:sha256, "different") |> Base.encode64()}
        ]
      )
      |> call()

    assert bad.status == 400
    assert bad.resp_body =~ "BadDigest"
    assert BucketConfigs.get("notifychunked", :notification) == :none

    ok =
      SigV4Request.signed_chunked_conn(:put, "/notifychunked", @event_bridge,
        query: %{"notification" => ""},
        headers: [
          {"x-amz-skip-destination-validation", "true"},
          {"x-amz-sdk-checksum-algorithm", "SHA256"}
        ],
        trailer_headers: [
          {"x-amz-checksum-sha256", :crypto.hash(:sha256, @event_bridge) |> Base.encode64()}
        ]
      )
      |> call()

    assert ok.status == 200

    assert {:ok, %{"EventBridgeConfiguration" => %{}}} =
             BucketConfigs.get("notifychunked", :notification)
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
