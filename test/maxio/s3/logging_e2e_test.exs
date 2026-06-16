defmodule Maxio.S3.LoggingE2ETest do
  use Maxio.DataCase, async: false

  import Plug.Conn

  alias Maxio.Auth.CredentialStore
  alias Maxio.BucketConfigs
  alias Maxio.Policy.Store
  alias Maxio.S3.Endpoint
  alias Maxio.Test.SigV4Request

  @data_dir Path.join(System.tmp_dir!(), "maxio_logging_e2e")
  @alice_ak "AKIALOGGING0000001"
  @alice_secret "logginglogginglogging1234"
  @alice_arn "arn:aws:iam:::user/" <> @alice_ak
  @enabled """
  <BucketLoggingStatus xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
    <LoggingEnabled>
      <TargetBucket>logtarget</TargetBucket>
      <TargetPrefix>access/</TargetPrefix>
    </LoggingEnabled>
  </BucketLoggingStatus>
  """
  @partitioned """
  <BucketLoggingStatus xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
    <LoggingEnabled>
      <TargetBucket>logtarget</TargetBucket>
      <TargetPrefix></TargetPrefix>
      <TargetGrants>
        <Grant>
          <Grantee xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:type="Group">
            <URI>http://acs.amazonaws.com/groups/s3/LogDelivery</URI>
          </Grantee>
          <Permission>WRITE</Permission>
        </Grant>
      </TargetGrants>
      <TargetObjectKeyFormat>
        <PartitionedPrefix>
          <PartitionDateSource>DeliveryTime</PartitionDateSource>
        </PartitionedPrefix>
      </TargetObjectKeyFormat>
    </LoggingEnabled>
  </BucketLoggingStatus>
  """
  @partitioned_default_date """
  <BucketLoggingStatus xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
    <LoggingEnabled>
      <TargetBucket>logtarget</TargetBucket>
      <TargetPrefix>partitioned/</TargetPrefix>
      <TargetObjectKeyFormat>
        <PartitionedPrefix />
      </TargetObjectKeyFormat>
    </LoggingEnabled>
  </BucketLoggingStatus>
  """
  @disabled """
  <BucketLoggingStatus xmlns="http://s3.amazonaws.com/doc/2006-03-01/" />
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

  defp put_logging(bucket, body, opts \\ []) do
    headers =
      Keyword.get(opts, :headers, [])
      |> maybe_add_content_md5(body, Keyword.get(opts, :content_md5, true))

    SigV4Request.signed_conn(:put, "/#{bucket}",
      query: %{"logging" => ""},
      body: body,
      headers: headers
    )
    |> call()
  end

  defp create_bucket(bucket, headers \\ []) do
    SigV4Request.signed_conn(:put, "/#{bucket}", headers: headers) |> call()
  end

  defp maybe_add_content_md5(headers, _body, false), do: headers

  defp maybe_add_content_md5(headers, body, true),
    do: [{"content-md5", content_md5(body)} | headers]

  defp content_md5(body), do: :crypto.hash(:md5, body) |> Base.encode64()

  test "GetBucketLogging returns empty default and Put round-trips enabled config" do
    assert create_bucket("logsource").status == 200
    assert create_bucket("logtarget", [{"x-amz-object-ownership", "ObjectWriter"}]).status == 200

    default =
      SigV4Request.signed_conn(:get, "/logsource", query: %{"logging" => ""})
      |> call()

    assert default.status == 200
    assert get_resp_header(default, "content-type") |> hd() =~ "application/xml"
    assert default.resp_body =~ "<BucketLoggingStatus"
    refute default.resp_body =~ "<LoggingEnabled>"
    assert BucketConfigs.get("logsource", :logging) == :none

    put_enabled = put_logging("logsource", @enabled)

    assert put_enabled.status == 200
    assert put_enabled.resp_body == ""

    assert {:ok,
            %{
              "LoggingEnabled" => %{
                "TargetBucket" => "logtarget",
                "TargetPrefix" => "access/"
              }
            }} = BucketConfigs.get("logsource", :logging)

    enabled =
      SigV4Request.signed_conn(:get, "/logsource", query: %{"logging" => ""})
      |> call()

    assert enabled.status == 200
    assert enabled.resp_body =~ "<TargetBucket>logtarget</TargetBucket>"
    assert enabled.resp_body =~ "<TargetPrefix>access/</TargetPrefix>"

    partitioned = put_logging("logsource", @partitioned)

    assert partitioned.status == 200

    round_trip =
      SigV4Request.signed_conn(:get, "/logsource", query: %{"logging" => ""})
      |> call()

    assert round_trip.status == 200
    assert round_trip.resp_body =~ "<TargetPrefix></TargetPrefix>"
    assert round_trip.resp_body =~ "<TargetGrants>"
    assert round_trip.resp_body =~ "<Permission>WRITE</Permission>"
    assert round_trip.resp_body =~ "<TargetObjectKeyFormat>"
    assert round_trip.resp_body =~ "<PartitionDateSource>DeliveryTime</PartitionDateSource>"

    default_date = put_logging("logsource", @partitioned_default_date)
    assert default_date.status == 200

    default_date_get =
      SigV4Request.signed_conn(:get, "/logsource", query: %{"logging" => ""})
      |> call()

    assert default_date_get.status == 200
    assert default_date_get.resp_body =~ "<PartitionDateSource>EventTime</PartitionDateSource>"
  end

  test "empty BucketLoggingStatus disables and deletes config" do
    assert create_bucket("logdisable").status == 200
    assert create_bucket("logtarget").status == 200
    assert put_logging("logdisable", @enabled).status == 200
    assert {:ok, _config} = BucketConfigs.get("logdisable", :logging)

    disabled = put_logging("logdisable", @disabled)

    assert disabled.status == 200
    assert BucketConfigs.get("logdisable", :logging) == :none

    get =
      SigV4Request.signed_conn(:get, "/logdisable", query: %{"logging" => ""})
      |> call()

    assert get.status == 200
    refute get.resp_body =~ "<LoggingEnabled>"
  end

  test "missing source or target buckets fail without storing config" do
    missing_source = put_logging("missing-log-source", @enabled)

    assert missing_source.status == 404
    assert missing_source.resp_body =~ "NoSuchBucket"

    assert create_bucket("lognotarget").status == 200

    missing_target = put_logging("lognotarget", @enabled)

    assert missing_target.status == 400
    assert missing_target.resp_body =~ "InvalidTargetBucketForLogging"
    assert BucketConfigs.get("lognotarget", :logging) == :none
  end

  test "invalid XML and semantic errors fail closed without overwriting config" do
    assert create_bucket("logbad").status == 200
    assert create_bucket("logtarget").status == 200
    assert put_logging("logbad", @enabled).status == 200

    bad_xml =
      "<BucketLoggingStatus><LoggingEnabled><TargetBucket /></LoggingEnabled></BucketLoggingStatus>"

    bad = put_logging("logbad", bad_xml)

    assert bad.status == 400
    assert bad.resp_body =~ "MalformedXML"

    missing_prefix =
      put_logging(
        "logbad",
        """
        <BucketLoggingStatus>
          <LoggingEnabled>
            <TargetBucket>logtarget</TargetBucket>
          </LoggingEnabled>
        </BucketLoggingStatus>
        """
      )

    assert missing_prefix.status == 400
    assert missing_prefix.resp_body =~ "MalformedXML"

    bad_permission =
      put_logging(
        "logbad",
        """
        <BucketLoggingStatus>
          <LoggingEnabled>
            <TargetBucket>logtarget</TargetBucket>
            <TargetPrefix>access/</TargetPrefix>
            <TargetGrants>
              <Grant>
                <Grantee xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:type="Group">
                  <URI>http://acs.amazonaws.com/groups/s3/LogDelivery</URI>
                </Grantee>
                <Permission>DELETE</Permission>
              </Grant>
            </TargetGrants>
          </LoggingEnabled>
        </BucketLoggingStatus>
        """
      )

    assert bad_permission.status == 400
    assert bad_permission.resp_body =~ "MalformedXML"

    assert {:ok, %{"LoggingEnabled" => %{"TargetPrefix" => "access/"}}} =
             BucketConfigs.get("logbad", :logging)
  end

  test "invalid stored logging config fails closed instead of defaulting" do
    assert create_bucket("logstored").status == 200

    assert :ok =
             BucketConfigs.put("logstored", :logging, %{
               "LoggingEnabled" => %{"TargetBucket" => "", "TargetPrefix" => ""}
             })

    get =
      SigV4Request.signed_conn(:get, "/logstored", query: %{"logging" => ""})
      |> call()

    assert get.status == 500
    assert get.resp_body =~ "InternalError"
  end

  test "PutBucketLogging requires and validates Content-MD5" do
    assert create_bucket("logmd5").status == 200
    assert create_bucket("logtarget").status == 200

    missing = put_logging("logmd5", @enabled, content_md5: false)

    assert missing.status == 400
    assert missing.resp_body =~ "MissingSecurityHeader"
    assert BucketConfigs.get("logmd5", :logging) == :none

    bad =
      put_logging("logmd5", @enabled,
        headers: [{"content-md5", content_md5("different")}],
        content_md5: false
      )

    assert bad.status == 400
    assert bad.resp_body =~ "BadDigest"
    assert BucketConfigs.get("logmd5", :logging) == :none
  end

  test "PutBucketLogging validates modeled flexible checksum headers and rejects trailers" do
    assert create_bucket("logflex").status == 200
    assert create_bucket("logtarget").status == 200

    missing_value =
      put_logging("logflex", @enabled, headers: [{"x-amz-sdk-checksum-algorithm", "SHA256"}])

    assert missing_value.status == 400
    assert missing_value.resp_body =~ "InvalidRequest"
    assert BucketConfigs.get("logflex", :logging) == :none

    bad_sha256 =
      put_logging("logflex", @enabled,
        headers: [
          {"x-amz-sdk-checksum-algorithm", "SHA256"},
          {"x-amz-checksum-sha256", :crypto.hash(:sha256, "different") |> Base.encode64()}
        ]
      )

    assert bad_sha256.status == 400
    assert bad_sha256.resp_body =~ "BadDigest"
    assert BucketConfigs.get("logflex", :logging) == :none

    trailer =
      put_logging("logflex", @enabled,
        headers: [
          {"x-amz-sdk-checksum-algorithm", "SHA256"},
          {"x-amz-trailer", "x-amz-checksum-sha256"}
        ]
      )

    assert trailer.status == 501
    assert trailer.resp_body =~ "NotImplemented"
    assert BucketConfigs.get("logflex", :logging) == :none

    ok =
      put_logging("logflex", @enabled,
        headers: [
          {"x-amz-sdk-checksum-algorithm", "SHA256"},
          {"x-amz-checksum-sha256", :crypto.hash(:sha256, @enabled) |> Base.encode64()}
        ]
      )

    assert ok.status == 200

    assert {:ok, %{"LoggingEnabled" => %{"TargetBucket" => "logtarget"}}} =
             BucketConfigs.get("logflex", :logging)
  end

  test "aws-chunked XML body is rejected before storing config" do
    assert create_bucket("logchunked").status == 200
    assert create_bucket("logtarget").status == 200

    conn =
      SigV4Request.signed_chunked_conn(:put, "/logchunked", @enabled,
        query: %{"logging" => ""},
        headers: [{"content-md5", content_md5(@enabled)}]
      )

    rejected = call(conn)

    assert rejected.status == 501
    assert rejected.resp_body =~ "NotImplemented"
    assert BucketConfigs.get("logchunked", :logging) == :none
  end

  test "x-amz-expected-bucket-owner is enforced on Get and Put" do
    assert create_bucket("logowner").status == 200
    assert create_bucket("logtarget").status == 200
    assert put_logging("logowner", @enabled).status == 200

    wrong_get =
      SigV4Request.signed_conn(:get, "/logowner",
        query: %{"logging" => ""},
        headers: [{"x-amz-expected-bucket-owner", "999999999999"}]
      )
      |> call()

    assert wrong_get.status == 403
    assert wrong_get.resp_body =~ "AccessDenied"

    wrong_put =
      put_logging("logowner", @partitioned,
        headers: [{"x-amz-expected-bucket-owner", "999999999999"}]
      )

    assert wrong_put.status == 403
    assert wrong_put.resp_body =~ "AccessDenied"

    assert {:ok, %{"LoggingEnabled" => %{"TargetPrefix" => "access/"}}} =
             BucketConfigs.get("logowner", :logging)

    correct_get =
      SigV4Request.signed_conn(:get, "/logowner",
        query: %{"logging" => ""},
        headers: [{"x-amz-expected-bucket-owner", "000000000000"}]
      )
      |> call()

    assert correct_get.status == 200
  end

  test "object-level logging subresource and unsupported methods are method not allowed" do
    assert create_bucket("logmethod").status == 200

    object_get =
      SigV4Request.signed_conn(:get, "/logmethod/object.txt", query: %{"logging" => ""})
      |> call()

    assert object_get.status == 405
    assert object_get.resp_body =~ "MethodNotAllowed"

    delete =
      SigV4Request.signed_conn(:delete, "/logmethod", query: %{"logging" => ""})
      |> call()

    assert delete.status == 405
    assert delete.resp_body =~ "MethodNotAllowed"
  end

  test "GetBucketLogging and PutBucketLogging use distinct IAM actions" do
    assert create_bucket("logauthz").status == 200
    assert create_bucket("logtarget").status == 200

    get_policy =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:GetBucketLogging","Resource":"arn:aws:s3:::logauthz"}})

    assert :ok = Store.put_principal_policy(@alice_arn, "get-logging-only", get_policy)

    get = alice(:get, "/logauthz", query: %{"logging" => ""}) |> call()
    assert get.status == 200

    denied =
      alice(:put, "/logauthz",
        query: %{"logging" => ""},
        body: @enabled,
        headers: [{"content-md5", content_md5(@enabled)}]
      )
      |> call()

    assert denied.status == 403
    assert denied.resp_body =~ "AccessDenied"
    assert BucketConfigs.get("logauthz", :logging) == :none

    put_policy =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:PutBucketLogging","Resource":"arn:aws:s3:::logauthz"}})

    assert :ok = Store.put_principal_policy(@alice_arn, "put-logging", put_policy)

    allowed =
      alice(:put, "/logauthz",
        query: %{"logging" => ""},
        body: @enabled,
        headers: [{"content-md5", content_md5(@enabled)}]
      )
      |> call()

    assert allowed.status == 200

    assert {:ok, %{"LoggingEnabled" => %{"TargetBucket" => "logtarget"}}} =
             BucketConfigs.get("logauthz", :logging)
  end

  test "bucket resource tag condition can gate logging actions" do
    assert create_bucket("logtagcond").status == 200

    tag_xml = """
    <Tagging><TagSet><Tag><Key>env</Key><Value>prod</Value></Tag></TagSet></Tagging>
    """

    assert (SigV4Request.signed_conn(:put, "/logtagcond",
              query: %{"tagging" => ""},
              body: tag_xml
            )
            |> call()).status == 204

    policy =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:GetBucketLogging","Resource":"arn:aws:s3:::logtagcond","Condition":{"StringEquals":{"aws:ResourceTag/env":"prod"}}}})

    assert :ok = Store.put_principal_policy(@alice_arn, "get-logging-resource-tag", policy)

    allowed = alice(:get, "/logtagcond", query: %{"logging" => ""}) |> call()
    assert allowed.status == 200

    dev_tag_xml = """
    <Tagging><TagSet><Tag><Key>env</Key><Value>dev</Value></Tag></TagSet></Tagging>
    """

    assert (SigV4Request.signed_conn(:put, "/logtagcond",
              query: %{"tagging" => ""},
              body: dev_tag_xml
            )
            |> call()).status == 204

    denied = alice(:get, "/logtagcond", query: %{"logging" => ""}) |> call()
    assert denied.status == 403
    assert denied.resp_body =~ "AccessDenied"
  end

  test "TargetGrants are rejected when target bucket uses BucketOwnerEnforced" do
    assert create_bucket("loggrantsource").status == 200
    assert create_bucket("logtarget").status == 200

    rejected = put_logging("loggrantsource", @partitioned)

    assert rejected.status == 400
    assert rejected.resp_body =~ "InvalidTargetBucketForLogging"
    assert BucketConfigs.get("loggrantsource", :logging) == :none
  end
end
