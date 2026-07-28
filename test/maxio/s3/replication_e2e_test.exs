defmodule Maxio.S3.ReplicationE2ETest do
  use Maxio.DataCase, async: false

  import ExUnit.CaptureLog
  import Plug.Conn

  alias Maxio.Auth.CredentialStore
  alias Maxio.BucketConfigs
  alias Maxio.ObjectMeta
  alias Maxio.Objects
  alias Maxio.Policy.Store
  alias Maxio.S3.{ReplicationBackfill, ReplicationDelivery, ReplicationOutbox}
  alias Maxio.S3.Endpoint
  alias Maxio.Test.SigV4Request
  alias Maxio.Versioning.VersionId

  @data_dir Path.join(System.tmp_dir!(), "maxio_replication_e2e")
  @alice_ak "AKIAREPLICATION01"
  @alice_secret "replicationreplication123"
  @alice_arn "arn:aws:iam:::user/" <> @alice_ak

  @replication """
  <ReplicationConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
    <Role>arn:aws:iam::000000000000:role/replication</Role>
    <Rule>
      <ID>logs</ID>
      <Priority>10</Priority>
      <Filter><Prefix>logs/</Prefix></Filter>
      <Status>Enabled</Status>
      <DeleteMarkerReplication><Status>Disabled</Status></DeleteMarkerReplication>
      <Destination>
        <Bucket>arn:aws:s3:::replica-dest</Bucket>
        <StorageClass>STANDARD_IA</StorageClass>
      </Destination>
    </Rule>
  </ReplicationConfiguration>
  """

  @legacy_prefix """
  <ReplicationConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
    <Role>arn:aws:iam::000000000000:role/replication</Role>
    <Rule>
      <ID>all</ID>
      <Status>Disabled</Status>
      <Prefix></Prefix>
      <Destination><Bucket>arn:aws:s3:::replica-dest</Bucket></Destination>
    </Rule>
  </ReplicationConfiguration>
  """

  @empty_filter """
  <ReplicationConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
    <Role>arn:aws:iam::000000000000:role/replication</Role>
    <Rule>
      <ID>all-v2</ID>
      <Priority>1</Priority>
      <Status>Enabled</Status>
      <Filter></Filter>
      <DeleteMarkerReplication><Status>Enabled</Status></DeleteMarkerReplication>
      <Destination><Bucket>arn:aws:s3:::replica-dest</Bucket></Destination>
    </Rule>
  </ReplicationConfiguration>
  """

  @delete_marker_replication """
  <ReplicationConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
    <Role>arn:aws:iam::000000000000:role/replication</Role>
    <Rule>
      <ID>dm</ID>
      <Priority>1</Priority>
      <Filter><Prefix>logs/</Prefix></Filter>
      <Status>Enabled</Status>
      <DeleteMarkerReplication><Status>Enabled</Status></DeleteMarkerReplication>
      <Destination><Bucket>arn:aws:s3:::replica-dest</Bucket></Destination>
    </Rule>
  </ReplicationConfiguration>
  """

  @delete_replication """
  <ReplicationConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
    <Role>arn:aws:iam::000000000000:role/replication</Role>
    <Rule>
      <ID>delete</ID>
      <Priority>1</Priority>
      <Filter><Prefix>logs/</Prefix></Filter>
      <Status>Enabled</Status>
      <DeleteMarkerReplication><Status>Disabled</Status></DeleteMarkerReplication>
      <DeleteReplication><Status>Enabled</Status></DeleteReplication>
      <Destination><Bucket>arn:aws:s3:::replica-dest</Bucket></Destination>
    </Rule>
  </ReplicationConfiguration>
  """

  @priority_replication """
  <ReplicationConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
    <Role>arn:aws:iam::000000000000:role/replication</Role>
    <Rule>
      <ID>low</ID>
      <Priority>1</Priority>
      <Filter><Prefix>logs/</Prefix></Filter>
      <Status>Enabled</Status>
      <DeleteMarkerReplication><Status>Disabled</Status></DeleteMarkerReplication>
      <Destination>
        <Bucket>arn:aws:s3:::replica-dest</Bucket>
        <StorageClass>STANDARD</StorageClass>
      </Destination>
    </Rule>
    <Rule>
      <ID>high</ID>
      <Priority>50</Priority>
      <Filter><Prefix>logs/</Prefix></Filter>
      <Status>Enabled</Status>
      <DeleteMarkerReplication><Status>Disabled</Status></DeleteMarkerReplication>
      <Destination>
        <Bucket>arn:aws:s3:::replica-dest</Bucket>
        <StorageClass>ONEZONE_IA</StorageClass>
      </Destination>
    </Rule>
  </ReplicationConfiguration>
  """

  @multi_destination_replication """
  <ReplicationConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
    <Role>arn:aws:iam::000000000000:role/replication</Role>
    <Rule>
      <ID>dst-a</ID>
      <Priority>1</Priority>
      <Filter><Prefix>logs/</Prefix></Filter>
      <Status>Enabled</Status>
      <DeleteMarkerReplication><Status>Disabled</Status></DeleteMarkerReplication>
      <Destination><Bucket>arn:aws:s3:::replica-a</Bucket></Destination>
    </Rule>
    <Rule>
      <ID>dst-b</ID>
      <Priority>2</Priority>
      <Filter><Prefix>logs/</Prefix></Filter>
      <Status>Enabled</Status>
      <DeleteMarkerReplication><Status>Disabled</Status></DeleteMarkerReplication>
      <Destination><Bucket>arn:aws:s3:::replica-b</Bucket></Destination>
    </Rule>
  </ReplicationConfiguration>
  """

  @other_role_prefix String.replace(
                       @legacy_prefix,
                       "arn:aws:iam::000000000000:role/replication",
                       "arn:aws:iam::000000000000:role/other"
                     )

  setup do
    File.rm_rf(@data_dir)
    File.mkdir_p!(@data_dir)
    prev = Application.get_env(:maxio, :s3)
    prev_authoritative_source = Application.get_env(:maxio, :authoritative_source)
    Application.put_env(:maxio, :s3, Keyword.put(prev, :data_dir, @data_dir))
    Application.put_env(:maxio, :authoritative_source, read: :pg, list: :pg, write: :pg)

    :ok =
      CredentialStore.put_access_key(%{
        access_key: @alice_ak,
        secret_key: @alice_secret,
        principal: %{type: :iam_user, access_key: @alice_ak, arn: @alice_arn}
      })

    on_exit(fn ->
      Application.put_env(:maxio, :s3, prev)
      restore_env(:authoritative_source, prev_authoritative_source)
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

  defp create_bucket(bucket), do: SigV4Request.signed_conn(:put, "/#{bucket}") |> call()

  defp enable_versioning(bucket) do
    put_versioning(bucket, "Enabled")
  end

  defp suspend_versioning(bucket) do
    put_versioning(bucket, "Suspended")
  end

  defp put_versioning(bucket, status) do
    body = "<VersioningConfiguration><Status>Enabled</Status></VersioningConfiguration>"
    body = String.replace(body, "Enabled", status)

    SigV4Request.signed_conn(:put, "/#{bucket}",
      query: %{"versioning" => ""},
      body: body
    )
    |> call()
  end

  defp put_replication(bucket, body, opts \\ []) do
    headers =
      Keyword.get(opts, :headers, [])
      |> maybe_add_content_md5(body, Keyword.get(opts, :content_md5, true))

    SigV4Request.signed_conn(:put, "/#{bucket}",
      query: %{"replication" => ""},
      body: body,
      headers: headers
    )
    |> call()
  end

  defp get_replication(bucket, opts \\ []) do
    SigV4Request.signed_conn(:get, "/#{bucket}",
      query: %{"replication" => ""},
      headers: Keyword.get(opts, :headers, [])
    )
    |> call()
  end

  defp delete_replication(bucket, opts \\ []) do
    SigV4Request.signed_conn(:delete, "/#{bucket}",
      query: %{"replication" => ""},
      headers: Keyword.get(opts, :headers, [])
    )
    |> call()
  end

  defp setup_replication_pair(source, body \\ @replication) do
    assert create_bucket(source).status == 200
    assert create_bucket("replica-dest").status == 200
    assert enable_versioning(source).status == 200
    assert enable_versioning("replica-dest").status == 200
    assert put_replication(source, body).status == 200
  end

  defp setup_multi_destination_replication(source) do
    assert create_bucket(source).status == 200
    assert create_bucket("replica-a").status == 200
    assert create_bucket("replica-b").status == 200
    assert enable_versioning(source).status == 200
    assert enable_versioning("replica-a").status == 200
    assert enable_versioning("replica-b").status == 200
    assert put_replication(source, @multi_destination_replication).status == 200
  end

  defp replication_to(bucket, body \\ @replication) do
    String.replace(body, "arn:aws:s3:::replica-dest", "arn:aws:s3:::#{bucket}")
  end

  defp put_object(bucket, key, body, opts \\ []) do
    SigV4Request.signed_conn(:put, "/#{bucket}/#{key}",
      body: body,
      headers: Keyword.get(opts, :headers, [])
    )
    |> call()
  end

  defp copy_object(bucket, key, source) do
    SigV4Request.signed_conn(:put, "/#{bucket}/#{key}", headers: [{"x-amz-copy-source", source}])
    |> call()
  end

  defp head_object(bucket, key, opts \\ []) do
    SigV4Request.signed_conn(:head, "/#{bucket}/#{key}", Keyword.take(opts, [:query]))
    |> call()
  end

  defp get_object(bucket, key, opts \\ []) do
    SigV4Request.signed_conn(:get, "/#{bucket}/#{key}", Keyword.take(opts, [:query]))
    |> call()
  end

  defp delete_object(bucket, key, opts \\ []) do
    SigV4Request.signed_conn(:delete, "/#{bucket}/#{key}", Keyword.take(opts, [:query]))
    |> call()
  end

  defp delete_objects(bucket, body) do
    SigV4Request.signed_conn(:post, "/#{bucket}", query: %{"delete" => ""}, body: body)
    |> call()
  end

  defp initiate_multipart(bucket, key) do
    SigV4Request.signed_conn(:post, "/#{bucket}/#{key}", query: %{"uploads" => ""}) |> call()
  end

  defp upload_part(bucket, key, upload_id, part_number, body) do
    SigV4Request.signed_conn(:put, "/#{bucket}/#{key}",
      query: %{"partNumber" => Integer.to_string(part_number), "uploadId" => upload_id},
      body: body
    )
    |> call()
  end

  defp complete_multipart(bucket, key, upload_id, parts) do
    body =
      [
        "<CompleteMultipartUpload>",
        Enum.map(parts, fn {part_number, etag} ->
          "<Part><PartNumber>#{part_number}</PartNumber><ETag>#{etag}</ETag></Part>"
        end),
        "</CompleteMultipartUpload>"
      ]
      |> IO.iodata_to_binary()

    SigV4Request.signed_conn(:post, "/#{bucket}/#{key}",
      query: %{"uploadId" => upload_id},
      body: body
    )
    |> call()
  end

  defp upload_id(body) do
    [_, id] = Regex.run(~r/<UploadId>([^<]+)<\/UploadId>/, body)
    id
  end

  defp maybe_add_content_md5(headers, _body, false), do: headers

  defp maybe_add_content_md5(headers, body, true),
    do: [{"content-md5", content_md5(body)} | headers]

  defp content_md5(body), do: :crypto.hash(:md5, body) |> Base.encode64()

  defp restore_env(key, nil), do: Application.delete_env(:maxio, key)
  defp restore_env(key, value), do: Application.put_env(:maxio, key, value)

  defp with_storage_backend(backend, fun) do
    previous = Application.get_env(:maxio, :storage_backend)
    Application.put_env(:maxio, :storage_backend, backend)

    try do
      fun.()
    after
      restore_env(:storage_backend, previous)
    end
  end

  test "put get and delete replication configuration" do
    assert create_bucket("replicationcfg").status == 200

    missing = get_replication("replicationcfg")
    assert missing.status == 404
    assert missing.resp_body =~ "ReplicationConfigurationNotFoundError"

    assert enable_versioning("replicationcfg").status == 200

    put = put_replication("replicationcfg", @replication)
    assert put.status == 200
    assert put.resp_body == ""

    assert {:ok, %{"Role" => "arn:aws:iam::000000000000:role/replication"}} =
             BucketConfigs.get("replicationcfg", :replication)

    get = get_replication("replicationcfg")
    assert get.status == 200
    assert get_resp_header(get, "content-type") |> hd() =~ "application/xml"
    assert get.resp_body =~ "<ReplicationConfiguration"
    assert get.resp_body =~ "<Role>arn:aws:iam::000000000000:role/replication</Role>"
    assert get.resp_body =~ "<Filter>"
    assert get.resp_body =~ "<StorageClass>STANDARD_IA</StorageClass>"

    assert put_replication("replicationcfg", @delete_replication).status == 200

    assert get_replication("replicationcfg").resp_body =~
             "<DeleteReplication><Status>Enabled</Status></DeleteReplication>"

    assert put_replication("replicationcfg", @legacy_prefix).status == 200
    assert get_replication("replicationcfg").resp_body =~ "<Prefix></Prefix>"

    assert put_replication("replicationcfg", @empty_filter).status == 200

    assert {:ok, %{"Rules" => [%{"ID" => "all-v2", "Filter" => %{}}]}} =
             BucketConfigs.get("replicationcfg", :replication)

    empty_filter_get = get_replication("replicationcfg")
    assert empty_filter_get.resp_body =~ "<Filter"

    deleted = delete_replication("replicationcfg")
    assert deleted.status == 204
    assert BucketConfigs.get("replicationcfg", :replication) == :none
    assert get_replication("replicationcfg").status == 404
  end

  test "put object matching replication rule is copied by drain" do
    setup_replication_pair("repdatasrc")

    put = put_object("repdatasrc", "logs/a.txt", "hello replication")
    assert put.status == 200
    [version_id] = get_resp_header(put, "x-amz-version-id")

    head = head_object("repdatasrc", "logs/a.txt")
    assert head.status == 200
    assert get_resp_header(head, "x-amz-replication-status") == ["PENDING"]

    assert [%{source_version_id: ^version_id, destination_storage_class: "STANDARD_IA"}] =
             ReplicationOutbox.list(status: "pending")

    assert {:ok, %{claimed: 1, completed: 1, failed: 0}} =
             ReplicationDelivery.drain(limit: 10)

    source_head = head_object("repdatasrc", "logs/a.txt")
    assert get_resp_header(source_head, "x-amz-replication-status") == ["COMPLETED"]

    assert %{replication_status: "COMPLETED"} =
             ObjectMeta.get("repdatasrc", "logs/a.txt", version_id,
               authoritative_source: [read: :sidecar, list: :pg, write: :pg],
               read_prefer_index: false
             )

    replica = get_object("replica-dest", "logs/a.txt")
    assert replica.status == 200
    assert replica.resp_body == "hello replication"
    assert get_resp_header(replica, "x-amz-version-id") == [version_id]
    assert get_resp_header(replica, "x-amz-replication-status") == ["REPLICA"]
    assert get_resp_header(replica, "x-amz-storage-class") == ["STANDARD_IA"]

    assert %{replication_status: "REPLICA"} =
             ObjectMeta.get("replica-dest", "logs/a.txt", version_id,
               authoritative_source: [read: :sidecar, list: :pg, write: :pg],
               read_prefer_index: false
             )
  end

  test "backfill enqueues existing object versions after replication config is added" do
    assert create_bucket("repbackfill").status == 200
    assert create_bucket("replica-dest").status == 200
    assert enable_versioning("repbackfill").status == 200
    assert enable_versioning("replica-dest").status == 200

    put = put_object("repbackfill", "logs/old.txt", "old payload")
    assert put.status == 200
    [version_id] = get_resp_header(put, "x-amz-version-id")

    assert put_object("repbackfill", "tmp/skipped.txt", "not matched").status == 200
    assert ReplicationOutbox.list(status: "pending") == []

    assert put_replication("repbackfill", @replication).status == 200

    assert {:ok,
            %{
              dry_run: true,
              scanned_versions: 2,
              matched_versions: 1,
              matched_tasks: 1,
              would_enqueue_tasks: 1,
              enqueued_tasks: 0,
              skipped_no_rule_versions: 1
            }} = ReplicationBackfill.run(source_bucket: "repbackfill", dry_run: true, limit: 100)

    assert ReplicationOutbox.list(status: "pending") == []

    assert {:ok,
            %{
              dry_run: false,
              scanned_versions: 2,
              matched_versions: 1,
              matched_tasks: 1,
              existing_tasks: 0,
              enqueued_tasks: 1,
              refreshed_source_statuses: 1
            }} = ReplicationBackfill.run(source_bucket: "repbackfill", dry_run: false, limit: 100)

    source_head = head_object("repbackfill", "logs/old.txt")
    assert get_resp_header(source_head, "x-amz-replication-status") == ["PENDING"]

    assert [%{source_version_id: ^version_id, event_name: "s3:ObjectCreated:Put"}] =
             ReplicationOutbox.list(status: "pending")

    assert {:ok, %{claimed: 1, completed: 1, failed: 0}} =
             ReplicationDelivery.drain(limit: 10)

    completed_source = head_object("repbackfill", "logs/old.txt")
    assert get_resp_header(completed_source, "x-amz-replication-status") == ["COMPLETED"]

    replica = get_object("replica-dest", "logs/old.txt")
    assert replica.status == 200
    assert replica.resp_body == "old payload"
    assert get_resp_header(replica, "x-amz-version-id") == [version_id]
    assert get_resp_header(replica, "x-amz-replication-status") == ["REPLICA"]

    assert {:ok,
            %{
              existing_tasks: 1,
              enqueued_tasks: 0,
              refreshed_source_statuses: 1
            }} = ReplicationBackfill.run(source_bucket: "repbackfill", dry_run: false, limit: 100)

    assert length(ReplicationOutbox.list(limit: 10)) == 1
  end

  test "backfill preserves delete marker order when delete marker replication is enabled" do
    assert create_bucket("repbackfilldm").status == 200
    assert create_bucket("replica-dest").status == 200
    assert enable_versioning("repbackfilldm").status == 200
    assert enable_versioning("replica-dest").status == 200

    put = put_object("repbackfilldm", "logs/deleted.txt", "delete later")
    assert put.status == 200
    [object_version_id] = get_resp_header(put, "x-amz-version-id")

    delete = delete_object("repbackfilldm", "logs/deleted.txt")
    assert delete.status == 204
    [marker_version_id] = get_resp_header(delete, "x-amz-version-id")
    assert get_resp_header(delete, "x-amz-delete-marker") == ["true"]

    assert put_replication("repbackfilldm", @delete_marker_replication).status == 200

    assert {:ok, %{enqueued_tasks: 2, matched_tasks: 2}} =
             ReplicationBackfill.run(source_bucket: "repbackfilldm", dry_run: false, limit: 100)

    pending_events =
      ReplicationOutbox.list(status: "pending")
      |> Enum.map(&{&1.event_name, &1.source_version_id})
      |> Enum.sort()

    assert pending_events == [
             {"s3:ObjectCreated:Put", object_version_id},
             {"s3:ObjectRemoved:DeleteMarkerCreated", marker_version_id}
           ]

    assert {:ok, %{claimed: 2, completed: 2, failed: 0}} =
             ReplicationDelivery.drain(limit: 10)

    assert %{is_delete_marker: true, replication_status: "COMPLETED"} =
             ObjectMeta.get("repbackfilldm", "logs/deleted.txt", marker_version_id)

    assert %{is_delete_marker: true, replication_status: "REPLICA"} =
             ObjectMeta.get("replica-dest", "logs/deleted.txt", marker_version_id)

    replica_get = get_object("replica-dest", "logs/deleted.txt")
    assert replica_get.status == 404
    assert get_resp_header(replica_get, "x-amz-delete-marker") == ["true"]
  end

  test "backfill drains newer null source version after older versioned object" do
    assert create_bucket("repbackfillnull").status == 200
    assert create_bucket("replica-dest").status == 200
    assert enable_versioning("repbackfillnull").status == 200
    assert enable_versioning("replica-dest").status == 200

    old = put_object("repbackfillnull", "logs/mixed.txt", "old versioned payload")
    assert old.status == 200
    [old_version_id] = get_resp_header(old, "x-amz-version-id")
    assert old_version_id != "null"

    assert suspend_versioning("repbackfillnull").status == 200

    latest_null = put_object("repbackfillnull", "logs/mixed.txt", "new null payload")
    assert latest_null.status == 200
    assert get_resp_header(latest_null, "x-amz-version-id") == []

    assert enable_versioning("repbackfillnull").status == 200
    assert put_replication("repbackfillnull", @replication).status == 200

    assert {:ok, %{enqueued_tasks: 2, matched_tasks: 2}} =
             ReplicationBackfill.run(source_bucket: "repbackfillnull", dry_run: false, limit: 100)

    assert {:ok, %{claimed: 2, completed: 2, failed: 0}} =
             ReplicationDelivery.drain(limit: 10)

    replica_latest = get_object("replica-dest", "logs/mixed.txt")
    assert replica_latest.status == 200
    assert replica_latest.resp_body == "new null payload"
    assert get_resp_header(replica_latest, "x-amz-version-id") == []
    assert get_resp_header(replica_latest, "x-amz-replication-status") == ["REPLICA"]

    replica_old =
      get_object("replica-dest", "logs/mixed.txt", query: %{"versionId" => old_version_id})

    assert replica_old.status == 200
    assert replica_old.resp_body == "old versioned payload"
  end

  test "same bucket replication fails closed instead of overwriting the source version" do
    assert create_bucket("repsame").status == 200
    assert enable_versioning("repsame").status == 200
    assert put_replication("repsame", replication_to("repsame")).status == 200

    put = put_object("repsame", "logs/same.txt", "keep source bytes")
    assert put.status == 200

    assert {:ok, %{claimed: 1, completed: 0, failed: 1}} =
             ReplicationDelivery.drain(limit: 10, failure_backoff_ms: 0)

    source = get_object("repsame", "logs/same.txt")
    assert source.status == 200
    assert source.resp_body == "keep source bytes"
    assert get_resp_header(source, "x-amz-replication-status") == ["FAILED"]

    assert [%{status: "failed", error_reason: reason}] = ReplicationOutbox.list(status: "failed")
    assert reason =~ "destination_version_conflict"
  end

  test "same source multi-destination terminal updates serialize aggregate status" do
    setup_multi_destination_replication("repmulti")

    put = put_object("repmulti", "logs/multi.txt", "multi destination")
    assert put.status == 200
    [version_id] = get_resp_header(put, "x-amz-version-id")

    events = ReplicationOutbox.list(status: "pending") |> Enum.sort_by(& &1.destination_bucket)
    assert Enum.map(events, & &1.destination_bucket) == ["replica-a", "replica-b"]

    [claimed_a, claimed_b] =
      Enum.map(events, fn event ->
        assert {:ok, claimed} = ReplicationOutbox.claim(event.id, failure_backoff_ms: 0)
        claimed
      end)

    [result_a, result_b] =
      [claimed_a, claimed_b]
      |> Enum.map(fn claimed ->
        Task.async(fn -> ReplicationOutbox.mark_completed_with_source_status(claimed) end)
      end)
      |> Task.await_many(30_000)

    assert {:ok, %{status: "completed"}} = result_a
    assert {:ok, %{status: "completed"}} = result_b

    source_head = head_object("repmulti", "logs/multi.txt")
    assert get_resp_header(source_head, "x-amz-replication-status") == ["COMPLETED"]

    assert %{replication_status: "COMPLETED"} =
             ObjectMeta.get("repmulti", "logs/multi.txt", version_id,
               authoritative_source: [read: :sidecar, list: :pg, write: :pg],
               read_prefer_index: false
             )
  end

  test "delivery failure from destination versioning disabled records FAILED and retries" do
    assert create_bucket("repdisabled").status == 200
    assert create_bucket("replica-disabled").status == 200
    assert enable_versioning("repdisabled").status == 200
    assert put_replication("repdisabled", replication_to("replica-disabled")).status == 200

    put = put_object("repdisabled", "logs/retry.txt", "retry payload")
    assert put.status == 200
    [version_id] = get_resp_header(put, "x-amz-version-id")

    assert {:ok, %{claimed: 1, completed: 0, failed: 1}} =
             ReplicationDelivery.drain(limit: 10, failure_backoff_ms: 0)

    failed_source = head_object("repdisabled", "logs/retry.txt")
    assert get_resp_header(failed_source, "x-amz-replication-status") == ["FAILED"]

    assert %{replication_status: "FAILED"} =
             ObjectMeta.get("repdisabled", "logs/retry.txt", version_id,
               authoritative_source: [read: :sidecar, list: :pg, write: :pg],
               read_prefer_index: false
             )

    assert [
             %{
               source_version_id: ^version_id,
               status: "failed",
               attempts: 1,
               error_reason: reason
             }
           ] = ReplicationOutbox.list(status: "failed")

    assert reason =~ "destination_versioning_not_enabled"

    assert enable_versioning("replica-disabled").status == 200

    assert {:ok, %{claimed: 1, completed: 1, failed: 0}} =
             ReplicationDelivery.drain(limit: 10, failure_backoff_ms: 0)

    completed_source = head_object("repdisabled", "logs/retry.txt")
    assert get_resp_header(completed_source, "x-amz-replication-status") == ["COMPLETED"]

    replica = get_object("replica-disabled", "logs/retry.txt")
    assert replica.status == 200
    assert replica.resp_body == "retry payload"
    assert get_resp_header(replica, "x-amz-version-id") == [version_id]
    assert get_resp_header(replica, "x-amz-replication-status") == ["REPLICA"]
  end

  test "non matching objects do not enqueue replication tasks" do
    setup_replication_pair("repnomatch")

    put = put_object("repnomatch", "tmp/a.txt", "not replicated")
    assert put.status == 200

    head = head_object("repnomatch", "tmp/a.txt")
    assert head.status == 200
    assert get_resp_header(head, "x-amz-replication-status") == []
    assert ReplicationOutbox.list(status: "pending") == []
  end

  test "overlapping rules to the same destination use the highest priority rule" do
    setup_replication_pair("reppriority", @priority_replication)

    put = put_object("reppriority", "logs/priority.txt", "priority")
    assert put.status == 200

    assert [%{rule_id: "high", destination_storage_class: "ONEZONE_IA"}] =
             ReplicationOutbox.list(status: "pending")

    assert {:ok, %{claimed: 1, completed: 1, failed: 0}} =
             ReplicationDelivery.drain(limit: 10)

    replica = get_object("replica-dest", "logs/priority.txt")
    assert replica.status == 200
    assert replica.resp_body == "priority"
    assert get_resp_header(replica, "x-amz-storage-class") == ["ONEZONE_IA"]
  end

  test "copy object and complete multipart upload enqueue replication tasks" do
    setup_replication_pair("repcopympu")

    assert put_object("repcopympu", "src.txt", "copy payload").status == 200

    copy = copy_object("repcopympu", "logs/copied.txt", "/repcopympu/src.txt")
    assert copy.status == 200
    [copy_version_id] = get_resp_header(copy, "x-amz-version-id")

    copy_head = head_object("repcopympu", "logs/copied.txt")
    assert get_resp_header(copy_head, "x-amz-replication-status") == ["PENDING"]

    assert [%{event_name: "s3:ObjectCreated:Copy", source_version_id: ^copy_version_id}] =
             ReplicationOutbox.list(status: "pending")

    assert {:ok, %{claimed: 1, completed: 1, failed: 0}} =
             ReplicationDelivery.drain(limit: 10)

    copied = get_object("replica-dest", "logs/copied.txt")
    assert copied.status == 200
    assert copied.resp_body == "copy payload"
    assert get_resp_header(copied, "x-amz-replication-status") == ["REPLICA"]

    assert {:ok, %{existing_tasks: 1, enqueued_tasks: 0}} =
             ReplicationBackfill.run(source_bucket: "repcopympu", dry_run: false, limit: 100)

    assert length(ReplicationOutbox.list(limit: 10)) == 1

    init = initiate_multipart("repcopympu", "logs/mp.bin")
    assert init.status == 200
    upload_id = upload_id(init.resp_body)

    part = upload_part("repcopympu", "logs/mp.bin", upload_id, 1, "multipart payload")
    assert part.status == 200
    [etag] = get_resp_header(part, "etag")

    complete = complete_multipart("repcopympu", "logs/mp.bin", upload_id, [{1, etag}])
    assert complete.status == 200
    [mpu_version_id] = get_resp_header(complete, "x-amz-version-id")

    assert [
             %{
               event_name: "s3:ObjectCreated:CompleteMultipartUpload",
               source_version_id: ^mpu_version_id
             }
           ] =
             ReplicationOutbox.list(status: "pending")

    assert {:ok, %{claimed: 1, completed: 1, failed: 0}} =
             ReplicationDelivery.drain(limit: 10)

    replica = get_object("replica-dest", "logs/mp.bin")
    assert replica.status == 200
    assert replica.resp_body == "multipart payload"
    assert get_resp_header(replica, "x-amz-replication-status") == ["REPLICA"]
  end

  test "delete marker replication mirrors the marker to the destination bucket" do
    setup_replication_pair("repdm", @delete_marker_replication)

    put = put_object("repdm", "logs/deleted.txt", "delete me")
    assert put.status == 200

    assert {:ok, %{claimed: 1, completed: 1, failed: 0}} =
             ReplicationDelivery.drain(limit: 10)

    delete = delete_object("repdm", "logs/deleted.txt")
    assert delete.status == 204
    [marker_version_id] = get_resp_header(delete, "x-amz-version-id")
    assert get_resp_header(delete, "x-amz-delete-marker") == ["true"]

    assert %{is_delete_marker: true, replication_status: "PENDING"} =
             ObjectMeta.get("repdm", "logs/deleted.txt", marker_version_id)

    assert [
             %{
               event_name: "s3:ObjectRemoved:DeleteMarkerCreated",
               source_version_id: ^marker_version_id
             }
           ] = ReplicationOutbox.list(status: "pending")

    assert {:ok, %{claimed: 1, completed: 1, failed: 0}} =
             ReplicationDelivery.drain(limit: 10)

    assert %{is_delete_marker: true, replication_status: "COMPLETED"} =
             ObjectMeta.get("repdm", "logs/deleted.txt", marker_version_id)

    assert %{is_delete_marker: true, replication_status: "REPLICA"} =
             ObjectMeta.get("replica-dest", "logs/deleted.txt", marker_version_id)

    replica_get = get_object("replica-dest", "logs/deleted.txt")
    assert replica_get.status == 404
    assert get_resp_header(replica_get, "x-amz-delete-marker") == ["true"]
  end

  test "DeleteReplication mirrors version hard deletes to replica versions" do
    setup_replication_pair("repharddelete", @delete_replication)

    put = put_object("repharddelete", "logs/hard.txt", "delete this version")
    assert put.status == 200
    [version_id] = get_resp_header(put, "x-amz-version-id")

    assert {:ok, %{claimed: 1, completed: 1, failed: 0}} =
             ReplicationDelivery.drain(limit: 10)

    assert %{replication_status: "REPLICA"} =
             ObjectMeta.get("replica-dest", "logs/hard.txt", version_id)

    delete = delete_object("repharddelete", "logs/hard.txt", query: %{"versionId" => version_id})
    assert delete.status == 204
    assert get_resp_header(delete, "x-amz-version-id") == [version_id]

    assert ObjectMeta.get("repharddelete", "logs/hard.txt", version_id) == {:error, :not_found}

    assert [
             %{
               event_name: "s3:ObjectRemoved:Delete",
               source_version_id: ^version_id,
               status: "pending"
             }
           ] = ReplicationOutbox.list(status: "pending")

    assert {:ok, %{claimed: 1, completed: 1, failed: 0}} =
             ReplicationDelivery.drain(limit: 10)

    assert ObjectMeta.get("replica-dest", "logs/hard.txt", version_id) == {:error, :not_found}

    replica_get =
      get_object("replica-dest", "logs/hard.txt", query: %{"versionId" => version_id})

    assert replica_get.status == 404
  end

  test "DeleteReplication hard delete is idempotent when destination replica version is already missing" do
    setup_replication_pair("rephardmissing", @delete_replication)

    put = put_object("rephardmissing", "logs/missing-target.txt", "delete missing target")
    assert put.status == 200
    [version_id] = get_resp_header(put, "x-amz-version-id")

    assert {:ok, %{claimed: 1, completed: 1, failed: 0}} =
             ReplicationDelivery.drain(limit: 10)

    assert %{replication_status: "REPLICA"} =
             ObjectMeta.get("replica-dest", "logs/missing-target.txt", version_id)

    target_delete =
      delete_object("replica-dest", "logs/missing-target.txt",
        query: %{"versionId" => version_id}
      )

    assert target_delete.status == 204

    assert ObjectMeta.get("replica-dest", "logs/missing-target.txt", version_id) ==
             {:error, :not_found}

    source_delete =
      delete_object("rephardmissing", "logs/missing-target.txt",
        query: %{"versionId" => version_id}
      )

    assert source_delete.status == 204

    assert [
             %{
               event_name: "s3:ObjectRemoved:Delete",
               source_version_id: ^version_id,
               status: "pending"
             }
           ] = ReplicationOutbox.list(status: "pending")

    assert {:ok, %{claimed: 1, completed: 1, failed: 0}} =
             ReplicationDelivery.drain(limit: 10)
  end

  test "sidecar version hard delete logs matched DeleteReplication skip" do
    setup_replication_pair("repsidecarhard", @delete_replication)

    put = put_object("repsidecarhard", "logs/sidecar-hard.txt", "sidecar hard delete")
    assert put.status == 200
    [version_id] = get_resp_header(put, "x-amz-version-id")

    assert {:ok, %{claimed: 1, completed: 1, failed: 0}} =
             ReplicationDelivery.drain(limit: 10)

    Application.put_env(:maxio, :authoritative_source,
      read: :sidecar,
      list: :sidecar,
      write: :sidecar
    )

    log =
      capture_log([level: :warning], fn ->
        delete =
          delete_object("repsidecarhard", "logs/sidecar-hard.txt",
            query: %{"versionId" => version_id}
          )

        assert delete.status == 204
      end)

    assert log =~ "replication skipped under non-PG write authority"
    assert log =~ "s3:ObjectRemoved:Delete"
    assert log =~ "write_authority=:sidecar"
    assert log =~ "matched_tasks=1"
    assert ReplicationOutbox.list(status: "pending") == []
  end

  test "DeleteReplication hard delete fails closed when destination version is not a replica" do
    assert create_bucket("rephardconflict").status == 200
    assert create_bucket("replica-dest").status == 200
    assert enable_versioning("rephardconflict").status == 200
    assert enable_versioning("replica-dest").status == 200
    assert put_replication("rephardconflict", @delete_replication).status == 200

    version_id = VersionId.generate()
    attrs = %{size: 1, etag: "conflict-etag", content_type: "text/plain", tags: %{}}

    assert {:ok, _source} =
             Objects.put_version_with_id(
               "rephardconflict",
               "logs/conflict.txt",
               version_id,
               attrs
             )

    assert {:ok, _destination} =
             Objects.put_version_with_id("replica-dest", "logs/conflict.txt", version_id, attrs)

    delete =
      delete_object("rephardconflict", "logs/conflict.txt", query: %{"versionId" => version_id})

    assert delete.status == 204

    assert [
             %{
               event_name: "s3:ObjectRemoved:Delete",
               source_version_id: ^version_id,
               status: "pending"
             }
           ] = ReplicationOutbox.list(status: "pending")

    assert {:ok, %{claimed: 1, completed: 0, failed: 1}} =
             ReplicationDelivery.drain(limit: 10, failure_backoff_ms: 0)

    assert [
             %{
               event_name: "s3:ObjectRemoved:Delete",
               source_version_id: ^version_id,
               status: "failed",
               error_reason: reason
             }
           ] = ReplicationOutbox.list(status: "failed")

    assert reason =~ "destination_version_conflict"

    assert %{replication_status: nil} =
             ObjectMeta.get("replica-dest", "logs/conflict.txt", version_id)
  end

  test "DeleteReplication hard delete stays retryable when destination storage delete fails" do
    setup_replication_pair("rephardstoragefail", @delete_replication)

    put = put_object("rephardstoragefail", "logs/storage-fail.txt", "delete must retry")
    assert put.status == 200
    [version_id] = get_resp_header(put, "x-amz-version-id")

    assert {:ok, %{claimed: 1, completed: 1, failed: 0}} =
             ReplicationDelivery.drain(limit: 10)

    assert %{replication_status: "REPLICA"} =
             ObjectMeta.get("replica-dest", "logs/storage-fail.txt", version_id)

    delete =
      delete_object("rephardstoragefail", "logs/storage-fail.txt",
        query: %{"versionId" => version_id}
      )

    assert delete.status == 204

    with_storage_backend(Maxio.Test.StorageDeleteVersionErrorBackend, fn ->
      assert {:ok, %{claimed: 1, completed: 0, failed: 1}} =
               ReplicationDelivery.drain(limit: 10, failure_backoff_ms: 0)
    end)

    assert [
             %{
               event_name: "s3:ObjectRemoved:Delete",
               source_version_id: ^version_id,
               status: "failed",
               error_reason: reason
             }
           ] = ReplicationOutbox.list(status: "failed")

    assert reason =~ "injected_delete_version_failure"

    assert %{replication_status: "REPLICA"} =
             ObjectMeta.get("replica-dest", "logs/storage-fail.txt", version_id)

    replica =
      get_object("replica-dest", "logs/storage-fail.txt", query: %{"versionId" => version_id})

    assert replica.status == 200
    assert replica.resp_body == "delete must retry"
  end

  test "DeleteObjects with VersionId uses DeleteReplication hard delete path" do
    setup_replication_pair("repbatchdelete", @delete_replication)

    put = put_object("repbatchdelete", "logs/batch.txt", "batch delete")
    assert put.status == 200
    [version_id] = get_resp_header(put, "x-amz-version-id")

    assert {:ok, %{claimed: 1, completed: 1, failed: 0}} =
             ReplicationDelivery.drain(limit: 10)

    body =
      ~s(<Delete><Object><Key>logs/batch.txt</Key><VersionId>#{version_id}</VersionId></Object></Delete>)

    delete = delete_objects("repbatchdelete", body)
    assert delete.status == 200
    assert delete.resp_body =~ "<VersionId>#{version_id}</VersionId>"

    assert [
             %{
               event_name: "s3:ObjectRemoved:Delete",
               source_version_id: ^version_id,
               status: "pending"
             }
           ] = ReplicationOutbox.list(status: "pending")

    assert {:ok, %{claimed: 1, completed: 1, failed: 0}} =
             ReplicationDelivery.drain(limit: 10)

    assert ObjectMeta.get("replica-dest", "logs/batch.txt", version_id) ==
             {:error, :not_found}
  end

  test "DeleteMarkerReplication alone does not mirror version hard deletes" do
    setup_replication_pair("repdmonlyhard", @delete_marker_replication)

    put = put_object("repdmonlyhard", "logs/keep-replica.txt", "keep replica")
    assert put.status == 200
    [version_id] = get_resp_header(put, "x-amz-version-id")

    assert {:ok, %{claimed: 1, completed: 1, failed: 0}} =
             ReplicationDelivery.drain(limit: 10)

    delete =
      delete_object("repdmonlyhard", "logs/keep-replica.txt", query: %{"versionId" => version_id})

    assert delete.status == 204
    assert ReplicationOutbox.list(status: "pending") == []

    replica =
      get_object("replica-dest", "logs/keep-replica.txt", query: %{"versionId" => version_id})

    assert replica.status == 200
    assert replica.resp_body == "keep replica"
  end

  test "DeleteReplication alone does not mirror delete marker creation" do
    setup_replication_pair("repdeleteonlymarker", @delete_replication)

    put = put_object("repdeleteonlymarker", "logs/no-marker.txt", "marker stays local")
    assert put.status == 200

    assert {:ok, %{claimed: 1, completed: 1, failed: 0}} =
             ReplicationDelivery.drain(limit: 10)

    delete = delete_object("repdeleteonlymarker", "logs/no-marker.txt")
    assert delete.status == 204
    assert get_resp_header(delete, "x-amz-delete-marker") == ["true"]
    assert ReplicationOutbox.list(status: "pending") == []

    replica = get_object("replica-dest", "logs/no-marker.txt")
    assert replica.status == 200
    assert replica.resp_body == "marker stays local"
  end

  test "sidecar delete marker logs matched DeleteMarkerReplication skip" do
    setup_replication_pair("repsidecarmarker", @delete_marker_replication)

    put = put_object("repsidecarmarker", "logs/sidecar-marker.txt", "sidecar marker")
    assert put.status == 200

    assert {:ok, %{claimed: 1, completed: 1, failed: 0}} =
             ReplicationDelivery.drain(limit: 10)

    Application.put_env(:maxio, :authoritative_source,
      read: :sidecar,
      list: :sidecar,
      write: :sidecar
    )

    log =
      capture_log([level: :warning], fn ->
        delete = delete_object("repsidecarmarker", "logs/sidecar-marker.txt")
        assert delete.status == 204
        assert get_resp_header(delete, "x-amz-delete-marker") == ["true"]
      end)

    assert log =~ "replication skipped under non-PG write authority"
    assert log =~ "s3:ObjectRemoved:DeleteMarkerCreated"
    assert log =~ "write_authority=:sidecar"
    assert log =~ "matched_tasks=1"
    assert ReplicationOutbox.list(status: "pending") == []
  end

  test "put replication requires source bucket versioning enabled" do
    assert create_bucket("replicationunversioned").status == 200

    rejected = put_replication("replicationunversioned", @replication)
    assert rejected.status == 400
    assert rejected.resp_body =~ "InvalidRequest"
    assert BucketConfigs.get("replicationunversioned", :replication) == :none

    assert enable_versioning("replicationunversioned").status == 200
    assert put_replication("replicationunversioned", @replication).status == 200
  end

  test "malformed XML and checksum failures do not overwrite existing replication config" do
    assert create_bucket("replicationbad").status == 200
    assert enable_versioning("replicationbad").status == 200
    assert put_replication("replicationbad", @replication).status == 200

    missing_md5 = put_replication("replicationbad", @legacy_prefix, content_md5: false)
    assert missing_md5.status == 400
    assert missing_md5.resp_body =~ "MissingSecurityHeader"

    bad_md5 =
      put_replication("replicationbad", @legacy_prefix,
        headers: [{"content-md5", content_md5("different")}],
        content_md5: false
      )

    assert bad_md5.status == 400
    assert bad_md5.resp_body =~ "BadDigest"

    bad_xml =
      put_replication(
        "replicationbad",
        "<ReplicationConfiguration><Role>r</Role><Rule><Bad /></Rule></ReplicationConfiguration>"
      )

    assert bad_xml.status == 400
    assert bad_xml.resp_body =~ "MalformedXML"

    assert {:ok, %{"Rules" => [%{"ID" => "logs"}]}} =
             BucketConfigs.get("replicationbad", :replication)
  end

  test "invalid replication XML semantics do not overwrite existing config" do
    assert create_bucket("replicationsemanticbad").status == 200
    assert enable_versioning("replicationsemanticbad").status == 200
    assert put_replication("replicationsemanticbad", @replication).status == 200

    invalid_configs = [
      ~s(<ReplicationConfiguration><Role>arn:aws:iam::000000000000:role/replication</Role><Rule><ID>logs</ID><Status>Enabled</Status><Priority>1</Priority><Filter><Tag><Key>env</Key><Value>prod</Value></Tag></Filter><DeleteMarkerReplication><Status>Enabled</Status></DeleteMarkerReplication><Destination><Bucket>arn:aws:s3:::replica-dest</Bucket></Destination></Rule></ReplicationConfiguration>),
      ~s(<ReplicationConfiguration><Role>arn:aws:iam::000000000000:role/replication</Role><Rule><ID>logs</ID><Status>Enabled</Status><Prefix></Prefix><SourceSelectionCriteria><SseKmsEncryptedObjects><Status>Enabled</Status></SseKmsEncryptedObjects></SourceSelectionCriteria><Destination><Bucket>arn:aws:s3:::replica-dest</Bucket></Destination></Rule></ReplicationConfiguration>),
      ~s(<ReplicationConfiguration><Role>arn:aws:iam::000000000000:role/replication</Role><Rule><ID>logs</ID><Status>Enabled</Status><Prefix></Prefix><Destination><Bucket>arn:aws:s3:::replica-dest</Bucket><AccessControlTranslation><Owner>Destination</Owner></AccessControlTranslation></Destination></Rule></ReplicationConfiguration>),
      ~s(<ReplicationConfiguration><Role>arn:aws:iam::000000000000:role/replication</Role><Rule><ID>dup</ID><Status>Enabled</Status><Prefix>a/</Prefix><Destination><Bucket>arn:aws:s3:::replica-dest</Bucket></Destination></Rule><Rule><ID>dup</ID><Status>Enabled</Status><Prefix>b/</Prefix><Destination><Bucket>arn:aws:s3:::replica-dest-2</Bucket></Destination></Rule></ReplicationConfiguration>),
      ~s(<ReplicationConfiguration><Role>arn:aws:iam::000000000000:role/replication</Role><Rule><ID>logs</ID><Status>Enabled</Status><Prefix></Prefix><Destination><Bucket>arn:aws:s3:::replica-dest</Bucket><StorageClass>standard_ia</StorageClass></Destination></Rule></ReplicationConfiguration>)
    ]

    for xml <- invalid_configs do
      rejected = put_replication("replicationsemanticbad", xml)
      assert rejected.status == 400
      assert rejected.resp_body =~ "MalformedXML"

      assert {:ok, %{"Rules" => [%{"ID" => "logs"}]}} =
               BucketConfigs.get("replicationsemanticbad", :replication)
    end
  end

  test "checksum trailers and aws-chunked XML bodies are validated" do
    assert create_bucket("replicationchunked").status == 200
    assert enable_versioning("replicationchunked").status == 200

    plain_trailer =
      put_replication("replicationchunked", @replication,
        headers: [
          {"x-amz-sdk-checksum-algorithm", "SHA256"},
          {"x-amz-trailer", "x-amz-checksum-sha256"}
        ]
      )

    assert plain_trailer.status == 400
    assert plain_trailer.resp_body =~ "InvalidRequest"

    bare_non_checksum_trailer =
      put_replication("replicationchunked", @replication,
        headers: [{"x-amz-trailer", "x-amz-meta-not-a-checksum"}],
        content_md5: false
      )

    assert bare_non_checksum_trailer.status == 400
    assert bare_non_checksum_trailer.resp_body =~ "MissingSecurityHeader"

    bad =
      SigV4Request.signed_chunked_conn(:put, "/replicationchunked", @replication,
        query: %{"replication" => ""},
        headers: [
          {"x-amz-sdk-checksum-algorithm", "SHA256"},
          {"content-md5", content_md5(@replication)}
        ],
        trailer_headers: [
          {"x-amz-checksum-sha256", :crypto.hash(:sha256, "different") |> Base.encode64()}
        ]
      )
      |> call()

    assert bad.status == 400
    assert bad.resp_body =~ "BadDigest"
    assert BucketConfigs.get("replicationchunked", :replication) == :none

    ok_trailer =
      SigV4Request.signed_chunked_conn(:put, "/replicationchunked", @replication,
        query: %{"replication" => ""},
        headers: [{"x-amz-sdk-checksum-algorithm", "SHA256"}],
        trailer_headers: [
          {"x-amz-checksum-sha256", :crypto.hash(:sha256, @replication) |> Base.encode64()}
        ]
      )
      |> call()

    assert ok_trailer.status == 200

    assert {:ok, %{"Role" => "arn:aws:iam::000000000000:role/replication"}} =
             BucketConfigs.get("replicationchunked", :replication)

    ok =
      SigV4Request.signed_chunked_conn(:put, "/replicationchunked", @replication,
        query: %{"replication" => ""},
        headers: [{"content-md5", content_md5(@replication)}]
      )
      |> call()

    assert ok.status == 200

    assert {:ok, %{"Role" => "arn:aws:iam::000000000000:role/replication"}} =
             BucketConfigs.get("replicationchunked", :replication)
  end

  test "expected bucket owner missing bucket and method boundaries are enforced" do
    assert create_bucket("replicationowner").status == 200
    assert enable_versioning("replicationowner").status == 200
    assert put_replication("replicationowner", @replication).status == 200

    wrong_get =
      get_replication("replicationowner",
        headers: [{"x-amz-expected-bucket-owner", "999999999999"}]
      )

    assert wrong_get.status == 403
    assert wrong_get.resp_body =~ "AccessDenied"

    wrong_put =
      put_replication("replicationowner", @legacy_prefix,
        headers: [{"x-amz-expected-bucket-owner", "999999999999"}]
      )

    assert wrong_put.status == 403

    wrong_delete =
      delete_replication("replicationowner",
        headers: [{"x-amz-expected-bucket-owner", "999999999999"}]
      )

    assert wrong_delete.status == 403

    missing = put_replication("missing-replication", @replication)
    assert missing.status == 404
    assert missing.resp_body =~ "NoSuchBucket"

    object_get =
      SigV4Request.signed_conn(:get, "/replicationowner/object.txt",
        query: %{"replication" => ""}
      )
      |> call()

    assert object_get.status == 405
    assert object_get.resp_body =~ "MethodNotAllowed"

    post =
      SigV4Request.signed_conn(:post, "/replicationowner", query: %{"replication" => ""})
      |> call()

    assert post.status == 405
  end

  test "replication IAM actions and resource tag condition behavior match action map" do
    assert create_bucket("replicationauthz").status == 200
    assert enable_versioning("replicationauthz").status == 200
    assert put_replication("replicationauthz", @replication).status == 200

    get_policy =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:GetReplicationConfiguration","Resource":"arn:aws:s3:::replicationauthz"}})

    assert :ok = Store.put_principal_policy(@alice_arn, "get-replication-only", get_policy)

    assert (alice(:get, "/replicationauthz", query: %{"replication" => ""}) |> call()).status ==
             200

    denied_put =
      alice(:put, "/replicationauthz",
        query: %{"replication" => ""},
        body: @legacy_prefix,
        headers: [{"content-md5", content_md5(@legacy_prefix)}]
      )
      |> call()

    assert denied_put.status == 403

    denied_delete =
      alice(:delete, "/replicationauthz", query: %{"replication" => ""}) |> call()

    assert denied_delete.status == 403

    put_policy =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:PutReplicationConfiguration","Resource":"arn:aws:s3:::replicationauthz"}})

    assert :ok = Store.put_principal_policy(@alice_arn, "put-replication", put_policy)

    denied_without_pass_role =
      alice(:put, "/replicationauthz",
        query: %{"replication" => ""},
        body: @legacy_prefix,
        headers: [{"content-md5", content_md5(@legacy_prefix)}]
      )
      |> call()

    assert denied_without_pass_role.status == 403

    pass_role_policy =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"iam:PassRole","Resource":"arn:aws:iam::000000000000:role/replication"}})

    assert :ok = Store.put_principal_policy(@alice_arn, "pass-replication-role", pass_role_policy)

    denied_wrong_role =
      alice(:put, "/replicationauthz",
        query: %{"replication" => ""},
        body: @other_role_prefix,
        headers: [{"content-md5", content_md5(@other_role_prefix)}]
      )
      |> call()

    assert denied_wrong_role.status == 403

    deny_pass_role_policy =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Deny","Action":"iam:PassRole","Resource":"arn:aws:iam::000000000000:role/replication"}})

    assert :ok =
             Store.put_principal_policy(
               @alice_arn,
               "deny-pass-replication-role",
               deny_pass_role_policy
             )

    denied_explicit_pass_role =
      alice(:put, "/replicationauthz",
        query: %{"replication" => ""},
        body: @legacy_prefix,
        headers: [{"content-md5", content_md5(@legacy_prefix)}]
      )
      |> call()

    assert denied_explicit_pass_role.status == 403
    assert :ok = Store.delete_principal_policy(@alice_arn, "deny-pass-replication-role")

    allowed_put =
      alice(:put, "/replicationauthz",
        query: %{"replication" => ""},
        body: @legacy_prefix,
        headers: [{"content-md5", content_md5(@legacy_prefix)}]
      )
      |> call()

    assert allowed_put.status == 200

    allowed_delete =
      alice(:delete, "/replicationauthz", query: %{"replication" => ""}) |> call()

    assert allowed_delete.status == 204

    tag_xml = "<Tagging><TagSet><Tag><Key>env</Key><Value>prod</Value></Tag></TagSet></Tagging>"

    assert (SigV4Request.signed_conn(:put, "/replicationauthz",
              query: %{"tagging" => ""},
              body: tag_xml
            )
            |> call()).status == 204

    assert :ok = Store.delete_principal_policy(@alice_arn, "get-replication-only")
    assert :ok = Store.delete_principal_policy(@alice_arn, "put-replication")
    assert :ok = Store.delete_principal_policy(@alice_arn, "pass-replication-role")

    resource_tag_policy =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:GetReplicationConfiguration","Resource":"arn:aws:s3:::replicationauthz","Condition":{"StringEquals":{"aws:ResourceTag/env":"prod"}}}})

    assert :ok =
             Store.put_principal_policy(
               @alice_arn,
               "get-replication-resource-tag",
               resource_tag_policy
             )

    denied_by_tag_condition =
      alice(:get, "/replicationauthz", query: %{"replication" => ""}) |> call()

    assert denied_by_tag_condition.status == 403
  end
end
