defmodule Maxio.S3.ObjectLockE2ETest do
  use Maxio.DataCase, async: false

  import Plug.Conn

  alias Maxio.Auth.CredentialStore
  alias Maxio.BucketConfigs
  alias Maxio.IAM
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

  defp unique_access_key(prefix) do
    suffix =
      [System.unique_integer([:positive]), System.monotonic_time()]
      |> :erlang.phash2()
      |> Integer.to_string(36)
      |> String.upcase()

    "AKIA" <> prefix <> suffix
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

    SigV4Request.signed_conn(:get, "/#{bucket}/#{key}",
      query: query,
      headers: Keyword.get(opts, :headers, [])
    )
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

    SigV4Request.signed_conn(:get, "/#{bucket}/#{key}",
      query: query,
      headers: Keyword.get(opts, :headers, [])
    )
    |> call()
  end

  defp alice_put_retention(bucket, key, xml, opts) do
    headers =
      Keyword.get(opts, :headers, [])
      |> maybe_add_content_md5(xml, Keyword.get(opts, :content_md5, true))

    query = Map.merge(%{"retention" => ""}, Keyword.get(opts, :query, %{}))

    alice(:put, "/#{bucket}/#{key}",
      query: query,
      body: xml,
      headers: headers
    )
    |> call()
  end

  defp alice_get_retention(bucket, key, opts) do
    query = Map.merge(%{"retention" => ""}, Keyword.get(opts, :query, %{}))

    alice(:get, "/#{bucket}/#{key}",
      query: query,
      headers: Keyword.get(opts, :headers, [])
    )
    |> call()
  end

  defp alice_put_legal_hold(bucket, key, xml, opts) do
    headers =
      Keyword.get(opts, :headers, [])
      |> maybe_add_content_md5(xml, Keyword.get(opts, :content_md5, true))

    query = Map.merge(%{"legal-hold" => ""}, Keyword.get(opts, :query, %{}))

    alice(:put, "/#{bucket}/#{key}",
      query: query,
      body: xml,
      headers: headers
    )
    |> call()
  end

  defp alice_get_legal_hold(bucket, key, opts) do
    query = Map.merge(%{"legal-hold" => ""}, Keyword.get(opts, :query, %{}))

    alice(:get, "/#{bucket}/#{key}",
      query: query,
      headers: Keyword.get(opts, :headers, [])
    )
    |> call()
  end

  defp enable_requester_pays(bucket),
    do: BucketConfigs.put(bucket, :request_payment, %{"Payer" => "Requester"})

  defp allow_alice_object_lock(bucket, key, actions \\ object_lock_actions()) do
    policy =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":#{Jason.encode!(actions)},"Resource":"arn:aws:s3:::#{bucket}/#{key}"}})

    Store.put_principal_policy(@alice_arn, "object-lock-#{bucket}-#{:erlang.phash2(key)}", policy)
  end

  defp object_lock_actions do
    [
      "s3:GetObjectVersion",
      "s3:GetObjectRetention",
      "s3:PutObjectRetention",
      "s3:GetObjectLegalHold",
      "s3:PutObjectLegalHold"
    ]
  end

  defp assert_charged(conn),
    do: assert(get_resp_header(conn, "x-amz-request-charged") == ["requester"])

  defp refute_charged(conn), do: assert(get_resp_header(conn, "x-amz-request-charged") == [])

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

    for bad_xml <- [
          "<ObjectLockConfiguration><ObjectLockEnabled>Enabled</ObjectLockEnabled><Rule><DefaultRetention><Mode>GOVERNANCE</Mode><Days>1</Days><Years>1</Years></DefaultRetention></Rule></ObjectLockConfiguration>",
          "<ObjectLockConfiguration><ObjectLockEnabled>Enabled</ObjectLockEnabled><Rule><DefaultRetention><Mode>governance</Mode><Days>1</Days></DefaultRetention></Rule></ObjectLockConfiguration>",
          "<ObjectLockConfiguration><ObjectLockEnabled><Value>Enabled</Value></ObjectLockEnabled></ObjectLockConfiguration>",
          "<ObjectLockConfiguration><ObjectLockEnabled>Enabled</ObjectLockEnabled><ObjectLockEnabled>Enabled</ObjectLockEnabled></ObjectLockConfiguration>"
        ] do
      response = put_object_lock("lockbad", bad_xml)

      assert response.status == 400
      assert response.resp_body =~ "MalformedXML"

      assert {:ok, %{"Rule" => %{"DefaultRetention" => %{"Years" => 1}}}} =
               BucketConfigs.get("lockbad", :object_lock)
    end
  end

  test "checksum trailers and aws-chunked XML bodies are validated before storing config" do
    assert create_bucket("lockchunked", [{"x-amz-bucket-object-lock-enabled", "true"}]).status ==
             200

    plain_trailer =
      put_object_lock("lockchunked", @governance,
        headers: [
          {"x-amz-sdk-checksum-algorithm", "SHA256"},
          {"x-amz-trailer", "x-amz-checksum-sha256"}
        ]
      )

    assert plain_trailer.status == 400
    assert plain_trailer.resp_body =~ "InvalidRequest"

    bare_non_checksum_trailer =
      put_object_lock("lockchunked", @governance,
        headers: [{"x-amz-trailer", "x-amz-meta-not-a-checksum"}],
        content_md5: false
      )

    assert bare_non_checksum_trailer.status == 400
    assert bare_non_checksum_trailer.resp_body =~ "MissingSecurityHeader"

    bad =
      SigV4Request.signed_chunked_conn(:put, "/lockchunked", @governance,
        query: %{"object-lock" => ""},
        headers: [
          {"x-amz-sdk-checksum-algorithm", "SHA256"},
          {"content-md5", content_md5(@governance)}
        ],
        trailer_headers: [
          {"x-amz-checksum-sha256", content_sha256("different")}
        ]
      )
      |> call()

    assert bad.status == 400
    assert bad.resp_body =~ "BadDigest"

    assert {:ok, %{"ObjectLockEnabled" => "Enabled"}} =
             BucketConfigs.get("lockchunked", :object_lock)

    ok_trailer =
      SigV4Request.signed_chunked_conn(:put, "/lockchunked", @governance,
        query: %{"object-lock" => ""},
        headers: [{"x-amz-sdk-checksum-algorithm", "SHA256"}],
        trailer_headers: [
          {"x-amz-checksum-sha256", content_sha256(@governance)}
        ]
      )
      |> call()

    assert ok_trailer.status == 200

    assert {:ok, %{"Rule" => %{"DefaultRetention" => %{"Days" => 7}}}} =
             BucketConfigs.get("lockchunked", :object_lock)

    signed_trailer =
      SigV4Request.signed_chunked_conn(:put, "/lockchunked", @governance,
        query: %{"object-lock" => ""},
        headers: [{"x-amz-sdk-checksum-algorithm", "SHA256"}],
        trailer_headers: [
          {"x-amz-checksum-sha256", content_sha256(@governance)}
        ],
        streaming_payload_hash: "STREAMING-AWS4-HMAC-SHA256-PAYLOAD-TRAILER"
      )
      |> call()

    assert signed_trailer.status == 200

    assert {:ok, %{"Rule" => %{"DefaultRetention" => %{"Days" => 7}}}} =
             BucketConfigs.get("lockchunked", :object_lock)

    ok_chunked =
      SigV4Request.signed_chunked_conn(:put, "/lockchunked", @compliance,
        query: %{"object-lock" => ""},
        headers: [{"content-md5", content_md5(@compliance)}]
      )
      |> call()

    assert ok_chunked.status == 200

    assert {:ok, %{"Rule" => %{"DefaultRetention" => %{"Years" => 1}}}} =
             BucketConfigs.get("lockchunked", :object_lock)

    oversized = String.duplicate("x", 131_073)

    too_large =
      SigV4Request.signed_chunked_conn(:put, "/lockchunked", oversized,
        query: %{"object-lock" => ""},
        chunk_size: byte_size(oversized),
        decoded_length_override: 131_072,
        headers: [{"content-md5", content_md5(oversized)}]
      )
      |> call()

    assert too_large.status == 400
    assert too_large.resp_body =~ "MalformedXML"
    assert too_large.resp_body =~ "ObjectLockConfiguration exceeds 128KB"

    assert {:ok, %{"Rule" => %{"DefaultRetention" => %{"Years" => 1}}}} =
             BucketConfigs.get("lockchunked", :object_lock)
  end

  test "object retention and legal hold aws-chunked checksum trailers are validated" do
    bucket = "lockobjectchunked"
    key = "doc.txt"

    assert create_bucket(bucket, [{"x-amz-bucket-object-lock-enabled", "true"}]).status == 200

    put = put_object(bucket, key, "locked")
    assert put.status == 200
    [version_id] = get_resp_header(put, "x-amz-version-id")

    retention = retention_xml("GOVERNANCE", "2035-01-01T00:00:00Z")

    bad_retention =
      SigV4Request.signed_chunked_conn(:put, "/#{bucket}/#{key}", retention,
        query: %{"retention" => "", "versionId" => version_id},
        headers: [{"x-amz-sdk-checksum-algorithm", "SHA256"}],
        trailer_headers: [
          {"x-amz-checksum-sha256", content_sha256("different")}
        ]
      )
      |> call()

    assert bad_retention.status == 400
    assert bad_retention.resp_body =~ "BadDigest"

    empty_retention = get_retention(bucket, key, query: %{"versionId" => version_id})
    assert empty_retention.status == 200
    refute empty_retention.resp_body =~ "<Mode>GOVERNANCE</Mode>"

    ok_retention =
      SigV4Request.signed_chunked_conn(:put, "/#{bucket}/#{key}", retention,
        query: %{"retention" => "", "versionId" => version_id},
        headers: [{"x-amz-sdk-checksum-algorithm", "SHA256"}],
        trailer_headers: [
          {"x-amz-checksum-sha256", content_sha256(retention)}
        ]
      )
      |> call()

    assert ok_retention.status == 200

    get_retention = get_retention(bucket, key, query: %{"versionId" => version_id})
    assert get_retention.status == 200
    assert get_retention.resp_body =~ "<Mode>GOVERNANCE</Mode>"

    legal_hold_on = legal_hold_xml("ON")

    bad_legal_hold =
      SigV4Request.signed_chunked_conn(:put, "/#{bucket}/#{key}", legal_hold_on,
        query: %{"legal-hold" => "", "versionId" => version_id},
        headers: [{"x-amz-sdk-checksum-algorithm", "SHA256"}],
        trailer_headers: [
          {"x-amz-checksum-sha256", content_sha256("different")}
        ]
      )
      |> call()

    assert bad_legal_hold.status == 400
    assert bad_legal_hold.resp_body =~ "BadDigest"

    default_legal_hold = get_legal_hold(bucket, key, query: %{"versionId" => version_id})
    assert default_legal_hold.status == 200
    assert default_legal_hold.resp_body =~ "<Status>OFF</Status>"

    ok_legal_hold =
      SigV4Request.signed_chunked_conn(:put, "/#{bucket}/#{key}", legal_hold_on,
        query: %{"legal-hold" => "", "versionId" => version_id},
        headers: [{"x-amz-sdk-checksum-algorithm", "SHA256"}],
        trailer_headers: [
          {"x-amz-checksum-sha256", content_sha256(legal_hold_on)}
        ]
      )
      |> call()

    assert ok_legal_hold.status == 200

    legal_hold = get_legal_hold(bucket, key, query: %{"versionId" => version_id})
    assert legal_hold.status == 200
    assert legal_hold.resp_body =~ "<Status>ON</Status>"
  end

  test "malformed object retention and legal hold XML do not mutate object lock metadata" do
    bucket = "lockobjectbadxml"
    key = "doc.txt"

    assert create_bucket(bucket, [{"x-amz-bucket-object-lock-enabled", "true"}]).status == 200

    put = put_object(bucket, key, "locked")
    assert put.status == 200
    [version_id] = get_resp_header(put, "x-amz-version-id")

    assert put_retention(bucket, key, retention_xml("GOVERNANCE", "2035-01-01T00:00:00Z"),
             query: %{"versionId" => version_id}
           ).status == 200

    assert put_legal_hold(bucket, key, legal_hold_xml("ON"), query: %{"versionId" => version_id}).status ==
             200

    for bad_retention <- [
          "<Retention><Mode>COMPLIANCE</Mode><RetainUntilDate><Value>2036-01-01T00:00:00Z</Value></RetainUntilDate></Retention>",
          "<Retention><Mode>governance</Mode><RetainUntilDate>2036-01-01T00:00:00Z</RetainUntilDate></Retention>",
          "<Retention><Mode>COMPLIANCE</Mode><Mode>GOVERNANCE</Mode><RetainUntilDate>2036-01-01T00:00:00Z</RetainUntilDate></Retention>",
          "<LegalHold><Status>OFF</Status></LegalHold>"
        ] do
      response =
        put_retention(bucket, key, bad_retention, query: %{"versionId" => version_id})

      assert response.status == 400
      assert response.resp_body =~ "MalformedXML"

      retention = get_retention(bucket, key, query: %{"versionId" => version_id})
      assert retention.status == 200
      assert retention.resp_body =~ "<Mode>GOVERNANCE</Mode>"
      assert retention.resp_body =~ "2035-01-01T00:00:00"
    end

    for bad_legal_hold <- [
          "<LegalHold><Status><Value>OFF</Value></Status></LegalHold>",
          "<LegalHold><Status>off</Status></LegalHold>",
          "<LegalHold><Status>OFF</Status><Status>ON</Status></LegalHold>",
          "<Retention><Mode>GOVERNANCE</Mode><RetainUntilDate>2036-01-01T00:00:00Z</RetainUntilDate></Retention>"
        ] do
      response =
        put_legal_hold(bucket, key, bad_legal_hold, query: %{"versionId" => version_id})

      assert response.status == 400
      assert response.resp_body =~ "MalformedXML"

      legal_hold = get_legal_hold(bucket, key, query: %{"versionId" => version_id})
      assert legal_hold.status == 200
      assert legal_hold.resp_body =~ "<Status>ON</Status>"
    end
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

  test "versioned retention and legal hold reads require their metadata actions" do
    bucket = "lockmetadataauthz"
    key = "audit.txt"

    assert create_bucket(bucket, [{"x-amz-bucket-object-lock-enabled", "true"}]).status == 200

    put = put_object(bucket, key, "audit")
    assert put.status == 200
    [version_id] = get_resp_header(put, "x-amz-version-id")

    assert put_retention(bucket, key, retention_xml("GOVERNANCE", "2090-01-01T00:00:00Z"),
             query: %{"versionId" => version_id}
           ).status == 200

    assert put_legal_hold(bucket, key, legal_hold_xml("ON"), query: %{"versionId" => version_id}).status ==
             200

    resource = "arn:aws:s3:::#{bucket}/#{key}"

    metadata_policy =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":["s3:GetObjectRetention","s3:GetObjectLegalHold"],"Resource":"#{resource}"}})

    assert :ok = Store.put_principal_policy(@alice_arn, "versioned-lock-read", metadata_policy)

    allowed_retention =
      alice_get_retention(bucket, key, query: %{"versionId" => version_id})

    assert allowed_retention.status == 200
    assert allowed_retention.resp_body =~ "<Mode>GOVERNANCE</Mode>"

    allowed_legal_hold =
      alice_get_legal_hold(bucket, key, query: %{"versionId" => version_id})

    assert allowed_legal_hold.status == 200
    assert allowed_legal_hold.resp_body =~ "<Status>ON</Status>"

    version_only_policy =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:GetObjectVersion","Resource":"#{resource}"}})

    assert :ok =
             Store.put_principal_policy(@alice_arn, "versioned-lock-read", version_only_policy)

    denied_retention =
      alice_get_retention(bucket, key, query: %{"versionId" => version_id})

    assert denied_retention.status == 403
    assert denied_retention.resp_body =~ "<Code>AccessDenied</Code>"

    denied_legal_hold =
      alice_get_legal_hold(bucket, key, query: %{"versionId" => version_id})

    assert denied_legal_hold.status == 403
    assert denied_legal_hold.resp_body =~ "<Code>AccessDenied</Code>"
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

  test "object retention and legal hold enforce expected bucket owner before metadata changes" do
    bucket = "lockobjectowner"
    key = "doc.txt"
    wrong_owner = [{"x-amz-expected-bucket-owner", "999999999999"}]

    assert create_bucket(bucket, [{"x-amz-bucket-object-lock-enabled", "true"}]).status == 200

    put = put_object(bucket, key, "locked")
    assert put.status == 200
    [version_id] = get_resp_header(put, "x-amz-version-id")

    retention = retention_xml("GOVERNANCE", "2035-01-01T00:00:00Z")

    wrong_put_retention =
      put_retention(bucket, key, retention,
        query: %{"versionId" => version_id},
        headers: wrong_owner
      )

    assert wrong_put_retention.status == 403

    empty_retention = get_retention(bucket, key, query: %{"versionId" => version_id})
    assert empty_retention.status == 200
    refute empty_retention.resp_body =~ "<Mode>GOVERNANCE</Mode>"

    assert put_retention(bucket, key, retention, query: %{"versionId" => version_id}).status ==
             200

    wrong_get_retention =
      get_retention(bucket, key,
        query: %{"versionId" => version_id},
        headers: wrong_owner
      )

    assert wrong_get_retention.status == 403

    wrong_put_legal_hold =
      put_legal_hold(bucket, key, legal_hold_xml("ON"),
        query: %{"versionId" => version_id},
        headers: wrong_owner
      )

    assert wrong_put_legal_hold.status == 403

    legal_hold = get_legal_hold(bucket, key, query: %{"versionId" => version_id})
    assert legal_hold.status == 200
    assert legal_hold.resp_body =~ "<Status>OFF</Status>"

    assert put_legal_hold(bucket, key, legal_hold_xml("ON"), query: %{"versionId" => version_id}).status ==
             200

    wrong_get_legal_hold =
      get_legal_hold(bucket, key,
        query: %{"versionId" => version_id},
        headers: wrong_owner
      )

    assert wrong_get_legal_hold.status == 403
  end

  test "object retention and legal hold enforce Requester Pays for non-owner callers" do
    bucket = "lockobjectpayer"
    key = "doc.txt"
    header_key = "header-doc.txt"
    retention = retention_xml("GOVERNANCE", "2035-01-01T00:00:00Z")
    legal_hold = legal_hold_xml("ON")

    assert create_bucket(bucket, [{"x-amz-bucket-object-lock-enabled", "true"}]).status == 200

    put = put_object(bucket, key, "locked")
    assert put.status == 200
    [version_id] = get_resp_header(put, "x-amz-version-id")

    header_put_object = put_object(bucket, header_key, "locked-header")
    assert header_put_object.status == 200
    [header_version_id] = get_resp_header(header_put_object, "x-amz-version-id")

    assert :ok = enable_requester_pays(bucket)
    assert :ok = allow_alice_object_lock(bucket, key)
    assert :ok = allow_alice_object_lock(bucket, header_key)

    missing_put =
      alice_put_retention(bucket, key, retention, query: %{"versionId" => version_id})

    assert missing_put.status == 403
    assert missing_put.resp_body =~ "<Code>AccessDenied</Code>"
    refute_charged(missing_put)

    invalid_put =
      alice_put_retention(bucket, key, retention,
        query: %{"versionId" => version_id},
        headers: [{"x-amz-request-payer", "owner"}]
      )

    assert invalid_put.status == 403
    assert invalid_put.resp_body =~ "<Code>AccessDenied</Code>"
    refute_charged(invalid_put)

    unsigned_put =
      alice(:put, "/#{bucket}/#{key}",
        query: %{"retention" => "", "versionId" => version_id},
        body: retention,
        headers: [{"content-md5", content_md5(retention)}]
      )
      |> put_req_header("x-amz-request-payer", "requester")
      |> call()

    assert unsigned_put.status == 403
    assert unsigned_put.resp_body =~ "<Code>AccessDenied</Code>"
    refute_charged(unsigned_put)

    empty_retention = get_retention(bucket, key, query: %{"versionId" => version_id})
    assert empty_retention.status == 200
    refute empty_retention.resp_body =~ "<Mode>GOVERNANCE</Mode>"
    refute_charged(empty_retention)

    query_put =
      alice_put_retention(bucket, key, retention,
        query: %{"versionId" => version_id, "x-amz-request-payer" => "requester"}
      )

    assert query_put.status == 200
    assert_charged(query_put)

    header_put =
      alice_put_retention(bucket, header_key, retention,
        query: %{"versionId" => header_version_id},
        headers: [{"x-amz-request-payer", "requester"}]
      )

    assert header_put.status == 200
    assert_charged(header_put)

    missing_get = alice_get_retention(bucket, key, query: %{"versionId" => version_id})
    assert missing_get.status == 403
    assert missing_get.resp_body =~ "<Code>AccessDenied</Code>"
    refute_charged(missing_get)

    invalid_get =
      alice_get_retention(bucket, key,
        query: %{"versionId" => version_id},
        headers: [{"x-amz-request-payer", "owner"}]
      )

    assert invalid_get.status == 403
    assert invalid_get.resp_body =~ "<Code>AccessDenied</Code>"
    refute_charged(invalid_get)

    header_get =
      alice_get_retention(bucket, key,
        query: %{"versionId" => version_id},
        headers: [{"x-amz-request-payer", "requester"}]
      )

    assert header_get.status == 200
    assert header_get.resp_body =~ "<Mode>GOVERNANCE</Mode>"
    assert_charged(header_get)

    query_get =
      alice_get_retention(bucket, key,
        query: %{"versionId" => version_id, "x-amz-request-payer" => "requester"}
      )

    assert query_get.status == 200
    assert query_get.resp_body =~ "<Mode>GOVERNANCE</Mode>"
    assert_charged(query_get)

    unsigned_get =
      alice(:get, "/#{bucket}/#{key}", query: %{"retention" => "", "versionId" => version_id})
      |> put_req_header("x-amz-request-payer", "requester")
      |> call()

    assert unsigned_get.status == 403
    assert unsigned_get.resp_body =~ "<Code>AccessDenied</Code>"
    refute_charged(unsigned_get)

    owner_get = get_retention(bucket, key, query: %{"versionId" => version_id})
    assert owner_get.status == 200
    assert owner_get.resp_body =~ "<Mode>GOVERNANCE</Mode>"
    refute_charged(owner_get)

    missing_legal_hold =
      alice_put_legal_hold(bucket, key, legal_hold, query: %{"versionId" => version_id})

    assert missing_legal_hold.status == 403
    assert missing_legal_hold.resp_body =~ "<Code>AccessDenied</Code>"
    refute_charged(missing_legal_hold)

    default_legal_hold = get_legal_hold(bucket, key, query: %{"versionId" => version_id})
    assert default_legal_hold.status == 200
    assert default_legal_hold.resp_body =~ "<Status>OFF</Status>"
    refute_charged(default_legal_hold)

    invalid_legal_hold =
      alice_put_legal_hold(bucket, key, legal_hold,
        query: %{"versionId" => version_id},
        headers: [{"x-amz-request-payer", "owner"}]
      )

    assert invalid_legal_hold.status == 403
    assert invalid_legal_hold.resp_body =~ "<Code>AccessDenied</Code>"
    refute_charged(invalid_legal_hold)

    unsigned_legal_hold =
      alice(:put, "/#{bucket}/#{key}",
        query: %{"legal-hold" => "", "versionId" => version_id},
        body: legal_hold,
        headers: [{"content-md5", content_md5(legal_hold)}]
      )
      |> put_req_header("x-amz-request-payer", "requester")
      |> call()

    assert unsigned_legal_hold.status == 403
    assert unsigned_legal_hold.resp_body =~ "<Code>AccessDenied</Code>"
    refute_charged(unsigned_legal_hold)

    still_default_legal_hold = get_legal_hold(bucket, key, query: %{"versionId" => version_id})
    assert still_default_legal_hold.status == 200
    assert still_default_legal_hold.resp_body =~ "<Status>OFF</Status>"
    refute_charged(still_default_legal_hold)

    query_legal_hold_put =
      alice_put_legal_hold(bucket, key, legal_hold,
        query: %{"versionId" => version_id, "x-amz-request-payer" => "requester"}
      )

    assert query_legal_hold_put.status == 200
    assert_charged(query_legal_hold_put)

    header_legal_hold =
      alice_put_legal_hold(bucket, key, legal_hold,
        query: %{"versionId" => version_id},
        headers: [{"x-amz-request-payer", "requester"}]
      )

    assert header_legal_hold.status == 200
    assert_charged(header_legal_hold)

    missing_legal_hold_get =
      alice_get_legal_hold(bucket, key, query: %{"versionId" => version_id})

    assert missing_legal_hold_get.status == 403
    assert missing_legal_hold_get.resp_body =~ "<Code>AccessDenied</Code>"
    refute_charged(missing_legal_hold_get)

    invalid_legal_hold_get =
      alice_get_legal_hold(bucket, key,
        query: %{"versionId" => version_id},
        headers: [{"x-amz-request-payer", "owner"}]
      )

    assert invalid_legal_hold_get.status == 403
    assert invalid_legal_hold_get.resp_body =~ "<Code>AccessDenied</Code>"
    refute_charged(invalid_legal_hold_get)

    unsigned_legal_hold_get =
      alice(:get, "/#{bucket}/#{key}", query: %{"legal-hold" => "", "versionId" => version_id})
      |> put_req_header("x-amz-request-payer", "requester")
      |> call()

    assert unsigned_legal_hold_get.status == 403
    assert unsigned_legal_hold_get.resp_body =~ "<Code>AccessDenied</Code>"
    refute_charged(unsigned_legal_hold_get)

    header_legal_hold_get =
      alice_get_legal_hold(bucket, key,
        query: %{"versionId" => version_id},
        headers: [{"x-amz-request-payer", "requester"}]
      )

    assert header_legal_hold_get.status == 200
    assert header_legal_hold_get.resp_body =~ "<Status>ON</Status>"
    assert_charged(header_legal_hold_get)

    query_legal_hold_get =
      alice_get_legal_hold(bucket, key,
        query: %{"versionId" => version_id, "x-amz-request-payer" => "requester"}
      )

    assert query_legal_hold_get.status == 200
    assert query_legal_hold_get.resp_body =~ "<Status>ON</Status>"
    assert_charged(query_legal_hold_get)

    owner_legal_hold = get_legal_hold(bucket, key, query: %{"versionId" => version_id})
    assert owner_legal_hold.status == 200
    assert owner_legal_hold.resp_body =~ "<Status>ON</Status>"
    refute_charged(owner_legal_hold)
  end

  test "requester-paid object lock writes target only the requested version" do
    bucket = "lockpayerversion"
    key = "doc.txt"

    assert create_bucket(bucket, [{"x-amz-bucket-object-lock-enabled", "true"}]).status == 200

    v1_put = put_object(bucket, key, "v1")
    assert v1_put.status == 200
    [v1] = get_resp_header(v1_put, "x-amz-version-id")

    v2_put = put_object(bucket, key, "v2")
    assert v2_put.status == 200
    [v2] = get_resp_header(v2_put, "x-amz-version-id")

    assert :ok = enable_requester_pays(bucket)
    assert :ok = allow_alice_object_lock(bucket, key)

    retention =
      alice_put_retention(bucket, key, retention_xml("GOVERNANCE", "2037-01-01T00:00:00Z"),
        query: %{"versionId" => v1, "x-amz-request-payer" => "requester"}
      )

    assert retention.status == 200
    assert_charged(retention)

    legal_hold =
      alice_put_legal_hold(bucket, key, legal_hold_xml("ON"),
        query: %{"versionId" => v2, "x-amz-request-payer" => "requester"}
      )

    assert legal_hold.status == 200
    assert_charged(legal_hold)

    v1_retention = get_retention(bucket, key, query: %{"versionId" => v1})
    assert v1_retention.status == 200
    assert v1_retention.resp_body =~ "<Mode>GOVERNANCE</Mode>"
    assert v1_retention.resp_body =~ "2037-01-01T00:00:00"

    v2_retention = get_retention(bucket, key, query: %{"versionId" => v2})
    assert v2_retention.status == 200
    refute v2_retention.resp_body =~ "<Mode>GOVERNANCE</Mode>"

    v1_legal_hold = get_legal_hold(bucket, key, query: %{"versionId" => v1})
    assert v1_legal_hold.status == 200
    assert v1_legal_hold.resp_body =~ "<Status>OFF</Status>"

    v2_legal_hold = get_legal_hold(bucket, key, query: %{"versionId" => v2})
    assert v2_legal_hold.status == 200
    assert v2_legal_hold.resp_body =~ "<Status>ON</Status>"

    alice_v1 =
      alice_get_retention(bucket, key,
        query: %{"versionId" => v1, "x-amz-request-payer" => "requester"}
      )

    assert alice_v1.status == 200
    assert alice_v1.resp_body =~ "<Mode>GOVERNANCE</Mode>"
    assert_charged(alice_v1)

    alice_v2 =
      alice_get_legal_hold(bucket, key,
        query: %{"versionId" => v2, "x-amz-request-payer" => "requester"}
      )

    assert alice_v2.status == 200
    assert alice_v2.resp_body =~ "<Status>ON</Status>"
    assert_charged(alice_v2)
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

  test "governance bypass object delete enforces permissions boundary explicit deny" do
    bucket = "lockgovboundary"
    key = "report.txt"

    assert create_bucket(bucket, [{"x-amz-bucket-object-lock-enabled", "true"}]).status == 200

    put = put_object(bucket, key, "v1")
    assert put.status == 200
    [version_id] = get_resp_header(put, "x-amz-version-id")

    assert put_retention(bucket, key, retention_xml("GOVERNANCE", "2035-01-01T00:00:00Z"),
             query: %{"versionId" => version_id}
           ).status == 200

    user_name = "lock-delete-boundary-#{System.unique_integer([:positive])}"
    access_key = unique_access_key("LOCKDEL")
    secret = "lock-delete-boundary-secret-123456"

    assert {:ok, user} = IAM.create_user(name: user_name)

    assert :ok =
             CredentialStore.put_access_key(%{
               access_key: access_key,
               secret_key: secret,
               principal: %{type: :iam_user, access_key: access_key, arn: user.user_arn}
             })

    identity_policy =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":["s3:DeleteObjectVersion","s3:BypassGovernanceRetention"],"Resource":"arn:aws:s3:::#{bucket}/#{key}"}})

    boundary_policy =
      ~s({"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"s3:DeleteObjectVersion","Resource":"arn:aws:s3:::#{bucket}/#{key}"},{"Effect":"Deny","Action":"s3:BypassGovernanceRetention","Resource":"arn:aws:s3:::#{bucket}/#{key}"}]})

    assert :ok =
             Store.put_principal_policy(
               user.user_arn,
               "allow-lock-delete-bypass",
               identity_policy
             )

    assert {:ok, boundary} =
             IAM.create_managed_policy(
               name: "lock-delete-boundary-#{System.unique_integer([:positive])}",
               path: "/authz/",
               policy: boundary_policy
             )

    assert {:ok, _user} =
             IAM.put_user_permissions_boundary_strict(user.user_name, boundary.policy_arn)

    denied =
      SigV4Request.signed_conn(:delete, "/#{bucket}/#{key}",
        query: %{"versionId" => version_id},
        access_key: access_key,
        secret: secret,
        headers: [{"x-amz-bypass-governance-retention", "true"}]
      )
      |> call()

    assert denied.status == 403
    assert denied.resp_body =~ "<Code>AccessDenied</Code>"

    still_there = get_object(bucket, key, query: %{"versionId" => version_id})
    assert still_there.status == 200
    assert still_there.resp_body == "v1"
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

  test "active governance retention can be extended but shortening requires bypass" do
    bucket = "lockgovtransition"
    key = "report.txt"

    assert create_bucket(bucket, [{"x-amz-bucket-object-lock-enabled", "true"}]).status == 200

    put = put_object(bucket, key, "v1")
    assert put.status == 200
    [version_id] = get_resp_header(put, "x-amz-version-id")

    assert put_retention(bucket, key, retention_xml("GOVERNANCE", "2090-01-01T00:00:00Z"),
             query: %{"versionId" => version_id}
           ).status == 200

    extended =
      put_retention(bucket, key, retention_xml("GOVERNANCE", "2091-01-01T00:00:00Z"),
        query: %{"versionId" => version_id}
      )

    assert extended.status == 200

    denied_shortening =
      put_retention(bucket, key, retention_xml("GOVERNANCE", "2089-01-01T00:00:00Z"),
        query: %{"versionId" => version_id}
      )

    assert denied_shortening.status == 403
    assert denied_shortening.resp_body =~ "<Code>AccessDenied</Code>"

    unchanged = get_retention(bucket, key, query: %{"versionId" => version_id})
    assert unchanged.status == 200
    assert unchanged.resp_body =~ "2091-01-01T00:00:00"

    allowed_shortening =
      put_retention(bucket, key, retention_xml("GOVERNANCE", "2089-01-01T00:00:00Z"),
        query: %{"versionId" => version_id},
        headers: [{"x-amz-bypass-governance-retention", "true"}]
      )

    assert allowed_shortening.status == 200
  end

  test "active compliance retention can only be extended" do
    bucket = "lockcomptransition"
    key = "audit.txt"

    assert create_bucket(bucket, [{"x-amz-bucket-object-lock-enabled", "true"}]).status == 200

    put = put_object(bucket, key, "v1")
    assert put.status == 200
    [version_id] = get_resp_header(put, "x-amz-version-id")

    assert put_retention(bucket, key, retention_xml("COMPLIANCE", "2090-01-01T00:00:00Z"),
             query: %{"versionId" => version_id}
           ).status == 200

    extended =
      put_retention(bucket, key, retention_xml("COMPLIANCE", "2091-01-01T00:00:00Z"),
        query: %{"versionId" => version_id}
      )

    assert extended.status == 200

    denied_shortening =
      put_retention(bucket, key, retention_xml("COMPLIANCE", "2089-01-01T00:00:00Z"),
        query: %{"versionId" => version_id},
        headers: [{"x-amz-bypass-governance-retention", "true"}]
      )

    assert denied_shortening.status == 403
    assert denied_shortening.resp_body =~ "<Code>AccessDenied</Code>"

    denied_mode_change =
      put_retention(bucket, key, retention_xml("GOVERNANCE", "2092-01-01T00:00:00Z"),
        query: %{"versionId" => version_id},
        headers: [{"x-amz-bypass-governance-retention", "true"}]
      )

    assert denied_mode_change.status == 403
    assert denied_mode_change.resp_body =~ "<Code>AccessDenied</Code>"

    unchanged = get_retention(bucket, key, query: %{"versionId" => version_id})
    assert unchanged.status == 200
    assert unchanged.resp_body =~ "<Mode>COMPLIANCE</Mode>"
    assert unchanged.resp_body =~ "2091-01-01T00:00:00"
  end

  test "requester-paid governance retention update requires both payer and bypass permission" do
    bucket = "lockpaygov"
    key = "report.txt"
    original_retention = retention_xml("GOVERNANCE", "2035-01-01T00:00:00Z")
    shorter_retention = retention_xml("GOVERNANCE", "2034-01-01T00:00:00Z")

    assert create_bucket(bucket, [{"x-amz-bucket-object-lock-enabled", "true"}]).status == 200

    put = put_object(bucket, key, "v1")
    assert put.status == 200
    [version_id] = get_resp_header(put, "x-amz-version-id")

    assert put_retention(bucket, key, original_retention, query: %{"versionId" => version_id}).status ==
             200

    assert :ok = enable_requester_pays(bucket)
    assert :ok = allow_alice_object_lock(bucket, key, ["s3:PutObjectRetention"])

    denied_no_bypass_permission =
      alice(:put, "/#{bucket}/#{key}",
        query: %{"retention" => "", "versionId" => version_id},
        body: shorter_retention,
        headers: [
          {"content-md5", content_md5(shorter_retention)},
          {"x-amz-bypass-governance-retention", "true"},
          {"x-amz-request-payer", "requester"}
        ]
      )
      |> call()

    assert denied_no_bypass_permission.status == 403
    assert denied_no_bypass_permission.resp_body =~ "<Code>AccessDenied</Code>"
    refute_charged(denied_no_bypass_permission)

    unchanged = get_retention(bucket, key, query: %{"versionId" => version_id})
    assert unchanged.status == 200
    assert unchanged.resp_body =~ "2035-01-01T00:00:00"

    bypass_policy =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:BypassGovernanceRetention","Resource":"arn:aws:s3:::#{bucket}/#{key}"}})

    assert :ok = Store.put_principal_policy(@alice_arn, "bypass-lock-paygov", bypass_policy)

    missing_payer =
      alice(:put, "/#{bucket}/#{key}",
        query: %{"retention" => "", "versionId" => version_id},
        body: shorter_retention,
        headers: [
          {"content-md5", content_md5(shorter_retention)},
          {"x-amz-bypass-governance-retention", "true"}
        ]
      )
      |> call()

    assert missing_payer.status == 403
    assert missing_payer.resp_body =~ "<Code>AccessDenied</Code>"
    refute_charged(missing_payer)

    invalid_payer =
      alice(:put, "/#{bucket}/#{key}",
        query: %{"retention" => "", "versionId" => version_id},
        body: shorter_retention,
        headers: [
          {"content-md5", content_md5(shorter_retention)},
          {"x-amz-bypass-governance-retention", "true"},
          {"x-amz-request-payer", "owner"}
        ]
      )
      |> call()

    assert invalid_payer.status == 403
    assert invalid_payer.resp_body =~ "<Code>AccessDenied</Code>"
    refute_charged(invalid_payer)

    still_unchanged = get_retention(bucket, key, query: %{"versionId" => version_id})
    assert still_unchanged.status == 200
    assert still_unchanged.resp_body =~ "2035-01-01T00:00:00"

    allowed =
      alice(:put, "/#{bucket}/#{key}",
        query: %{"retention" => "", "versionId" => version_id},
        body: shorter_retention,
        headers: [
          {"content-md5", content_md5(shorter_retention)},
          {"x-amz-bypass-governance-retention", "true"},
          {"x-amz-request-payer", "requester"}
        ]
      )
      |> call()

    assert allowed.status == 200
    assert_charged(allowed)

    updated = get_retention(bucket, key, query: %{"versionId" => version_id})
    assert updated.status == 200
    assert updated.resp_body =~ "2034-01-01T00:00:00"
  end

  test "governance retention update bypass enforces permissions boundary explicit deny" do
    bucket = "lockputgovboundary"
    key = "report.txt"

    assert create_bucket(bucket, [{"x-amz-bucket-object-lock-enabled", "true"}]).status == 200

    put = put_object(bucket, key, "v1")
    assert put.status == 200
    [version_id] = get_resp_header(put, "x-amz-version-id")

    assert put_retention(bucket, key, retention_xml("GOVERNANCE", "2035-01-01T00:00:00Z"),
             query: %{"versionId" => version_id}
           ).status == 200

    user_name = "lock-retention-boundary-#{System.unique_integer([:positive])}"
    access_key = unique_access_key("LOCKRET")
    secret = "lock-retention-boundary-secret-123456"

    assert {:ok, user} = IAM.create_user(name: user_name)

    assert :ok =
             CredentialStore.put_access_key(%{
               access_key: access_key,
               secret_key: secret,
               principal: %{type: :iam_user, access_key: access_key, arn: user.user_arn}
             })

    identity_policy =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":["s3:PutObjectRetention","s3:BypassGovernanceRetention"],"Resource":"arn:aws:s3:::#{bucket}/#{key}"}})

    boundary_policy =
      ~s({"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"s3:PutObjectRetention","Resource":"arn:aws:s3:::#{bucket}/#{key}"},{"Effect":"Deny","Action":"s3:BypassGovernanceRetention","Resource":"arn:aws:s3:::#{bucket}/#{key}"}]})

    assert :ok =
             Store.put_principal_policy(
               user.user_arn,
               "allow-lock-retention-bypass",
               identity_policy
             )

    assert {:ok, boundary} =
             IAM.create_managed_policy(
               name: "lock-retention-boundary-#{System.unique_integer([:positive])}",
               path: "/authz/",
               policy: boundary_policy
             )

    assert {:ok, _user} =
             IAM.put_user_permissions_boundary_strict(user.user_name, boundary.policy_arn)

    body = retention_xml("GOVERNANCE", "2034-01-01T00:00:00Z")

    denied =
      SigV4Request.signed_conn(:put, "/#{bucket}/#{key}",
        query: %{"retention" => "", "versionId" => version_id},
        access_key: access_key,
        secret: secret,
        body: body,
        headers: [
          {"content-md5", content_md5(body)},
          {"x-amz-bypass-governance-retention", "true"}
        ]
      )
      |> call()

    assert denied.status == 403
    assert denied.resp_body =~ "<Code>AccessDenied</Code>"
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
