defmodule Maxio.S3.WebsiteE2ETest do
  use Maxio.DataCase, async: false

  import Plug.Conn

  alias Maxio.Auth.CredentialStore
  alias Maxio.BucketConfigs
  alias Maxio.Policy.Store
  alias Maxio.S3.Endpoint
  alias Maxio.Test.SigV4Request

  @data_dir Path.join(System.tmp_dir!(), "maxio_website_e2e")
  @alice_ak "AKIAWEBSITEPOLICY01"
  @alice_secret "websitewebsitewebsiteweb12"
  @alice_arn "arn:aws:iam:::user/" <> @alice_ak
  @website """
  <WebsiteConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
    <IndexDocument><Suffix>index.html</Suffix></IndexDocument>
    <ErrorDocument><Key>404.html</Key></ErrorDocument>
    <RoutingRules>
      <RoutingRule>
        <Condition><KeyPrefixEquals>docs/</KeyPrefixEquals></Condition>
        <Redirect><ReplaceKeyPrefixWith>documents/</ReplaceKeyPrefixWith></Redirect>
      </RoutingRule>
    </RoutingRules>
  </WebsiteConfiguration>
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

  defp put_website(bucket, body, opts \\ []) do
    SigV4Request.signed_conn(:put, "/#{bucket}",
      query: %{"website" => ""},
      body: body,
      headers: [{"content-md5", content_md5(body)}] ++ Keyword.get(opts, :headers, [])
    )
    |> call()
  end

  defp content_md5(body), do: :crypto.hash(:md5, body) |> Base.encode64()
  defp content_sha256(body), do: :crypto.hash(:sha256, body) |> Base.encode64()

  defp website_conn(method, bucket, path, opts \\ []) do
    path = if String.starts_with?(path, "/"), do: path, else: "/" <> path

    SigV4Request.anon_conn(method, path, opts)
    |> Map.put(:host, "#{bucket}.s3-website.localhost")
  end

  defp allow_public_get(bucket) do
    policy =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Principal":"*","Action":"s3:GetObject","Resource":"arn:aws:s3:::#{bucket}/*"}})

    SigV4Request.signed_conn(:put, "/#{bucket}",
      query: %{"policy" => ""},
      body: policy,
      headers: [{"content-type", "application/json"}]
    )
    |> call()
  end

  defp put_object(bucket, key, body, headers \\ []) do
    SigV4Request.signed_conn(:put, "/#{bucket}/#{key}", body: body, headers: headers)
    |> call()
  end

  defp sse_c_headers(customer_key) do
    [
      {"x-amz-server-side-encryption-customer-algorithm", "AES256"},
      {"x-amz-server-side-encryption-customer-key", Base.encode64(customer_key)},
      {"x-amz-server-side-encryption-customer-key-md5",
       :crypto.hash(:md5, customer_key) |> Base.encode64()}
    ]
  end

  test "PutBucketWebsite, GetBucketWebsite, and DeleteBucketWebsite round-trip" do
    assert (SigV4Request.signed_conn(:put, "/webcfg") |> call()).status == 200

    put = put_website("webcfg", @website)

    assert put.status == 200
    assert put.resp_body == ""

    assert {:ok, config} = BucketConfigs.get("webcfg", :website)
    assert config["index_document"] == %{"suffix" => "index.html"}
    assert config["error_document"] == %{"key" => "404.html"}
    assert [rule] = config["routing_rules"]
    assert rule["condition"] == %{"key_prefix_equals" => "docs/"}

    get =
      SigV4Request.signed_conn(:get, "/webcfg", query: %{"website" => ""})
      |> call()

    assert get.status == 200
    assert get_resp_header(get, "content-type") |> hd() =~ "application/xml"
    assert get.resp_body =~ "<WebsiteConfiguration"
    assert get.resp_body =~ "<Suffix>index.html</Suffix>"
    assert get.resp_body =~ "<ReplaceKeyPrefixWith>documents/</ReplaceKeyPrefixWith>"

    delete =
      SigV4Request.signed_conn(:delete, "/webcfg", query: %{"website" => ""})
      |> call()

    assert delete.status == 204
    assert delete.resp_body == ""
    assert BucketConfigs.get("webcfg", :website) == :none

    missing =
      SigV4Request.signed_conn(:get, "/webcfg", query: %{"website" => ""})
      |> call()

    assert missing.status == 404
    assert missing.resp_body =~ "NoSuchWebsiteConfiguration"

    idempotent =
      SigV4Request.signed_conn(:delete, "/webcfg", query: %{"website" => ""})
      |> call()

    assert idempotent.status == 204
  end

  test "website endpoint serves index documents without changing the REST endpoint" do
    bucket = "webdata"

    index_only =
      ~s(<WebsiteConfiguration><IndexDocument><Suffix>index.html</Suffix></IndexDocument><ErrorDocument><Key>404.html</Key></ErrorDocument></WebsiteConfiguration>)

    assert (SigV4Request.signed_conn(:put, "/#{bucket}") |> call()).status == 200
    assert put_website(bucket, index_only).status == 200
    assert allow_public_get(bucket).status == 204

    assert put_object(bucket, "index.html", "home").status == 200
    assert put_object(bucket, "docs/index.html", "docs home").status == 200

    root = website_conn(:get, bucket, "/") |> call()
    assert root.status == 200
    assert root.resp_body == "home"

    with_rest_override_query =
      website_conn(:get, bucket, "/", query: %{"response-content-type" => "text/plain"})
      |> call()

    assert with_rest_override_query.status == 200
    assert with_rest_override_query.resp_body == "home"

    assert get_resp_header(with_rest_override_query, "content-type") |> hd() =~
             "binary/octet-stream"

    range = website_conn(:get, bucket, "/", headers: [{"range", "bytes=1-2"}]) |> call()
    assert range.status == 206
    assert range.resp_body == "om"
    assert get_resp_header(range, "content-range") == ["bytes 1-2/4"]

    etag = get_resp_header(root, "etag") |> hd()
    not_modified = website_conn(:get, bucket, "/", headers: [{"if-none-match", etag}]) |> call()
    assert not_modified.status == 304
    assert not_modified.resp_body == ""

    folder = website_conn(:get, bucket, "/docs/") |> call()
    assert folder.status == 200
    assert folder.resp_body == "docs home"

    slash_redirect =
      website_conn(:get, bucket, "/docs",
        query: %{"v" => "1", "response-content-type" => "text/plain"}
      )
      |> call()

    assert slash_redirect.status == 302
    assert get_resp_header(slash_redirect, "location") == ["/docs/?v=1"]

    rest =
      SigV4Request.signed_conn(:get, "/#{bucket}/")
      |> call()

    assert rest.status == 200
    assert rest.resp_body =~ "<ListBucketResult"
    refute rest.resp_body == "home"
  end

  test "website endpoint serves configured error document with the original status" do
    bucket = "weberror"
    assert (SigV4Request.signed_conn(:put, "/#{bucket}") |> call()).status == 200
    assert put_website(bucket, @website).status == 200
    assert allow_public_get(bucket).status == 204

    assert put_object(bucket, "404.html", "custom missing", [{"content-type", "text/html"}]).status ==
             200

    missing = website_conn(:get, bucket, "/missing.html") |> call()
    assert missing.status == 404
    assert missing.resp_body == "custom missing"
    assert get_resp_header(missing, "content-type") |> hd() =~ "text/html"

    head = website_conn(:head, bucket, "/missing.html") |> call()
    assert head.status == 404
    assert head.resp_body == ""
    assert get_resp_header(head, "content-length") == ["14"]
  end

  test "website endpoint applies redirect-all and routing rules" do
    redirect_bucket = "webredirectall"

    redirect_all_xml =
      ~s(<WebsiteConfiguration><RedirectAllRequestsTo><HostName>example.com</HostName><Protocol>https</Protocol></RedirectAllRequestsTo></WebsiteConfiguration>)

    assert (SigV4Request.signed_conn(:put, "/#{redirect_bucket}") |> call()).status == 200
    assert put_website(redirect_bucket, redirect_all_xml).status == 200

    redirected =
      website_conn(:get, redirect_bucket, "/old/page.html",
        query: %{"v" => "1", "X-Amz-Signature" => "abc"}
      )
      |> call()

    assert redirected.status == 301
    assert get_resp_header(redirected, "location") == ["https://example.com/old/page.html?v=1"]

    routing_bucket = "webrouting"

    routing_xml = """
    <WebsiteConfiguration>
      <IndexDocument><Suffix>index.html</Suffix></IndexDocument>
      <RoutingRules>
        <RoutingRule>
          <Condition><KeyPrefixEquals>old/</KeyPrefixEquals></Condition>
          <Redirect><ReplaceKeyPrefixWith>new/</ReplaceKeyPrefixWith><HttpRedirectCode>302</HttpRedirectCode></Redirect>
        </RoutingRule>
        <RoutingRule>
          <Condition><KeyPrefixEquals>gone/</KeyPrefixEquals><HttpErrorCodeReturnedEquals>404</HttpErrorCodeReturnedEquals></Condition>
          <Redirect><HostName>archive.example.com</HostName><ReplaceKeyPrefixWith>archived/</ReplaceKeyPrefixWith><HttpRedirectCode>307</HttpRedirectCode></Redirect>
        </RoutingRule>
      </RoutingRules>
    </WebsiteConfiguration>
    """

    assert (SigV4Request.signed_conn(:put, "/#{routing_bucket}") |> call()).status == 200
    assert put_website(routing_bucket, routing_xml).status == 200
    assert allow_public_get(routing_bucket).status == 204

    prefix = website_conn(:get, routing_bucket, "/old/page.html") |> call()
    assert prefix.status == 302
    assert get_resp_header(prefix, "location") == ["/new/page.html"]

    error_redirect = website_conn(:get, routing_bucket, "/gone/page.html") |> call()
    assert error_redirect.status == 307

    assert get_resp_header(error_redirect, "location") == [
             "http://archive.example.com/archived/page.html"
           ]
  end

  test "website endpoint uses object-level redirect metadata while REST GET still reads bytes" do
    bucket = "webobjredirect"
    assert (SigV4Request.signed_conn(:put, "/#{bucket}") |> call()).status == 200
    assert put_website(bucket, @website).status == 200
    assert allow_public_get(bucket).status == 204

    assert put_object(bucket, "legacy.html", "legacy body", [
             {"x-amz-website-redirect-location", "/landing.html"}
           ]).status == 200

    website = website_conn(:get, bucket, "/legacy.html") |> call()
    assert website.status == 301
    assert website.resp_body == ""
    assert get_resp_header(website, "location") == ["/landing.html"]

    rest =
      SigV4Request.signed_conn(:get, "/#{bucket}/legacy.html")
      |> call()

    assert rest.status == 200
    assert rest.resp_body == "legacy body"
    assert get_resp_header(rest, "x-amz-website-redirect-location") == ["/landing.html"]
  end

  test "website endpoint renders default HTML errors and requester pays remains forbidden" do
    bucket = "webhtmlerrors"

    index_only =
      ~s(<WebsiteConfiguration><IndexDocument><Suffix>index.html</Suffix></IndexDocument></WebsiteConfiguration>)

    assert (SigV4Request.signed_conn(:put, "/#{bucket}") |> call()).status == 200
    assert put_website(bucket, index_only).status == 200
    assert put_object(bucket, "index.html", "home").status == 200

    private = website_conn(:get, bucket, "/") |> call()
    assert private.status == 403
    assert get_resp_header(private, "content-type") |> hd() =~ "text/html"
    assert private.resp_body =~ "<html>"
    refute private.resp_body =~ "<Error>"

    missing_private = website_conn(:get, bucket, "/absent.html") |> call()
    assert missing_private.status == 404
    assert get_resp_header(missing_private, "content-type") |> hd() =~ "text/html"
    assert missing_private.resp_body =~ "NoSuchKey"

    assert allow_public_get(bucket).status == 204
    assert :ok = BucketConfigs.put(bucket, :request_payment, %{"Payer" => "Requester"})

    requester_ack =
      website_conn(:get, bucket, "/",
        query: %{"x-amz-request-payer" => "requester"},
        headers: [{"x-amz-request-payer", "requester"}]
      )
      |> call()

    assert requester_ack.status == 403
    assert get_resp_header(requester_ack, "content-type") |> hd() =~ "text/html"
    assert requester_ack.resp_body =~ "AccessDenied"

    redirect_bucket = "webrequestpayredirect"

    redirect_all_xml =
      ~s(<WebsiteConfiguration><RedirectAllRequestsTo><HostName>example.com</HostName><Protocol>https</Protocol></RedirectAllRequestsTo></WebsiteConfiguration>)

    assert (SigV4Request.signed_conn(:put, "/#{redirect_bucket}") |> call()).status == 200
    assert put_website(redirect_bucket, redirect_all_xml).status == 200
    assert :ok = BucketConfigs.put(redirect_bucket, :request_payment, %{"Payer" => "Requester"})

    blocked_redirect = website_conn(:get, redirect_bucket, "/anything") |> call()
    assert blocked_redirect.status == 403
    assert get_resp_header(blocked_redirect, "location") == []
  end

  test "website endpoint rejects SSE-C objects instead of accepting customer keys over HTTP" do
    bucket = "webssec"
    customer_key = :crypto.strong_rand_bytes(32)

    index_only =
      ~s(<WebsiteConfiguration><IndexDocument><Suffix>index.html</Suffix></IndexDocument></WebsiteConfiguration>)

    assert (SigV4Request.signed_conn(:put, "/#{bucket}") |> call()).status == 200
    assert put_website(bucket, index_only).status == 200
    assert allow_public_get(bucket).status == 204

    assert put_object(bucket, "secret.txt", "secret body", sse_c_headers(customer_key)).status ==
             200

    website =
      website_conn(:get, bucket, "/secret.txt", headers: sse_c_headers(customer_key))
      |> call()

    assert website.status == 400
    assert get_resp_header(website, "content-type") |> hd() =~ "text/html"
    assert website.resp_body =~ "SSE-C objects are not supported"
  end

  test "website endpoint serves SSE-S3 objects as plaintext before sending headers" do
    bucket = "websses3"

    assert (SigV4Request.signed_conn(:put, "/#{bucket}") |> call()).status == 200
    assert put_website(bucket, @website).status == 200
    assert allow_public_get(bucket).status == 204

    plain = String.duplicate("0123456789abcdef", 5_000)

    assert put_object(bucket, "secret.txt", plain, [
             {"content-type", "text/plain"},
             {"x-amz-server-side-encryption", "AES256"}
           ]).status == 200

    assert put_object(bucket, "404.html", "encrypted missing", [
             {"content-type", "text/html"},
             {"x-amz-server-side-encryption", "AES256"}
           ]).status == 200

    full = website_conn(:get, bucket, "/secret.txt") |> call()
    assert full.status == 200
    assert full.resp_body == plain
    assert get_resp_header(full, "content-length") == [Integer.to_string(byte_size(plain))]
    assert get_resp_header(full, "content-type") |> hd() =~ "text/plain"

    head = website_conn(:head, bucket, "/secret.txt") |> call()
    assert head.status == 200
    assert head.resp_body == ""
    assert get_resp_header(head, "content-length") == [Integer.to_string(byte_size(plain))]

    range =
      website_conn(:get, bucket, "/secret.txt", headers: [{"range", "bytes=65530-65555"}])
      |> call()

    assert range.status == 206
    assert range.resp_body == binary_part(plain, 65_530, 26)
    assert get_resp_header(range, "content-range") == ["bytes 65530-65555/#{byte_size(plain)}"]
    assert get_resp_header(range, "content-length") == ["26"]

    missing = website_conn(:get, bucket, "/missing.html") |> call()
    assert missing.status == 404
    assert missing.resp_body == "encrypted missing"
  end

  test "website endpoint fail-closes SSE-KMS and DSSE-KMS objects" do
    bucket = "webssekms"

    index_only =
      ~s(<WebsiteConfiguration><IndexDocument><Suffix>index.html</Suffix></IndexDocument></WebsiteConfiguration>)

    assert (SigV4Request.signed_conn(:put, "/#{bucket}") |> call()).status == 200
    assert put_website(bucket, index_only).status == 200
    assert allow_public_get(bucket).status == 204

    for {key, algorithm} <- [{"kms.txt", "aws:kms"}, {"dsse.txt", "aws:kms:dsse"}] do
      assert put_object(bucket, key, "secret body", [
               {"x-amz-server-side-encryption", algorithm}
             ]).status == 200

      website = website_conn(:get, bucket, "/#{key}") |> call()
      assert website.status == 501
      assert website.resp_body =~ "SSE-KMS objects are not supported"

      head = website_conn(:head, bucket, "/#{key}") |> call()
      assert head.status == 501
      assert head.resp_body == ""
    end
  end

  test "private encrypted website objects fail authorization before encryption mode checks" do
    bucket = "webprivenc"
    customer_key = :crypto.strong_rand_bytes(32)

    index_only =
      ~s(<WebsiteConfiguration><IndexDocument><Suffix>index.html</Suffix></IndexDocument></WebsiteConfiguration>)

    assert (SigV4Request.signed_conn(:put, "/#{bucket}") |> call()).status == 200
    assert put_website(bucket, index_only).status == 200

    objects = [
      {"ssec.txt", "SSE-C", sse_c_headers(customer_key)},
      {"kms.txt", "aws:kms", [{"x-amz-server-side-encryption", "aws:kms"}]},
      {"dsse.txt", "aws:kms:dsse", [{"x-amz-server-side-encryption", "aws:kms:dsse"}]}
    ]

    for {key, _algorithm, headers} <- objects do
      assert put_object(bucket, key, "private secret", headers).status == 200

      get =
        website_conn(:get, bucket, "/#{key}", headers: headers)
        |> call()

      assert get.status == 403
      assert get.resp_body =~ "AccessDenied"
      refute get.resp_body =~ "SSE-C objects are not supported"
      refute get.resp_body =~ "SSE-KMS objects are not supported"

      head =
        website_conn(:head, bucket, "/#{key}", headers: headers)
        |> call()

      assert head.status == 403
      assert head.resp_body == ""
    end
  end

  test "missing bucket returns NoSuchBucket" do
    put =
      SigV4Request.signed_conn(:put, "/missing-webcfg", query: %{"website" => ""}, body: @website)
      |> call()

    assert put.status == 404
    assert put.resp_body =~ "NoSuchBucket"
  end

  test "invalid website XML fails closed and does not overwrite existing config" do
    assert (SigV4Request.signed_conn(:put, "/webbad") |> call()).status == 200

    good = put_website("webbad", @website)

    assert good.status == 200

    bad_xml =
      ~s(<WebsiteConfiguration><RedirectAllRequestsTo><HostName>example.com</HostName></RedirectAllRequestsTo><IndexDocument><Suffix>index.html</Suffix></IndexDocument></WebsiteConfiguration>)

    bad = put_website("webbad", bad_xml)

    assert bad.status == 400
    assert bad.resp_body =~ "MalformedXML"

    duplicate =
      ~s(<WebsiteConfiguration><IndexDocument><Suffix>index.html</Suffix><Suffix>home.html</Suffix></IndexDocument></WebsiteConfiguration>)

    duplicate_res = put_website("webbad", duplicate)

    assert duplicate_res.status == 400
    assert duplicate_res.resp_body =~ "MalformedXML"

    unknown =
      ~s(<WebsiteConfiguration><IndexDocument><Unknown>index.html</Unknown></IndexDocument></WebsiteConfiguration>)

    unknown_res = put_website("webbad", unknown)

    assert unknown_res.status == 400
    assert unknown_res.resp_body =~ "MalformedXML"

    assert {:ok, config} = BucketConfigs.get("webbad", :website)
    assert config["index_document"] == %{"suffix" => "index.html"}
    assert config["redirect_all_requests_to"] == nil
  end

  test "too many routing rules returns MalformedXML" do
    assert (SigV4Request.signed_conn(:put, "/webmany") |> call()).status == 200

    rules =
      1..51
      |> Enum.map(fn n ->
        """
        <RoutingRule>
          <Condition><KeyPrefixEquals>old-#{n}/</KeyPrefixEquals></Condition>
          <Redirect><ReplaceKeyPrefixWith>new-#{n}/</ReplaceKeyPrefixWith></Redirect>
        </RoutingRule>
        """
      end)
      |> Enum.join()

    xml =
      "<WebsiteConfiguration><IndexDocument><Suffix>index.html</Suffix></IndexDocument><RoutingRules>" <>
        rules <> "</RoutingRules></WebsiteConfiguration>"

    put = put_website("webmany", xml)

    assert put.status == 400
    assert put.resp_body =~ "MalformedXML"
    assert BucketConfigs.get("webmany", :website) == :none
  end

  test "object-level website subresource is method not allowed" do
    assert (SigV4Request.signed_conn(:put, "/webobj") |> call()).status == 200

    get =
      SigV4Request.signed_conn(:get, "/webobj/object.txt", query: %{"website" => ""})
      |> call()

    assert get.status == 405
    assert get.resp_body =~ "MethodNotAllowed"
  end

  test "DeleteBucketWebsite requires its own IAM action" do
    assert (SigV4Request.signed_conn(:put, "/webauthz") |> call()).status == 200

    put_policy =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:PutBucketWebsite","Resource":"arn:aws:s3:::webauthz"}})

    assert :ok = Store.put_principal_policy(@alice_arn, "put-website-only", put_policy)

    put =
      alice(:put, "/webauthz",
        query: %{"website" => ""},
        body: @website,
        headers: [{"content-md5", content_md5(@website)}]
      )
      |> call()

    assert put.status == 200

    denied =
      alice(:delete, "/webauthz", query: %{"website" => ""})
      |> call()

    assert denied.status == 403
    assert denied.resp_body =~ "AccessDenied"
    assert {:ok, _config} = BucketConfigs.get("webauthz", :website)

    delete_policy =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:DeleteBucketWebsite","Resource":"arn:aws:s3:::webauthz"}})

    assert :ok = Store.put_principal_policy(@alice_arn, "delete-website", delete_policy)

    allowed =
      alice(:delete, "/webauthz", query: %{"website" => ""})
      |> call()

    assert allowed.status == 204
    assert BucketConfigs.get("webauthz", :website) == :none
  end

  test "PutBucketWebsite requires and validates Content-MD5" do
    assert (SigV4Request.signed_conn(:put, "/webmd5") |> call()).status == 200

    missing =
      SigV4Request.signed_conn(:put, "/webmd5",
        query: %{"website" => ""},
        body: @website,
        auto_content_md5: false
      )
      |> call()

    assert missing.status == 400
    assert missing.resp_body =~ "MissingSecurityHeader"
    assert BucketConfigs.get("webmd5", :website) == :none

    bad =
      SigV4Request.signed_conn(:put, "/webmd5",
        query: %{"website" => ""},
        body: @website,
        headers: [{"content-md5", content_md5("different")}]
      )
      |> call()

    assert bad.status == 400
    assert bad.resp_body =~ "BadDigest"
    assert BucketConfigs.get("webmd5", :website) == :none
  end

  test "PutBucketWebsite validates modeled flexible checksum headers" do
    assert (SigV4Request.signed_conn(:put, "/webflex") |> call()).status == 200

    missing_value =
      SigV4Request.signed_conn(:put, "/webflex",
        query: %{"website" => ""},
        body: @website,
        headers: [
          {"content-md5", content_md5(@website)},
          {"x-amz-sdk-checksum-algorithm", "SHA256"}
        ]
      )
      |> call()

    assert missing_value.status == 400
    assert missing_value.resp_body =~ "InvalidRequest"
    assert BucketConfigs.get("webflex", :website) == :none

    bad_sha256 =
      SigV4Request.signed_conn(:put, "/webflex",
        query: %{"website" => ""},
        body: @website,
        headers: [
          {"content-md5", content_md5(@website)},
          {"x-amz-sdk-checksum-algorithm", "SHA256"},
          {"x-amz-checksum-sha256", content_sha256("different")}
        ]
      )
      |> call()

    assert bad_sha256.status == 400
    assert bad_sha256.resp_body =~ "BadDigest"
    assert BucketConfigs.get("webflex", :website) == :none

    ok =
      SigV4Request.signed_conn(:put, "/webflex",
        query: %{"website" => ""},
        body: @website,
        headers: [
          {"content-md5", content_md5(@website)},
          {"x-amz-sdk-checksum-algorithm", "SHA256"},
          {"x-amz-checksum-sha256", content_sha256(@website)}
        ]
      )
      |> call()

    assert ok.status == 200
    assert {:ok, config} = BucketConfigs.get("webflex", :website)
    assert config["index_document"] == %{"suffix" => "index.html"}
  end

  test "x-amz-expected-bucket-owner is enforced on Get Put and Delete" do
    assert (SigV4Request.signed_conn(:put, "/webowner") |> call()).status == 200

    denied_put =
      put_website("webowner", @website,
        headers: [{"x-amz-expected-bucket-owner", "999999999999"}]
      )

    assert denied_put.status == 403
    assert denied_put.resp_body =~ "AccessDenied"
    assert BucketConfigs.get("webowner", :website) == :none

    allowed_put =
      put_website("webowner", @website,
        headers: [{"x-amz-expected-bucket-owner", "000000000000"}]
      )

    assert allowed_put.status == 200

    denied_get =
      SigV4Request.signed_conn(:get, "/webowner",
        query: %{"website" => ""},
        headers: [{"x-amz-expected-bucket-owner", "999999999999"}]
      )
      |> call()

    assert denied_get.status == 403
    assert denied_get.resp_body =~ "AccessDenied"

    allowed_get =
      SigV4Request.signed_conn(:get, "/webowner",
        query: %{"website" => ""},
        headers: [{"x-amz-expected-bucket-owner", "000000000000"}]
      )
      |> call()

    assert allowed_get.status == 200
    assert allowed_get.resp_body =~ "<Suffix>index.html</Suffix>"

    denied_delete =
      SigV4Request.signed_conn(:delete, "/webowner",
        query: %{"website" => ""},
        headers: [{"x-amz-expected-bucket-owner", "999999999999"}]
      )
      |> call()

    assert denied_delete.status == 403
    assert denied_delete.resp_body =~ "AccessDenied"
    assert {:ok, _config} = BucketConfigs.get("webowner", :website)

    allowed_delete =
      SigV4Request.signed_conn(:delete, "/webowner",
        query: %{"website" => ""},
        headers: [{"x-amz-expected-bucket-owner", "000000000000"}]
      )
      |> call()

    assert allowed_delete.status == 204
    assert BucketConfigs.get("webowner", :website) == :none
  end

  test "checksum trailers and aws-chunked XML bodies require Content-MD5 and validate before storing config" do
    assert (SigV4Request.signed_conn(:put, "/webchunked") |> call()).status == 200

    plain_trailer =
      put_website("webchunked", @website,
        headers: [
          {"x-amz-sdk-checksum-algorithm", "SHA256"},
          {"x-amz-trailer", "x-amz-checksum-sha256"}
        ]
      )

    assert plain_trailer.status == 400
    assert plain_trailer.resp_body =~ "InvalidRequest"
    assert BucketConfigs.get("webchunked", :website) == :none

    missing_md5 =
      SigV4Request.signed_chunked_conn(:put, "/webchunked", @website,
        query: %{"website" => ""},
        auto_content_md5: false,
        headers: [{"x-amz-sdk-checksum-algorithm", "SHA256"}],
        trailer_headers: [{"x-amz-checksum-sha256", content_sha256(@website)}]
      )
      |> call()

    assert missing_md5.status == 400
    assert missing_md5.resp_body =~ "MissingSecurityHeader"
    assert BucketConfigs.get("webchunked", :website) == :none

    missing_trailer =
      SigV4Request.signed_chunked_conn(:put, "/webchunked", @website,
        query: %{"website" => ""},
        headers: [
          {"content-md5", content_md5(@website)},
          {"x-amz-sdk-checksum-algorithm", "SHA256"},
          {"x-amz-trailer", "x-amz-checksum-sha256"}
        ],
        streaming_payload_hash: "STREAMING-UNSIGNED-PAYLOAD-TRAILER"
      )
      |> call()

    assert missing_trailer.status == 400
    assert missing_trailer.resp_body =~ "IncompleteBody"
    assert BucketConfigs.get("webchunked", :website) == :none

    bad =
      SigV4Request.signed_chunked_conn(:put, "/webchunked", @website,
        query: %{"website" => ""},
        headers: [
          {"content-md5", content_md5(@website)},
          {"x-amz-sdk-checksum-algorithm", "SHA256"}
        ],
        trailer_headers: [{"x-amz-checksum-sha256", content_sha256("different")}]
      )
      |> call()

    assert bad.status == 400
    assert bad.resp_body =~ "BadDigest"
    assert BucketConfigs.get("webchunked", :website) == :none

    ok_trailer =
      SigV4Request.signed_chunked_conn(:put, "/webchunked", @website,
        query: %{"website" => ""},
        headers: [
          {"content-md5", content_md5(@website)},
          {"x-amz-sdk-checksum-algorithm", "SHA256"}
        ],
        trailer_headers: [{"x-amz-checksum-sha256", content_sha256(@website)}]
      )
      |> call()

    assert ok_trailer.status == 200
    assert {:ok, config} = BucketConfigs.get("webchunked", :website)
    assert config["index_document"] == %{"suffix" => "index.html"}

    signed_trailer =
      SigV4Request.signed_chunked_conn(:put, "/webchunked", @website,
        query: %{"website" => ""},
        headers: [
          {"content-md5", content_md5(@website)},
          {"x-amz-sdk-checksum-algorithm", "SHA256"}
        ],
        trailer_headers: [{"x-amz-checksum-sha256", content_sha256(@website)}],
        streaming_payload_hash: "STREAMING-AWS4-HMAC-SHA256-PAYLOAD-TRAILER"
      )
      |> call()

    assert signed_trailer.status == 200

    bad_signed_trailer =
      SigV4Request.signed_chunked_conn(:put, "/webchunked", @website,
        query: %{"website" => ""},
        headers: [
          {"content-md5", content_md5(@website)},
          {"x-amz-sdk-checksum-algorithm", "SHA256"}
        ],
        trailer_headers: [{"x-amz-checksum-sha256", content_sha256(@website)}],
        streaming_payload_hash: "STREAMING-AWS4-HMAC-SHA256-PAYLOAD-TRAILER",
        tamper: fn chunked ->
          Regex.replace(
            ~r/x-amz-trailer-signature:[0-9a-f]{64}/,
            chunked,
            "x-amz-trailer-signature:" <> String.duplicate("0", 64)
          )
        end
      )
      |> call()

    assert bad_signed_trailer.status == 403
    assert bad_signed_trailer.resp_body =~ "SignatureDoesNotMatch"
    assert {:ok, _config} = BucketConfigs.get("webchunked", :website)

    ok_chunked =
      SigV4Request.signed_chunked_conn(:put, "/webchunked", @website,
        query: %{"website" => ""},
        headers: [{"content-md5", content_md5(@website)}]
      )
      |> call()

    assert ok_chunked.status == 200

    oversized = String.duplicate("x", 131_073)

    too_large =
      SigV4Request.signed_chunked_conn(:put, "/webchunked", oversized,
        query: %{"website" => ""},
        chunk_size: byte_size(oversized),
        decoded_length_override: 131_072,
        headers: [{"content-md5", content_md5(oversized)}]
      )
      |> call()

    assert too_large.status == 400
    assert too_large.resp_body =~ "MalformedXML"
    assert too_large.resp_body =~ "WebsiteConfiguration exceeds 128KB"

    assert {:ok, config_after_failure} = BucketConfigs.get("webchunked", :website)
    assert config_after_failure["index_document"] == %{"suffix" => "index.html"}
  end
end
