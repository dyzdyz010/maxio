defmodule Maxio.S3.AnalyticsE2ETest do
  use Maxio.DataCase, async: false

  import Plug.Conn

  alias Maxio.Auth.CredentialStore
  alias Maxio.BucketConfigs
  alias Maxio.Policy.Store
  alias Maxio.S3.Endpoint
  alias Maxio.Test.SigV4Request

  @data_dir Path.join(System.tmp_dir!(), "maxio_analytics_e2e")
  @alice_ak "AKIAANALYTICS0001"
  @alice_secret "analyticsanalytics123"
  @alice_arn "arn:aws:iam:::user/" <> @alice_ak

  @entire """
  <AnalyticsConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
    <Id>entire</Id>
    <StorageClassAnalysis />
  </AnalyticsConfiguration>
  """
  @prefix """
  <AnalyticsConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
    <Id>docs</Id>
    <Filter><Prefix>documents/</Prefix></Filter>
    <StorageClassAnalysis />
  </AnalyticsConfiguration>
  """
  @export """
  <AnalyticsConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
    <Id>export</Id>
    <StorageClassAnalysis>
      <DataExport>
        <OutputSchemaVersion>V_1</OutputSchemaVersion>
        <Destination>
          <S3BucketDestination>
            <Format>CSV</Format>
            <Bucket>arn:aws:s3:::analytics-dest</Bucket>
            <Prefix>reports/</Prefix>
          </S3BucketDestination>
        </Destination>
      </DataExport>
    </StorageClassAnalysis>
  </AnalyticsConfiguration>
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

  defp create_bucket(bucket), do: SigV4Request.signed_conn(:put, "/#{bucket}") |> call()

  defp put_analytics(bucket, id, body, opts \\ []) do
    SigV4Request.signed_conn(:put, "/#{bucket}",
      query: %{"analytics" => "", "id" => id},
      body: body,
      headers: Keyword.get(opts, :headers, [])
    )
    |> call()
  end

  defp get_analytics(bucket, id, opts \\ []) do
    SigV4Request.signed_conn(:get, "/#{bucket}",
      query: %{"analytics" => "", "id" => id},
      headers: Keyword.get(opts, :headers, [])
    )
    |> call()
  end

  defp delete_analytics(bucket, id, opts \\ []) do
    SigV4Request.signed_conn(:delete, "/#{bucket}",
      query: %{"analytics" => "", "id" => id},
      headers: Keyword.get(opts, :headers, [])
    )
    |> call()
  end

  test "put get list and delete analytics configurations by id" do
    assert create_bucket("analyticscfg").status == 200

    missing = get_analytics("analyticscfg", "entire")
    assert missing.status == 404
    assert missing.resp_body =~ "NoSuchConfiguration"

    put = put_analytics("analyticscfg", "entire", @entire)
    assert put.status == 200
    assert put.resp_body == ""

    assert {:ok, %{"Configurations" => [%{"Id" => "entire"}]}} =
             BucketConfigs.get("analyticscfg", :analytics)

    get = get_analytics("analyticscfg", "entire")
    assert get.status == 200
    assert get_resp_header(get, "content-type") |> hd() =~ "application/xml"
    assert get.resp_body =~ "<AnalyticsConfiguration"
    assert get.resp_body =~ "<StorageClassAnalysis"

    assert put_analytics("analyticscfg", "docs", @prefix).status == 200
    assert put_analytics("analyticscfg", "export", @export).status == 200

    export_get = get_analytics("analyticscfg", "export")
    assert export_get.status == 200
    assert export_get.resp_body =~ "<DataExport>"
    assert export_get.resp_body =~ "<OutputSchemaVersion>V_1</OutputSchemaVersion>"
    assert export_get.resp_body =~ "<S3BucketDestination>"
    assert export_get.resp_body =~ "<Format>CSV</Format>"
    assert export_get.resp_body =~ "<Bucket>arn:aws:s3:::analytics-dest</Bucket>"
    assert export_get.resp_body =~ "<Prefix>reports/</Prefix>"

    list =
      SigV4Request.signed_conn(:get, "/analyticscfg", query: %{"analytics" => ""})
      |> call()

    assert list.status == 200
    assert list.resp_body =~ "<ListBucketAnalyticsConfigurationResult"
    assert list.resp_body =~ "<Id>docs</Id>"
    assert list.resp_body =~ "<Id>entire</Id>"
    assert list.resp_body =~ "<Id>export</Id>"
    assert list.resp_body =~ "<DataExport>"
    assert list.resp_body =~ "<IsTruncated>false</IsTruncated>"

    deleted = delete_analytics("analyticscfg", "entire")
    assert deleted.status == 204

    assert {:ok, %{"Configurations" => configs}} = BucketConfigs.get("analyticscfg", :analytics)
    assert Enum.map(configs, & &1["Id"]) == ["docs", "export"]

    assert get_analytics("analyticscfg", "entire").status == 404
    assert get_analytics("analyticscfg", "docs").status == 200
  end

  test "list paginates at 100 configurations with continuation token" do
    assert create_bucket("analyticspage").status == 200

    configs =
      for n <- 1..101 do
        id = "cfg#{String.pad_leading(Integer.to_string(n), 3, "0")}"
        %{"Id" => id, "StorageClassAnalysis" => %{}}
      end

    assert :ok = BucketConfigs.put("analyticspage", :analytics, %{"Configurations" => configs})

    first =
      SigV4Request.signed_conn(:get, "/analyticspage", query: %{"analytics" => ""})
      |> call()

    assert first.status == 200
    assert first.resp_body =~ "<IsTruncated>true</IsTruncated>"
    assert first.resp_body =~ "<NextContinuationToken>cfg100</NextContinuationToken>"
    refute first.resp_body =~ "<Id>cfg101</Id>"

    second =
      SigV4Request.signed_conn(:get, "/analyticspage",
        query: %{"analytics" => "", "continuation-token" => "cfg100"}
      )
      |> call()

    assert second.status == 200
    assert second.resp_body =~ "<ContinuationToken>cfg100</ContinuationToken>"
    assert second.resp_body =~ "<Id>cfg101</Id>"
    assert second.resp_body =~ "<IsTruncated>false</IsTruncated>"

    invalid =
      SigV4Request.signed_conn(:get, "/analyticspage",
        query: %{"analytics" => "", "continuation-token" => "missing"}
      )
      |> call()

    assert invalid.status == 400
    assert invalid.resp_body =~ "InvalidArgument"
  end

  test "missing id mismatched XML id malformed XML and checksums fail closed" do
    assert create_bucket("analyticsbad").status == 200
    assert put_analytics("analyticsbad", "entire", @entire).status == 200

    missing_id =
      SigV4Request.signed_conn(:put, "/analyticsbad",
        query: %{"analytics" => ""},
        body: @entire
      )
      |> call()

    assert missing_id.status == 400
    assert missing_id.resp_body =~ "InvalidArgument"

    mismatch = put_analytics("analyticsbad", "docs", @entire)
    assert mismatch.status == 400
    assert mismatch.resp_body =~ "MalformedXML"

    bad_xml =
      put_analytics(
        "analyticsbad",
        "docs",
        "<AnalyticsConfiguration><Id>docs</Id><Bad /></AnalyticsConfiguration>"
      )

    assert bad_xml.status == 400
    assert bad_xml.resp_body =~ "MalformedXML"

    bad_checksum =
      put_analytics("analyticsbad", "docs", @prefix,
        headers: [
          {"x-amz-sdk-checksum-algorithm", "SHA256"},
          {"x-amz-checksum-sha256", :crypto.hash(:sha256, "different") |> Base.encode64()}
        ]
      )

    assert bad_checksum.status == 400
    assert bad_checksum.resp_body =~ "BadDigest"

    bad_content_md5 =
      put_analytics("analyticsbad", "docs", @prefix,
        headers: [{"content-md5", :crypto.hash(:md5, "different") |> Base.encode64()}]
      )

    assert bad_content_md5.status == 400
    assert bad_content_md5.resp_body =~ "BadDigest"

    assert {:ok, %{"Configurations" => [%{"Id" => "entire"}]}} =
             BucketConfigs.get("analyticsbad", :analytics)
  end

  test "checksum trailers and aws-chunked XML bodies are rejected" do
    assert create_bucket("analyticschunked").status == 200

    trailer =
      put_analytics("analyticschunked", "entire", @entire,
        headers: [
          {"x-amz-sdk-checksum-algorithm", "SHA256"},
          {"x-amz-trailer", "x-amz-checksum-sha256"}
        ]
      )

    assert trailer.status == 501
    assert trailer.resp_body =~ "NotImplemented"

    conn =
      SigV4Request.signed_chunked_conn(:put, "/analyticschunked", @entire,
        query: %{"analytics" => "", "id" => "entire"}
      )

    rejected = call(conn)
    assert rejected.status == 501
    assert rejected.resp_body =~ "NotImplemented"
    assert BucketConfigs.get("analyticschunked", :analytics) == :none
  end

  test "expected bucket owner missing bucket and method boundaries are enforced" do
    assert create_bucket("analyticsowner").status == 200
    assert put_analytics("analyticsowner", "entire", @entire).status == 200

    wrong_get =
      get_analytics("analyticsowner", "entire",
        headers: [{"x-amz-expected-bucket-owner", "999999999999"}]
      )

    assert wrong_get.status == 403
    assert wrong_get.resp_body =~ "AccessDenied"

    wrong_put =
      put_analytics("analyticsowner", "docs", @prefix,
        headers: [{"x-amz-expected-bucket-owner", "999999999999"}]
      )

    assert wrong_put.status == 403

    wrong_delete =
      delete_analytics("analyticsowner", "entire",
        headers: [{"x-amz-expected-bucket-owner", "999999999999"}]
      )

    assert wrong_delete.status == 403

    missing = put_analytics("missing-analytics", "entire", @entire)
    assert missing.status == 404
    assert missing.resp_body =~ "NoSuchBucket"

    object_get =
      SigV4Request.signed_conn(:get, "/analyticsowner/object.txt", query: %{"analytics" => ""})
      |> call()

    assert object_get.status == 405
    assert object_get.resp_body =~ "MethodNotAllowed"

    post =
      SigV4Request.signed_conn(:post, "/analyticsowner", query: %{"analytics" => ""})
      |> call()

    assert post.status == 405
  end

  test "analytics IAM actions and resource tag condition behavior match AWS action map" do
    assert create_bucket("analyticsauthz").status == 200
    assert put_analytics("analyticsauthz", "entire", @entire).status == 200

    get_policy =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:GetAnalyticsConfiguration","Resource":"arn:aws:s3:::analyticsauthz"}})

    assert :ok = Store.put_principal_policy(@alice_arn, "get-analytics-only", get_policy)

    assert (alice(:get, "/analyticsauthz", query: %{"analytics" => ""}) |> call()).status == 200

    assert (alice(:get, "/analyticsauthz", query: %{"analytics" => "", "id" => "entire"})
            |> call()).status == 200

    denied_put =
      alice(:put, "/analyticsauthz", query: %{"analytics" => "", "id" => "export"}, body: @export)
      |> call()

    assert denied_put.status == 403

    denied_delete =
      alice(:delete, "/analyticsauthz", query: %{"analytics" => "", "id" => "entire"})
      |> call()

    assert denied_delete.status == 403

    put_policy =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:PutAnalyticsConfiguration","Resource":"arn:aws:s3:::analyticsauthz"}})

    assert :ok = Store.put_principal_policy(@alice_arn, "put-analytics", put_policy)

    allowed_put =
      alice(:put, "/analyticsauthz", query: %{"analytics" => "", "id" => "export"}, body: @export)
      |> call()

    assert allowed_put.status == 200

    allowed_delete =
      alice(:delete, "/analyticsauthz", query: %{"analytics" => "", "id" => "export"})
      |> call()

    assert allowed_delete.status == 204

    tag_xml = "<Tagging><TagSet><Tag><Key>env</Key><Value>prod</Value></Tag></TagSet></Tagging>"

    assert (SigV4Request.signed_conn(:put, "/analyticsauthz",
              query: %{"tagging" => ""},
              body: tag_xml
            )
            |> call()).status == 204

    assert :ok = Store.delete_principal_policy(@alice_arn, "get-analytics-only")
    assert :ok = Store.delete_principal_policy(@alice_arn, "put-analytics")

    resource_tag_policy =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:GetAnalyticsConfiguration","Resource":"arn:aws:s3:::analyticsauthz","Condition":{"StringEquals":{"aws:ResourceTag/env":"prod"}}}})

    assert :ok =
             Store.put_principal_policy(
               @alice_arn,
               "get-analytics-resource-tag",
               resource_tag_policy
             )

    denied_by_tag_condition =
      alice(:get, "/analyticsauthz", query: %{"analytics" => "", "id" => "entire"}) |> call()

    assert denied_by_tag_condition.status == 403
  end
end
