defmodule Maxio.S3.ReplicationE2ETest do
  use Maxio.DataCase, async: false

  import Plug.Conn

  alias Maxio.Auth.CredentialStore
  alias Maxio.BucketConfigs
  alias Maxio.Policy.Store
  alias Maxio.S3.Endpoint
  alias Maxio.Test.SigV4Request

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

  @other_role_prefix String.replace(
                       @legacy_prefix,
                       "arn:aws:iam::000000000000:role/replication",
                       "arn:aws:iam::000000000000:role/other"
                     )

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

  defp create_bucket(bucket), do: SigV4Request.signed_conn(:put, "/#{bucket}") |> call()

  defp enable_versioning(bucket) do
    body = "<VersioningConfiguration><Status>Enabled</Status></VersioningConfiguration>"

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

  defp maybe_add_content_md5(headers, _body, false), do: headers

  defp maybe_add_content_md5(headers, body, true),
    do: [{"content-md5", content_md5(body)} | headers]

  defp content_md5(body), do: :crypto.hash(:md5, body) |> Base.encode64()

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

    assert put_replication("replicationcfg", @legacy_prefix).status == 200
    assert get_replication("replicationcfg").resp_body =~ "<Prefix></Prefix>"

    deleted = delete_replication("replicationcfg")
    assert deleted.status == 204
    assert BucketConfigs.get("replicationcfg", :replication) == :none
    assert get_replication("replicationcfg").status == 404
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

  test "checksum trailers and aws-chunked XML bodies are rejected" do
    assert create_bucket("replicationchunked").status == 200

    trailer =
      put_replication("replicationchunked", @replication,
        headers: [
          {"x-amz-sdk-checksum-algorithm", "SHA256"},
          {"x-amz-trailer", "x-amz-checksum-sha256"}
        ]
      )

    assert trailer.status == 501
    assert trailer.resp_body =~ "NotImplemented"

    conn =
      SigV4Request.signed_chunked_conn(:put, "/replicationchunked", @replication,
        query: %{"replication" => ""},
        headers: [{"content-md5", content_md5(@replication)}]
      )

    rejected = call(conn)
    assert rejected.status == 501
    assert rejected.resp_body =~ "NotImplemented"
    assert BucketConfigs.get("replicationchunked", :replication) == :none
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
