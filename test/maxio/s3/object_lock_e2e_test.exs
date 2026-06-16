defmodule Maxio.S3.ObjectLockE2ETest do
  use Maxio.DataCase, async: false

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
end
