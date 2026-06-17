defmodule Maxio.S3.ObjectLockE2ETest do
  use Maxio.DataCase, async: false

  import Plug.Conn

  alias Maxio.Auth.CredentialStore
  alias Maxio.BucketConfigs
  alias Maxio.Policy.Store
  alias Maxio.S3.Endpoint
  alias Maxio.Test.SigV4Request

  @data_dir Path.join(System.tmp_dir!(), "maxio_object_lock_e2e")
  @alice_ak "AKIAOBJECTLOCK01"
  @alice_secret "objectlockobjectlock123"
  @alice_arn "arn:aws:iam:::user/" <> @alice_ak

  @enabled """
  <ObjectLockConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
    <ObjectLockEnabled>Enabled</ObjectLockEnabled>
  </ObjectLockConfiguration>
  """

  @governance """
  <ObjectLockConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
    <ObjectLockEnabled>Enabled</ObjectLockEnabled>
    <Rule>
      <DefaultRetention>
        <Mode>GOVERNANCE</Mode>
        <Days>7</Days>
      </DefaultRetention>
    </Rule>
  </ObjectLockConfiguration>
  """

  @compliance """
  <ObjectLockConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
    <ObjectLockEnabled>Enabled</ObjectLockEnabled>
    <Rule>
      <DefaultRetention>
        <Mode>COMPLIANCE</Mode>
        <Years>1</Years>
      </DefaultRetention>
    </Rule>
  </ObjectLockConfiguration>
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

  defp create_bucket(bucket, headers \\ []) do
    SigV4Request.signed_conn(:put, "/#{bucket}", headers: headers) |> call()
  end

  defp alice_create_bucket(bucket, headers) do
    alice(:put, "/#{bucket}", headers: headers) |> call()
  end

  defp put_object_lock(bucket, body, opts \\ []) do
    headers =
      Keyword.get(opts, :headers, [])
      |> maybe_add_content_md5(body, Keyword.get(opts, :content_md5, true))

    SigV4Request.signed_conn(:put, "/#{bucket}",
      query: %{"object-lock" => ""},
      body: body,
      headers: headers
    )
    |> call()
  end

  defp get_object_lock(bucket, opts \\ []) do
    SigV4Request.signed_conn(:get, "/#{bucket}",
      query: %{"object-lock" => ""},
      headers: Keyword.get(opts, :headers, [])
    )
    |> call()
  end

  defp suspend_versioning(bucket) do
    body = "<VersioningConfiguration><Status>Suspended</Status></VersioningConfiguration>"

    SigV4Request.signed_conn(:put, "/#{bucket}",
      query: %{"versioning" => ""},
      body: body
    )
    |> call()
  end

  defp maybe_add_content_md5(headers, _body, false), do: headers

  defp maybe_add_content_md5(headers, body, true),
    do: [{"content-md5", content_md5(body)} | headers]

  defp content_md5(body), do: :crypto.hash(:md5, body) |> Base.encode64()
  defp content_sha256(body), do: :crypto.hash(:sha256, body) |> Base.encode64()

  defp put_object(bucket, key, body, opts \\ []) do
    SigV4Request.signed_conn(:put, "/#{bucket}/#{key}",
      body: body,
      headers: Keyword.get(opts, :headers, [])
    )
    |> call()
  end

  defp get_object(bucket, key, opts) do
    SigV4Request.signed_conn(:get, "/#{bucket}/#{key}",
      query: Keyword.get(opts, :query, %{}),
      headers: Keyword.get(opts, :headers, [])
    )
    |> call()
  end

  defp head_object(bucket, key, opts) do
    SigV4Request.signed_conn(:head, "/#{bucket}/#{key}",
      query: Keyword.get(opts, :query, %{}),
      headers: Keyword.get(opts, :headers, [])
    )
    |> call()
  end

  defp delete_object(bucket, key, opts) do
    SigV4Request.signed_conn(:delete, "/#{bucket}/#{key}",
      query: Keyword.get(opts, :query, %{}),
      headers: Keyword.get(opts, :headers, [])
    )
    |> call()
  end

  defp put_retention(bucket, key, xml, opts) do
    headers =
      Keyword.get(opts, :headers, [])
      |> maybe_add_content_md5(xml, Keyword.get(opts, :content_md5, true))

    query = Map.merge(%{"retention" => ""}, Keyword.get(opts, :query, %{}))

    SigV4Request.signed_conn(:put, "/#{bucket}/#{key}",
      query: query,
      body: xml,
      headers: headers
    )
    |> call()
  end

  defp get_retention(bucket, key, opts) do
    query = Map.merge(%{"retention" => ""}, Keyword.get(opts, :query, %{}))

    SigV4Request.signed_conn(:get, "/#{bucket}/#{key}", query: query)
    |> call()
  end

  defp put_legal_hold(bucket, key, xml, opts) do
    headers =
      Keyword.get(opts, :headers, [])
      |> maybe_add_content_md5(xml, Keyword.get(opts, :content_md5, true))

    query = Map.merge(%{"legal-hold" => ""}, Keyword.get(opts, :query, %{}))

    SigV4Request.signed_conn(:put, "/#{bucket}/#{key}",
      query: query,
      body: xml,
      headers: headers
    )
    |> call()
  end

  defp get_legal_hold(bucket, key, opts) do
    query = Map.merge(%{"legal-hold" => ""}, Keyword.get(opts, :query, %{}))

    SigV4Request.signed_conn(:get, "/#{bucket}/#{key}", query: query)
    |> call()
  end

  defp retention_xml(mode, retain_until) do
    """
    <Retention xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
      <Mode>#{mode}</Mode>
      <RetainUntilDate>#{retain_until}</RetainUntilDate>
    </Retention>
    """
  end

  defp legal_hold_xml(status) do
    """
    <LegalHold xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
      <Status>#{status}</Status>
    </LegalHold>
    """
  end

  defp assert_iso8601_equal(actual, expected) do
    {:ok, actual_dt, 0} = DateTime.from_iso8601(actual)
    {:ok, expected_dt, 0} = DateTime.from_iso8601(expected)
    assert DateTime.compare(actual_dt, expected_dt) == :eq
  end

  test "create bucket object lock enables versioning and allows put/get default retention" do
    assert create_bucket("lockcfg", [{"x-amz-bucket-object-lock-enabled", "true"}]).status == 200

    get = get_object_lock("lockcfg")
    assert get.status == 200
    assert get.resp_body =~ "<ObjectLockEnabled>Enabled</ObjectLockEnabled>"

    assert put_object_lock("lockcfg", @governance).status == 200

    assert {:ok, %{"Rule" => %{"DefaultRetention" => %{"Mode" => "GOVERNANCE", "Days" => 7}}}} =
             BucketConfigs.get("lockcfg", :object_lock)

    roundtrip = get_object_lock("lockcfg")
    assert roundtrip.status == 200
    assert roundtrip.resp_body =~ "<Mode>GOVERNANCE</Mode>"
    assert roundtrip.resp_body =~ "<Days>7</Days>"

    assert put_object_lock("lockcfg", @compliance).status == 200
    assert get_object_lock("lockcfg").resp_body =~ "<Years>1</Years>"

    suspended = suspend_versioning("lockcfg")
    assert suspended.status == 409
    assert suspended.resp_body =~ "InvalidBucketState"
  end

  test "missing config missing bucket expected owner and method boundaries are enforced" do
    assert create_bucket("lockplain").status == 200

    missing_config = get_object_lock("lockplain")
    assert missing_config.status == 404
    assert missing_config.resp_body =~ "ObjectLockConfigurationNotFoundError"

    disabled_put = put_object_lock("lockplain", @enabled)
    assert disabled_put.status == 409
    assert disabled_put.resp_body =~ "InvalidBucketState"
    assert BucketConfigs.get("lockplain", :object_lock) == :none

    missing_bucket = get_object_lock("missing-lock")
    assert missing_bucket.status == 404
    assert missing_bucket.resp_body =~ "NoSuchBucket"

    assert create_bucket("lockowner", [{"x-amz-bucket-object-lock-enabled", "true"}]).status ==
             200

    wrong_get =
      get_object_lock("lockowner", headers: [{"x-amz-expected-bucket-owner", "999999999999"}])

    assert wrong_get.status == 403

    wrong_put =
      put_object_lock("lockowner", @governance,
        headers: [{"x-amz-expected-bucket-owner", "999999999999"}]
      )

    assert wrong_put.status == 403

    object_get =
      SigV4Request.signed_conn(:get, "/lockowner/key", query: %{"object-lock" => ""})
      |> call()

    assert object_get.status == 405

    delete =
      SigV4Request.signed_conn(:delete, "/lockowner", query: %{"object-lock" => ""}) |> call()

    assert delete.status == 405
  end

  test "bad XML and checksum failures do not overwrite existing object lock config" do
    assert create_bucket("lockbad", [{"x-amz-bucket-object-lock-enabled", "true"}]).status == 200
    assert put_object_lock("lockbad", @governance).status == 200

    missing_md5 = put_object_lock("lockbad", @compliance, content_md5: false)
    assert missing_md5.status == 400
    assert missing_md5.resp_body =~ "MissingSecurityHeader"

    bad_md5 =
      put_object_lock("lockbad", @compliance,
        headers: [{"content-md5", content_md5("different")}],
        content_md5: false
      )

    assert bad_md5.status == 400
    assert bad_md5.resp_body =~ "BadDigest"

    missing_modeled_checksum =
      put_object_lock("lockbad", @compliance,
        headers: [{"x-amz-sdk-checksum-algorithm", "SHA256"}]
      )

    assert missing_modeled_checksum.status == 400
    assert missing_modeled_checksum.resp_body =~ "InvalidRequest"

    bad_modeled_checksum =
      put_object_lock("lockbad", @compliance,
        headers: [
          {"x-amz-sdk-checksum-algorithm", "SHA256"},
          {"x-amz-checksum-sha256", content_sha256("different")}
        ]
      )

    assert bad_modeled_checksum.status == 400
    assert bad_modeled_checksum.resp_body =~ "BadDigest"

    good_modeled_checksum =
      put_object_lock("lockbad", @compliance,
        headers: [
          {"x-amz-sdk-checksum-algorithm", "SHA256"},
          {"x-amz-checksum-sha256", content_sha256(@compliance)}
        ]
      )

    assert good_modeled_checksum.status == 200

    assert {:ok, %{"Rule" => %{"DefaultRetention" => %{"Years" => 1}}}} =
             BucketConfigs.get("lockbad", :object_lock)

    bad_xml =
      put_object_lock(
        "lockbad",
        "<ObjectLockConfiguration><ObjectLockEnabled>Enabled</ObjectLockEnabled><Rule><DefaultRetention><Mode>GOVERNANCE</Mode><Days>1</Days><Years>1</Years></DefaultRetention></Rule></ObjectLockConfiguration>"
      )

    assert bad_xml.status == 400
    assert bad_xml.resp_body =~ "MalformedXML"

    assert {:ok, %{"Rule" => %{"DefaultRetention" => %{"Years" => 1}}}} =
             BucketConfigs.get("lockbad", :object_lock)
  end

  test "checksum trailers and aws-chunked XML bodies are rejected" do
    assert create_bucket("lockchunked", [{"x-amz-bucket-object-lock-enabled", "true"}]).status ==
             200

    trailer =
      put_object_lock("lockchunked", @governance,
        headers: [
          {"x-amz-sdk-checksum-algorithm", "SHA256"},
          {"x-amz-trailer", "x-amz-checksum-sha256"}
        ]
      )

    assert trailer.status == 501
    assert trailer.resp_body =~ "NotImplemented"

    conn =
      SigV4Request.signed_chunked_conn(:put, "/lockchunked", @governance,
        query: %{"object-lock" => ""},
        headers: [{"content-md5", content_md5(@governance)}]
      )

    rejected = call(conn)
    assert rejected.status == 501
    assert rejected.resp_body =~ "NotImplemented"

    assert {:ok, %{"ObjectLockEnabled" => "Enabled"}} =
             BucketConfigs.get("lockchunked", :object_lock)
  end

  test "object lock IAM actions match action map" do
    assert create_bucket("lockauthz", [{"x-amz-bucket-object-lock-enabled", "true"}]).status ==
             200

    get_policy =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:GetBucketObjectLockConfiguration","Resource":"arn:aws:s3:::lockauthz"}})

    assert :ok = Store.put_principal_policy(@alice_arn, "get-object-lock-only", get_policy)

    assert (alice(:get, "/lockauthz", query: %{"object-lock" => ""}) |> call()).status == 200

    denied_put =
      alice(:put, "/lockauthz",
        query: %{"object-lock" => ""},
        body: @governance,
        headers: [{"content-md5", content_md5(@governance)}]
      )
      |> call()

    assert denied_put.status == 403

    assert :ok = Store.delete_principal_policy(@alice_arn, "get-object-lock-only")

    put_policy =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:PutBucketObjectLockConfiguration","Resource":"arn:aws:s3:::lockauthz"}})

    assert :ok = Store.put_principal_policy(@alice_arn, "put-object-lock", put_policy)

    allowed_put =
      alice(:put, "/lockauthz",
        query: %{"object-lock" => ""},
        body: @governance,
        headers: [{"content-md5", content_md5(@governance)}]
      )
      |> call()

    assert allowed_put.status == 200

    denied_get = alice(:get, "/lockauthz", query: %{"object-lock" => ""}) |> call()
    assert denied_get.status == 403
  end

  test "create bucket with object lock header requires additional object lock permission" do
    create_policy =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:CreateBucket","Resource":"arn:aws:s3:::lockcreateauthz"}})

    assert :ok = Store.put_principal_policy(@alice_arn, "create-lock-bucket", create_policy)

    denied =
      alice_create_bucket("lockcreateauthz", [{"x-amz-bucket-object-lock-enabled", "true"}])

    assert denied.status == 403

    object_lock_policy =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:PutBucketObjectLockConfiguration","Resource":"arn:aws:s3:::lockcreateauthz"}})

    assert :ok =
             Store.put_principal_policy(@alice_arn, "create-lock-object-lock", object_lock_policy)

    allowed =
      alice_create_bucket("lockcreateauthz", [{"x-amz-bucket-object-lock-enabled", "true"}])

    assert allowed.status == 200
    assert get_object_lock("lockcreateauthz").status == 200
  end

  test "create bucket with object lock false header does not require object lock permission" do
    create_policy =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:CreateBucket","Resource":"arn:aws:s3:::lockcreatefalse"}})

    assert :ok = Store.put_principal_policy(@alice_arn, "create-lock-false", create_policy)

    allowed =
      alice_create_bucket("lockcreatefalse", [{"x-amz-bucket-object-lock-enabled", "false"}])

    assert allowed.status == 200
    assert get_object_lock("lockcreatefalse").status == 404
    assert BucketConfigs.get("lockcreatefalse", :object_lock) == :none
  end

  test "object legal hold ON blocks version delete until legal hold is OFF" do
    assert create_bucket("locklegal", [{"x-amz-bucket-object-lock-enabled", "true"}]).status ==
             200

    put = put_object("locklegal", "doc.txt", "locked")
    assert put.status == 200
    [version_id] = get_resp_header(put, "x-amz-version-id")

    assert put_legal_hold("locklegal", "doc.txt", legal_hold_xml("ON"),
             query: %{"versionId" => version_id}
           ).status == 200

    legal_hold = get_legal_hold("locklegal", "doc.txt", query: %{"versionId" => version_id})
    assert legal_hold.status == 200
    assert legal_hold.resp_body =~ "<Status>ON</Status>"

    denied = delete_object("locklegal", "doc.txt", query: %{"versionId" => version_id})
    assert denied.status == 403
    assert denied.resp_body =~ "<Code>AccessDenied</Code>"

    assert put_legal_hold("locklegal", "doc.txt", legal_hold_xml("OFF"),
             query: %{"versionId" => version_id}
           ).status == 200

    allowed = delete_object("locklegal", "doc.txt", query: %{"versionId" => version_id})
    assert allowed.status == 204

    gone = get_object("locklegal", "doc.txt", query: %{"versionId" => version_id})
    assert gone.status == 404
  end

  test "governance retention blocks version delete unless bypass governance is authorized" do
    assert create_bucket("lockgov", [{"x-amz-bucket-object-lock-enabled", "true"}]).status == 200

    put = put_object("lockgov", "report.txt", "v1")
    assert put.status == 200
    [version_id] = get_resp_header(put, "x-amz-version-id")

    retain_until = "2035-01-01T00:00:00Z"

    assert put_retention("lockgov", "report.txt", retention_xml("GOVERNANCE", retain_until),
             query: %{"versionId" => version_id}
           ).status == 200

    retention = get_retention("lockgov", "report.txt", query: %{"versionId" => version_id})
    assert retention.status == 200
    assert retention.resp_body =~ "<Mode>GOVERNANCE</Mode>"
    assert retention.resp_body =~ "<RetainUntilDate>"

    denied = delete_object("lockgov", "report.txt", query: %{"versionId" => version_id})
    assert denied.status == 403
    assert denied.resp_body =~ "<Code>AccessDenied</Code>"

    allowed =
      delete_object("lockgov", "report.txt",
        query: %{"versionId" => version_id},
        headers: [{"x-amz-bypass-governance-retention", "true"}]
      )

    assert allowed.status == 204
  end

  test "governance bypass header requires explicit bypass permission for object delete" do
    bucket = "lockgovauthz"
    key = "report.txt"

    assert create_bucket(bucket, [{"x-amz-bucket-object-lock-enabled", "true"}]).status == 200

    put = put_object(bucket, key, "v1")
    assert put.status == 200
    [version_id] = get_resp_header(put, "x-amz-version-id")

    assert put_retention(bucket, key, retention_xml("GOVERNANCE", "2035-01-01T00:00:00Z"),
             query: %{"versionId" => version_id}
           ).status == 200

    delete_only_policy =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:DeleteObjectVersion","Resource":"arn:aws:s3:::#{bucket}/#{key}"}})

    assert :ok = Store.put_principal_policy(@alice_arn, "delete-lock-version", delete_only_policy)

    denied =
      alice(:delete, "/#{bucket}/#{key}",
        query: %{"versionId" => version_id},
        headers: [{"x-amz-bypass-governance-retention", "true"}]
      )
      |> call()

    assert denied.status == 403
    assert denied.resp_body =~ "<Code>AccessDenied</Code>"

    bypass_policy =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:BypassGovernanceRetention","Resource":"arn:aws:s3:::#{bucket}/#{key}"}})

    assert :ok = Store.put_principal_policy(@alice_arn, "bypass-lock-version", bypass_policy)

    allowed =
      alice(:delete, "/#{bucket}/#{key}",
        query: %{"versionId" => version_id},
        headers: [{"x-amz-bypass-governance-retention", "true"}]
      )
      |> call()

    assert allowed.status == 204
  end

  test "governance retention update bypass requires explicit bypass permission" do
    bucket = "lockputgovauthz"
    key = "report.txt"

    assert create_bucket(bucket, [{"x-amz-bucket-object-lock-enabled", "true"}]).status == 200

    put = put_object(bucket, key, "v1")
    assert put.status == 200
    [version_id] = get_resp_header(put, "x-amz-version-id")

    assert put_retention(bucket, key, retention_xml("GOVERNANCE", "2035-01-01T00:00:00Z"),
             query: %{"versionId" => version_id}
           ).status == 200

    put_retention_policy =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:PutObjectRetention","Resource":"arn:aws:s3:::#{bucket}/#{key}"}})

    assert :ok =
             Store.put_principal_policy(@alice_arn, "put-lock-retention", put_retention_policy)

    denied =
      alice(:put, "/#{bucket}/#{key}",
        query: %{"retention" => "", "versionId" => version_id},
        body: retention_xml("GOVERNANCE", "2034-01-01T00:00:00Z"),
        headers: [
          {"content-md5", content_md5(retention_xml("GOVERNANCE", "2034-01-01T00:00:00Z"))},
          {"x-amz-bypass-governance-retention", "true"}
        ]
      )
      |> call()

    assert denied.status == 403
    assert denied.resp_body =~ "<Code>AccessDenied</Code>"

    bypass_policy =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:BypassGovernanceRetention","Resource":"arn:aws:s3:::#{bucket}/#{key}"}})

    assert :ok = Store.put_principal_policy(@alice_arn, "bypass-lock-retention", bypass_policy)

    allowed =
      alice(:put, "/#{bucket}/#{key}",
        query: %{"retention" => "", "versionId" => version_id},
        body: retention_xml("GOVERNANCE", "2034-01-01T00:00:00Z"),
        headers: [
          {"content-md5", content_md5(retention_xml("GOVERNANCE", "2034-01-01T00:00:00Z"))},
          {"x-amz-bypass-governance-retention", "true"}
        ]
      )
      |> call()

    assert allowed.status == 200
  end

  test "compliance retention blocks version delete even with governance bypass header" do
    assert create_bucket("lockcomp", [{"x-amz-bucket-object-lock-enabled", "true"}]).status ==
             200

    put = put_object("lockcomp", "audit.txt", "v1")
    assert put.status == 200
    [version_id] = get_resp_header(put, "x-amz-version-id")

    assert put_retention(
             "lockcomp",
             "audit.txt",
             retention_xml("COMPLIANCE", "2035-01-01T00:00:00Z"),
             query: %{"versionId" => version_id}
           ).status == 200

    denied =
      delete_object("lockcomp", "audit.txt",
        query: %{"versionId" => version_id},
        headers: [{"x-amz-bypass-governance-retention", "true"}]
      )

    assert denied.status == 403
    assert denied.resp_body =~ "<Code>AccessDenied</Code>"

    still_there = get_object("lockcomp", "audit.txt", query: %{"versionId" => version_id})
    assert still_there.status == 200
    assert still_there.resp_body == "v1"
  end

  test "default retention applies to PutObject and object lock headers are returned" do
    assert create_bucket("lockdefault", [{"x-amz-bucket-object-lock-enabled", "true"}]).status ==
             200

    assert put_object_lock("lockdefault", @governance).status == 200

    put = put_object("lockdefault", "default.txt", "body")
    assert put.status == 200
    [version_id] = get_resp_header(put, "x-amz-version-id")

    get = get_object("lockdefault", "default.txt", query: %{"versionId" => version_id})
    assert get.status == 200
    assert get.resp_body == "body"
    assert get_resp_header(get, "x-amz-object-lock-mode") == ["GOVERNANCE"]
    assert [_retain_until] = get_resp_header(get, "x-amz-object-lock-retain-until-date")

    head = head_object("lockdefault", "default.txt", query: %{"versionId" => version_id})
    assert head.status == 200
    assert get_resp_header(head, "x-amz-object-lock-mode") == ["GOVERNANCE"]
    assert [_retain_until] = get_resp_header(head, "x-amz-object-lock-retain-until-date")

    denied = delete_object("lockdefault", "default.txt", query: %{"versionId" => version_id})
    assert denied.status == 403
  end

  test "explicit object lock upload headers require checksum and enabled object lock bucket" do
    assert create_bucket("lockupload", [{"x-amz-bucket-object-lock-enabled", "true"}]).status ==
             200

    retain_until = "2035-01-01T00:00:00Z"

    missing_checksum =
      put_object("lockupload", "explicit.txt", "body",
        headers: [
          {"x-amz-object-lock-mode", "GOVERNANCE"},
          {"x-amz-object-lock-retain-until-date", retain_until},
          {"x-amz-object-lock-legal-hold", "ON"}
        ]
      )

    assert missing_checksum.status == 400
    assert missing_checksum.resp_body =~ "InvalidRequest"

    put =
      put_object("lockupload", "explicit.txt", "body",
        headers: [
          {"content-md5", content_md5("body")},
          {"x-amz-object-lock-mode", "GOVERNANCE"},
          {"x-amz-object-lock-retain-until-date", retain_until},
          {"x-amz-object-lock-legal-hold", "ON"}
        ]
      )

    assert put.status == 200
    [version_id] = get_resp_header(put, "x-amz-version-id")

    get = get_object("lockupload", "explicit.txt", query: %{"versionId" => version_id})
    assert get.resp_body == "body"
    assert get_resp_header(get, "x-amz-object-lock-mode") == ["GOVERNANCE"]
    [actual_retain_until] = get_resp_header(get, "x-amz-object-lock-retain-until-date")
    assert_iso8601_equal(actual_retain_until, retain_until)
    assert get_resp_header(get, "x-amz-object-lock-legal-hold") == ["ON"]

    assert create_bucket("lockuploadplain").status == 200

    disabled =
      put_object("lockuploadplain", "plain.txt", "body",
        headers: [
          {"content-md5", content_md5("body")},
          {"x-amz-object-lock-mode", "GOVERNANCE"},
          {"x-amz-object-lock-retain-until-date", retain_until}
        ]
      )

    assert disabled.status == 409
    assert disabled.resp_body =~ "InvalidBucketState"
  end
end
