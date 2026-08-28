defmodule Maxio.S3.LoggingE2ETest do
  use Maxio.DataCase, async: false

  import ExUnit.CaptureLog
  import Plug.Conn

  alias Ecto.Changeset
  alias Maxio.Auth.CredentialStore
  alias Maxio.{BucketQuota, Buckets, Listing, ObjectMeta, Objects}
  alias Maxio.BucketConfigs
  alias Maxio.Policy.Store
  alias Maxio.Repo
  alias Maxio.S3.{Endpoint, ObjectLock}
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
    %{user_arn: @alice_arn} =
      create_user_with_access_key!(
        user_name: @alice_ak,
        access_key_id: @alice_ak,
        secret_key: @alice_secret
      )

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

  defp put_object(bucket, key, body, headers \\ []) do
    SigV4Request.signed_conn(:put, "/#{bucket}/#{key}", body: body, headers: headers) |> call()
  end

  defp logging_enabled(target, prefix \\ "access/") do
    """
    <BucketLoggingStatus xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
      <LoggingEnabled>
        <TargetBucket>#{target}</TargetBucket>
        <TargetPrefix>#{prefix}</TargetPrefix>
      </LoggingEnabled>
    </BucketLoggingStatus>
    """
  end

  defp log_entry_containing(bucket, prefix, needles) do
    bucket
    |> log_objects(prefix)
    |> Enum.find_value(fn object ->
      body = read_object(bucket, object.key, object.version_id)

      if Enum.all?(needles, &String.contains?(body, &1)) do
        {object, body}
      end
    end) ||
      flunk("expected access log under #{bucket}/#{prefix} containing #{inspect(needles)}")
  end

  defp log_object_count(bucket, prefix), do: bucket |> log_objects(prefix) |> length()

  defp log_objects(bucket, prefix) do
    bucket
    |> Objects.list_objects_v2(%{prefix: prefix, max_keys: 1000})
    |> Map.fetch!(:objects)
  end

  defp storage_keys(bucket) do
    Listing.scan_keys(bucket, ObjectMeta.put_effective_topology(data_dir: @data_dir))
  end

  defp read_object(bucket, key, version_id) do
    query = if version_id in [nil, "null"], do: %{}, else: %{"versionId" => version_id}

    get =
      SigV4Request.signed_conn(:get, "/#{bucket}/#{key}", query: query)
      |> call()

    assert get.status == 200
    get.resp_body
  end

  defp maybe_add_content_md5(headers, _body, false), do: headers

  defp maybe_add_content_md5(headers, body, true),
    do: [{"content-md5", content_md5(body)} | headers]

  defp content_md5(body), do: :crypto.hash(:md5, body) |> Base.encode64()

  defp with_sidecar_write_authority(fun) do
    previous = Application.get_env(:maxio, :authoritative_source)

    Application.put_env(
      :maxio,
      :authoritative_source,
      Keyword.put(previous || [], :write, :sidecar)
    )

    try do
      fun.()
    after
      if previous,
        do: Application.put_env(:maxio, :authoritative_source, previous),
        else: Application.delete_env(:maxio, :authoritative_source)
    end
  end

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

  test "server access logging delivers simple-prefix objects for source requests" do
    assert create_bucket("logsource").status == 200
    assert create_bucket("logtarget").status == 200
    assert put_logging("logsource", @enabled).status == 200

    put = put_object("logsource", "photos/cat.txt", "hello log", [{"content-type", "text/plain"}])

    assert put.status == 200

    {log_object, body} =
      log_entry_containing("logtarget", "access/", [
        "logsource",
        "put_object",
        "photos/cat.txt",
        " 200 "
      ])

    assert Regex.match?(
             ~r/^access\/\d{4}-\d{2}-\d{2}-\d{2}-\d{2}-\d{2}-[A-Za-z0-9_-]+\.log$/,
             log_object.key
           )

    assert log_object.version_id == "null"
    assert log_object.content_type == "text/plain"
    assert log_object.metadata == %{"maxio-log-source-bucket" => "logsource"}
    assert body =~ ~s("PUT /logsource/photos/cat.txt HTTP/1.1")
  end

  test "server access logging uses target bucket default SSE-S3 encryption" do
    assert create_bucket("logsource").status == 200
    assert create_bucket("logtarget").status == 200

    assert :ok =
             BucketConfigs.put("logtarget", :encryption, %{
               "algorithm" => "AES256",
               "bucket_key_enabled" => false
             })

    assert put_logging("logsource", @enabled).status == 200

    put = put_object("logsource", "encrypted-log-target.txt", "hello encrypted log")

    assert put.status == 200

    {log_object, body} =
      log_entry_containing("logtarget", "access/", [
        "put_object",
        "encrypted-log-target.txt",
        " 200 "
      ])

    assert log_object.sse_algorithm == "AES256"
    assert is_map(log_object.sse_envelope)
    assert Map.has_key?(log_object.sse_envelope, "wrapped_dek_b64")
    assert body =~ ~s("PUT /logsource/encrypted-log-target.txt HTTP/1.1")
  end

  test "server access logging records S3 error codes for failed source requests" do
    assert create_bucket("logsource").status == 200
    assert create_bucket("logtarget").status == 200
    assert put_logging("logsource", @enabled).status == 200

    denied = alice(:put, "/logsource/denied.txt", body: "blocked") |> call()

    assert denied.status == 403
    assert denied.resp_body =~ "AccessDenied"

    {_log_object, body} =
      log_entry_containing("logtarget", "access/", [
        "denied.txt",
        " 403 "
      ])

    assert body =~ "AccessDenied"
    assert body =~ ~s("PUT /logsource/denied.txt HTTP/1.1")
  end

  test "server access logging honors partitioned prefix target grants and target versioning" do
    assert create_bucket("logsource").status == 200
    assert create_bucket("logtarget", [{"x-amz-object-ownership", "ObjectWriter"}]).status == 200
    assert :ok = Buckets.put_versioning("logtarget", "Enabled", nil)
    assert put_logging("logsource", @partitioned).status == 200

    put = put_object("logsource", "partitioned-object.txt", "hello partitioned")

    assert put.status == 200

    {log_object, body} =
      log_entry_containing("logtarget", "000000000000/us-east-1/logsource/", [
        "put_object",
        "partitioned-object.txt",
        " 200 "
      ])

    assert Regex.match?(
             ~r/^000000000000\/us-east-1\/logsource\/\d{4}\/\d{2}\/\d{2}\/\d{4}-\d{2}-\d{2}-\d{2}-\d{2}-\d{2}-[A-Za-z0-9_-]+\.log$/,
             log_object.key
           )

    assert log_object.version_id != "null"
    assert log_object.acl_canned == "custom"

    assert [
             %{
               "grantee" => %{
                 "type" => "Group",
                 "uri" => "http://acs.amazonaws.com/groups/s3/LogDelivery"
               },
               "permission" => "WRITE"
             }
           ] = log_object.acl_grants["grants"]

    assert body =~ "SigV4"
  end

  test "server access log delivery is best-effort when target quota rejects metadata commit" do
    assert create_bucket("logsource").status == 200
    assert create_bucket("logtarget").status == 200
    assert put_logging("logsource", @enabled).status == 200

    initial_count = log_object_count("logtarget", "access/")
    initial_storage_keys = storage_keys("logtarget")
    assert initial_count > 0
    assert :ok = BucketQuota.put_hard("logtarget", 1)

    log =
      capture_log([level: :error], fn ->
        response = put_object("logsource", "quota-survives.txt", "ok")
        send(self(), {:quota_logging_response, response})
      end)

    assert_receive {:quota_logging_response, response}
    assert response.status == 200
    assert {:ok, _object} = Objects.get_metadata("logsource", "quota-survives.txt")
    assert log =~ "server access log metadata commit failed"
    assert log =~ "XMinioAdminBucketQuotaExceeded"
    assert log_object_count("logtarget", "access/") == initial_count
    assert storage_keys("logtarget") == initial_storage_keys
  end

  test "PutBucketLogging rejects target buckets that S3 server access logging does not allow" do
    scenarios = [
      {"cross-region", "logputregsrc", "logputregtarget",
       fn target ->
         {:ok, _bucket} =
           Buckets.create(target, "arn:aws:iam:::root", region: "eu-west-1")

         :ok
       end, "Cross S3 location logging not allowed"},
      {"requester-pays", "logputrpsource", "logputrptarget",
       fn target ->
         assert create_bucket(target).status == 200
         BucketConfigs.put(target, :request_payment, %{"Payer" => "Requester"})
       end, "Requester Pays"},
      {"object-lock", "logputlocksource", "logputlocktarget",
       fn target ->
         assert create_bucket(target).status == 200
         ObjectLock.enable_bucket!(target)
       end, "Object Lock"}
    ]

    for {_label, source, target, setup_target, expected_message} <- scenarios do
      assert create_bucket(source).status == 200
      assert :ok = setup_target.(target)

      rejected = put_logging(source, logging_enabled(target))

      assert rejected.status == 400
      assert rejected.resp_body =~ "InvalidTargetBucketForLogging"
      assert rejected.resp_body =~ expected_message
      assert BucketConfigs.get(source, :logging) == :none
    end
  end

  test "server access log delivery cleans sidecar-authority bytes when target quota rejects metadata" do
    with_sidecar_write_authority(fn ->
      assert create_bucket("logsidecarsource").status == 200
      assert create_bucket("logsidecartarget").status == 200
      assert put_logging("logsidecarsource", logging_enabled("logsidecartarget")).status == 200

      initial_count = log_object_count("logsidecartarget", "access/")
      initial_storage_keys = storage_keys("logsidecartarget")
      assert initial_count > 0
      assert :ok = BucketQuota.put_hard("logsidecartarget", 1)

      log =
        capture_log([level: :error], fn ->
          response = put_object("logsidecarsource", "quota-sidecar-survives.txt", "ok")
          send(self(), {:sidecar_quota_logging_response, response})
        end)

      assert_receive {:sidecar_quota_logging_response, response}
      assert response.status == 200

      assert {:ok, _object} =
               Objects.get_metadata("logsidecarsource", "quota-sidecar-survives.txt")

      assert log =~ "server access log metadata commit failed"
      assert log =~ "XMinioAdminBucketQuotaExceeded"
      assert log_object_count("logsidecartarget", "access/") == initial_count
      assert storage_keys("logsidecartarget") == initial_storage_keys
    end)
  end

  test "server access log delivery skips target states that drift after configuration" do
    scenarios = [
      {"cross-region", "logregsource", "logregtarget",
       fn target ->
         {:ok, bucket} = Buckets.lookup(target)

         bucket
         |> Changeset.change(region: "eu-west-1")
         |> Repo.update!()

         :ok
       end, "target_region_mismatch"},
      {"requester-pays", "logrpsource", "logrptarget",
       fn target -> BucketConfigs.put(target, :request_payment, %{"Payer" => "Requester"}) end,
       "target_requester_pays_enabled"},
      {"object-lock", "loglocksource", "loglocktarget",
       fn target -> ObjectLock.enable_bucket!(target) end, "target_object_lock_enabled"},
      {"kms", "logkmssource", "logkmstarget",
       fn target ->
         BucketConfigs.put(target, :encryption, %{
           "algorithm" => "aws:kms",
           "kms_key_id" => "alias/maxio/logging",
           "bucket_key_enabled" => false
         })
       end, "unsupported_target_encryption"},
      {"dsse", "logdssesource", "logdssetarget",
       fn target ->
         BucketConfigs.put(target, :encryption, %{
           "algorithm" => "aws:kms:dsse",
           "kms_key_id" => "alias/maxio/logging",
           "bucket_key_enabled" => false
         })
       end, "unsupported_target_encryption"}
    ]

    for {label, source, target, setup_target, expected_reason} <- scenarios do
      assert create_bucket(source).status == 200
      assert create_bucket(target).status == 200
      assert put_logging(source, logging_enabled(target)).status == 200

      initial_count = log_object_count(target, "access/")
      initial_storage_keys = storage_keys(target)
      assert initial_count > 0
      assert :ok = setup_target.(target)

      log =
        capture_log([level: :warning], fn ->
          response = put_object(source, "#{label}.txt", "source request survives")
          send(self(), {:unsupported_logging_target_response, label, response})
        end)

      assert_receive {:unsupported_logging_target_response, ^label, response}
      assert response.status == 200
      assert log =~ expected_reason
      assert log_object_count(target, "access/") == initial_count
      assert storage_keys(target) == initial_storage_keys
    end
  end

  test "server access log delivery skips corrupt stored TargetGrants instead of dropping them" do
    assert create_bucket("logstoredgrantsrc").status == 200

    assert create_bucket("logstoredgranttarget", [{"x-amz-object-ownership", "ObjectWriter"}]).status ==
             200

    assert :ok =
             BucketConfigs.put("logstoredgrantsrc", :logging, %{
               "LoggingEnabled" => %{
                 "TargetBucket" => "logstoredgranttarget",
                 "TargetPrefix" => "access/",
                 "TargetGrants" => [
                   %{
                     "Grantee" => %{
                       "type" => "Group",
                       "URI" => "http://example.com/not-a-supported-s3-group"
                     },
                     "Permission" => "WRITE"
                   }
                 ],
                 "TargetObjectKeyFormat" => %{"type" => "simple"}
               }
             })

    log =
      capture_log([level: :warning], fn ->
        response =
          put_object("logstoredgrantsrc", "corrupt-grants.txt", "source request survives")

        send(self(), {:corrupt_target_grants_response, response})
      end)

    assert_receive {:corrupt_target_grants_response, response}
    assert response.status == 200
    assert log =~ "invalid_logging_config"
    assert log_object_count("logstoredgranttarget", "access/") == 0
    assert storage_keys("logstoredgranttarget") == []
  end

  test "server access log delivery rechecks TargetGrants against current object ownership" do
    assert create_bucket("loggrantsrc").status == 200

    assert create_bucket("loggranttarget", [{"x-amz-object-ownership", "ObjectWriter"}]).status ==
             200

    assert put_logging(
             "loggrantsrc",
             String.replace(@partitioned, "logtarget", "loggranttarget")
           ).status == 200

    initial_count = log_object_count("loggranttarget", "000000000000/us-east-1/loggrantsrc/")
    initial_storage_keys = storage_keys("loggranttarget")
    assert initial_count > 0

    assert :ok =
             BucketConfigs.put("loggranttarget", :ownership_controls, %{
               "ObjectOwnership" => "BucketOwnerEnforced"
             })

    log =
      capture_log([level: :warning], fn ->
        response = put_object("loggrantsrc", "after-boe.txt", "source request survives")
        send(self(), {:target_grants_boe_response, response})
      end)

    assert_receive {:target_grants_boe_response, response}
    assert response.status == 200
    assert log =~ "target_grants_with_bucket_owner_enforced"

    assert log_object_count("loggranttarget", "000000000000/us-east-1/loggrantsrc/") ==
             initial_count

    assert storage_keys("loggranttarget") == initial_storage_keys
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

    assert create_bucket("logbadacl", [{"x-amz-object-ownership", "ObjectWriter"}]).status == 200

    bad_cases = [
      {"empty target bucket",
       """
       <BucketLoggingStatus>
         <LoggingEnabled>
           <TargetBucket />
           <TargetPrefix>access/</TargetPrefix>
         </LoggingEnabled>
       </BucketLoggingStatus>
       """},
      {"missing target prefix",
       """
       <BucketLoggingStatus>
         <LoggingEnabled>
           <TargetBucket>logtarget</TargetBucket>
         </LoggingEnabled>
       </BucketLoggingStatus>
       """},
      {"nested target bucket text",
       """
       <BucketLoggingStatus>
         <LoggingEnabled>
           <TargetBucket><Name>logtarget</Name></TargetBucket>
           <TargetPrefix>access/</TargetPrefix>
         </LoggingEnabled>
       </BucketLoggingStatus>
       """},
      {"unsupported permission",
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
       """},
      {"logging grant acl permission",
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
               <Permission>READ_ACP</Permission>
             </Grant>
           </TargetGrants>
         </LoggingEnabled>
       </BucketLoggingStatus>
       """},
      {"unsupported email grantee",
       """
       <BucketLoggingStatus>
         <LoggingEnabled>
           <TargetBucket>logtarget</TargetBucket>
           <TargetPrefix>access/</TargetPrefix>
           <TargetGrants>
             <Grant>
               <Grantee xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:type="AmazonCustomerByEmail">
                 <EmailAddress>owner@example.com</EmailAddress>
               </Grantee>
               <Permission>READ</Permission>
             </Grant>
           </TargetGrants>
         </LoggingEnabled>
       </BucketLoggingStatus>
       """},
      {"empty target grants",
       """
       <BucketLoggingStatus>
         <LoggingEnabled>
           <TargetBucket>logtarget</TargetBucket>
           <TargetPrefix>access/</TargetPrefix>
           <TargetGrants />
         </LoggingEnabled>
       </BucketLoggingStatus>
       """},
      {"duplicate key format variants",
       """
       <BucketLoggingStatus>
         <LoggingEnabled>
           <TargetBucket>logtarget</TargetBucket>
           <TargetPrefix>access/</TargetPrefix>
           <TargetObjectKeyFormat>
             <SimplePrefix />
             <PartitionedPrefix>
               <PartitionDateSource>DeliveryTime</PartitionDateSource>
             </PartitionedPrefix>
           </TargetObjectKeyFormat>
         </LoggingEnabled>
       </BucketLoggingStatus>
       """},
      {"invalid partition date source",
       """
       <BucketLoggingStatus>
         <LoggingEnabled>
           <TargetBucket>logtarget</TargetBucket>
           <TargetPrefix>access/</TargetPrefix>
           <TargetObjectKeyFormat>
             <PartitionedPrefix>
               <PartitionDateSource>deliverytime</PartitionDateSource>
             </PartitionedPrefix>
           </TargetObjectKeyFormat>
         </LoggingEnabled>
       </BucketLoggingStatus>
       """},
      {"unsupported group uri",
       """
       <BucketLoggingStatus>
         <LoggingEnabled>
           <TargetBucket>logbadacl</TargetBucket>
           <TargetPrefix>access/</TargetPrefix>
           <TargetGrants>
             <Grant>
               <Grantee xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:type="Group">
                 <URI>http://example.com/not-a-supported-s3-group</URI>
               </Grantee>
               <Permission>WRITE</Permission>
             </Grant>
           </TargetGrants>
         </LoggingEnabled>
       </BucketLoggingStatus>
       """}
    ]

    for {label, xml} <- bad_cases do
      bad = put_logging("logbad", xml)

      assert bad.status == 400, label
      assert bad.resp_body =~ "MalformedXML"

      assert {:ok, %{"LoggingEnabled" => %{"TargetPrefix" => "access/"}}} =
               BucketConfigs.get("logbad", :logging)
    end

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

  test "PutBucketLogging validates modeled flexible checksum headers and trailers" do
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

    plain_trailer =
      put_logging("logflex", @enabled,
        headers: [
          {"x-amz-sdk-checksum-algorithm", "SHA256"},
          {"x-amz-trailer", "x-amz-checksum-sha256"}
        ]
      )

    assert plain_trailer.status == 400
    assert plain_trailer.resp_body =~ "InvalidRequest"
    assert BucketConfigs.get("logflex", :logging) == :none

    bare_non_checksum_trailer =
      put_logging("logflex", @enabled,
        headers: [{"x-amz-trailer", "x-amz-meta-not-a-checksum"}],
        content_md5: false
      )

    assert bare_non_checksum_trailer.status == 400
    assert bare_non_checksum_trailer.resp_body =~ "MissingSecurityHeader"
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

  test "aws-chunked XML body is decoded and checksum-validated before storing config" do
    assert create_bucket("logchunked").status == 200
    assert create_bucket("logtarget").status == 200

    bad =
      SigV4Request.signed_chunked_conn(:put, "/logchunked", @enabled,
        query: %{"logging" => ""},
        headers: [
          {"x-amz-sdk-checksum-algorithm", "SHA256"},
          {"content-md5", content_md5(@enabled)}
        ],
        trailer_headers: [
          {"x-amz-checksum-sha256", :crypto.hash(:sha256, "different") |> Base.encode64()}
        ]
      )
      |> call()

    assert bad.status == 400
    assert bad.resp_body =~ "BadDigest"
    assert BucketConfigs.get("logchunked", :logging) == :none

    ok_trailer =
      SigV4Request.signed_chunked_conn(:put, "/logchunked", @enabled,
        query: %{"logging" => ""},
        headers: [{"x-amz-sdk-checksum-algorithm", "SHA256"}],
        trailer_headers: [
          {"x-amz-checksum-sha256", :crypto.hash(:sha256, @enabled) |> Base.encode64()}
        ]
      )
      |> call()

    assert ok_trailer.status == 200

    assert {:ok, %{"LoggingEnabled" => %{"TargetBucket" => "logtarget"}}} =
             BucketConfigs.get("logchunked", :logging)

    oversized = String.duplicate("x", 131_073)

    too_large =
      SigV4Request.signed_chunked_conn(:put, "/logchunked", oversized,
        query: %{"logging" => ""},
        chunk_size: byte_size(oversized),
        decoded_length_override: 131_072,
        headers: [{"content-md5", content_md5(oversized)}]
      )
      |> call()

    assert too_large.status == 400
    assert too_large.resp_body =~ "MalformedXML"
    assert too_large.resp_body =~ "BucketLoggingStatus exceeds 128KB"

    assert {:ok, %{"LoggingEnabled" => %{"TargetBucket" => "logtarget"}}} =
             BucketConfigs.get("logchunked", :logging)

    ok =
      SigV4Request.signed_chunked_conn(:put, "/logchunked", @enabled,
        query: %{"logging" => ""},
        headers: [{"content-md5", content_md5(@enabled)}]
      )
      |> call()

    assert ok.status == 200

    assert {:ok, %{"LoggingEnabled" => %{"TargetBucket" => "logtarget"}}} =
             BucketConfigs.get("logchunked", :logging)
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
