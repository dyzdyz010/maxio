defmodule Maxio.S3.RequestPaymentE2ETest do
  use Maxio.DataCase, async: false

  import Plug.Conn

  alias Maxio.Auth.CredentialStore
  alias Maxio.Auth.SigV4.{Canonical, Signer}
  alias Maxio.BucketConfigs
  alias Maxio.Policy.Store
  alias Maxio.S3.Endpoint
  alias Maxio.Test.SigV4Request

  @data_dir Path.join(System.tmp_dir!(), "maxio_request_payment_e2e")
  @alice_ak "AKIAREQUESTPAYMENT01"
  @alice_secret "requestpaymentrequestpay123"
  @alice_arn "arn:aws:iam:::user/" <> @alice_ak
  @requester """
  <RequestPaymentConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
    <Payer>Requester</Payer>
  </RequestPaymentConfiguration>
  """
  @bucket_owner """
  <RequestPaymentConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
    <Payer>BucketOwner</Payer>
  </RequestPaymentConfiguration>
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

  defp alice_raw_query(method, path, raw_query, opts \\ []) do
    body = Keyword.get(opts, :body, "")
    extra_headers = Keyword.get(opts, :headers, [])
    now = DateTime.utc_now()
    amz_date = Calendar.strftime(now, "%Y%m%dT%H%M%SZ")
    scope_date = Calendar.strftime(now, "%Y%m%d")
    scope = "#{scope_date}/us-east-1/s3/aws4_request"
    payload_hash = Signer.hex_sha256(body)

    base_headers =
      [
        {"host", "localhost"},
        {"x-amz-content-sha256", payload_hash},
        {"x-amz-date", amz_date}
      ] ++ Enum.map(extra_headers, fn {key, value} -> {String.downcase(key), value} end)

    canonical_req = %{
      method: to_string(method) |> String.upcase(),
      path: URI.decode(path),
      query: raw_query,
      headers: base_headers,
      payload_hash: payload_hash
    }

    canonical = Canonical.canonical_request(canonical_req)
    string_to_sign = Signer.string_to_sign(amz_date, scope, canonical, "AWS4-HMAC-SHA256")
    key = Signer.derive_signing_key(@alice_secret, scope_date, "us-east-1", "s3")
    signature = Signer.signature(key, string_to_sign)
    signed_headers = Canonical.signed_headers(base_headers)

    auth =
      "AWS4-HMAC-SHA256 Credential=#{@alice_ak}/#{scope}," <>
        "SignedHeaders=#{signed_headers},Signature=#{signature}"

    full_path = if raw_query == "", do: path, else: path <> "?" <> raw_query

    conn =
      Plug.Test.conn(method, full_path, body)
      |> Map.put(:host, "localhost")
      |> put_private(:maxio_now, now)

    base_headers
    |> Enum.reject(fn {key, _value} -> key == "host" end)
    |> Enum.reduce(conn, fn {key, value}, acc -> put_req_header(acc, key, value) end)
    |> put_req_header("authorization", auth)
  end

  defp put_request_payment(bucket, body, opts \\ []) do
    SigV4Request.signed_conn(:put, "/#{bucket}",
      query: %{"requestPayment" => ""},
      body: body,
      headers: [{"content-md5", content_md5(body)}] ++ Keyword.get(opts, :headers, [])
    )
    |> call()
  end

  defp content_md5(body), do: :crypto.hash(:md5, body) |> Base.encode64()
  defp content_sha256(body), do: :crypto.hash(:sha256, body) |> Base.encode64()

  defp enable_versioning(bucket) do
    body = ~s(<VersioningConfiguration><Status>Enabled</Status></VersioningConfiguration>)

    SigV4Request.signed_conn(:put, "/#{bucket}", query: %{"versioning" => ""}, body: body)
    |> call()
  end

  defp allow_alice_data_plane(bucket, actions \\ :all) do
    object_actions =
      case actions do
        :all ->
          [
            "s3:GetObject",
            "s3:PutObject",
            "s3:DeleteObject",
            "s3:GetObjectTagging",
            "s3:PutObjectTagging",
            "s3:DeleteObjectTagging",
            "s3:GetObjectAcl",
            "s3:PutObjectAcl",
            "s3:AbortMultipartUpload",
            "s3:ListMultipartUploadParts"
          ]

        actions when is_list(actions) ->
          actions
      end

    policy =
      ~s({"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":#{Jason.encode!(object_actions)},"Resource":"arn:aws:s3:::#{bucket}/*"},{"Effect":"Allow","Action":["s3:ListBucket","s3:ListBucketVersions","s3:ListBucketMultipartUploads"],"Resource":"arn:aws:s3:::#{bucket}"}]})

    Store.put_principal_policy(@alice_arn, "data-plane-#{bucket}", policy)
  end

  defp assert_charged(conn),
    do: assert(get_resp_header(conn, "x-amz-request-charged") == ["requester"])

  defp refute_charged(conn), do: assert(get_resp_header(conn, "x-amz-request-charged") == [])

  defp upload_id(body) do
    [_, upload_id] = Regex.run(~r/<UploadId>([^<]+)<\/UploadId>/, body)
    upload_id
  end

  test "GetBucketRequestPayment returns default BucketOwner and Put round-trips Payer" do
    assert (SigV4Request.signed_conn(:put, "/requestpay") |> call()).status == 200

    default =
      SigV4Request.signed_conn(:get, "/requestpay", query: %{"requestPayment" => ""})
      |> call()

    assert default.status == 200
    assert get_resp_header(default, "content-type") |> hd() =~ "application/xml"
    assert default.resp_body =~ "<RequestPaymentConfiguration"
    assert default.resp_body =~ "<Payer>BucketOwner</Payer>"
    assert BucketConfigs.get("requestpay", :request_payment) == :none

    put_requester = put_request_payment("requestpay", @requester)

    assert put_requester.status == 200
    assert put_requester.resp_body == ""
    assert {:ok, %{"Payer" => "Requester"}} = BucketConfigs.get("requestpay", :request_payment)

    requester =
      SigV4Request.signed_conn(:get, "/requestpay", query: %{"requestPayment" => ""})
      |> call()

    assert requester.status == 200
    assert requester.resp_body =~ "<Payer>Requester</Payer>"

    put_bucket_owner = put_request_payment("requestpay", @bucket_owner)

    assert put_bucket_owner.status == 200

    assert {:ok, %{"Payer" => "BucketOwner"}} =
             BucketConfigs.get("requestpay", :request_payment)
  end

  test "missing bucket returns NoSuchBucket" do
    put =
      SigV4Request.signed_conn(:put, "/missing-requestpay",
        query: %{"requestPayment" => ""},
        body: @requester,
        headers: [{"content-md5", content_md5(@requester)}]
      )
      |> call()

    assert put.status == 404
    assert put.resp_body =~ "NoSuchBucket"

    get =
      SigV4Request.signed_conn(:get, "/missing-requestpay", query: %{"requestPayment" => ""})
      |> call()

    assert get.status == 404
    assert get.resp_body =~ "NoSuchBucket"
  end

  test "invalid request payment XML fails closed and does not overwrite existing config" do
    assert (SigV4Request.signed_conn(:put, "/requestpaybad") |> call()).status == 200

    good = put_request_payment("requestpaybad", @requester)

    assert good.status == 200

    bad_body = "<RequestPaymentConfiguration><Payer>Owner</Payer></RequestPaymentConfiguration>"

    bad =
      put_request_payment("requestpaybad", bad_body)

    assert bad.status == 400
    assert bad.resp_body =~ "MalformedXML"

    assert {:ok, %{"Payer" => "Requester"}} =
             BucketConfigs.get("requestpaybad", :request_payment)
  end

  test "invalid stored request payment config fails closed instead of defaulting" do
    assert (SigV4Request.signed_conn(:put, "/requestpaystored") |> call()).status == 200
    assert :ok = BucketConfigs.put("requestpaystored", :request_payment, %{"Payer" => "Owner"})

    get =
      SigV4Request.signed_conn(:get, "/requestpaystored", query: %{"requestPayment" => ""})
      |> call()

    assert get.status == 500
    assert get.resp_body =~ "InternalError"

    assert :ok = BucketConfigs.put("requestpaystored", :request_payment, %{})

    missing_payer =
      SigV4Request.signed_conn(:get, "/requestpaystored", query: %{"requestPayment" => ""})
      |> call()

    assert missing_payer.status == 500
    assert missing_payer.resp_body =~ "InternalError"
  end

  test "PutBucketRequestPayment requires and validates Content-MD5" do
    assert (SigV4Request.signed_conn(:put, "/requestpaymd5") |> call()).status == 200

    missing =
      SigV4Request.signed_conn(:put, "/requestpaymd5",
        query: %{"requestPayment" => ""},
        body: @requester
      )
      |> call()

    assert missing.status == 400
    assert missing.resp_body =~ "MissingSecurityHeader"
    assert BucketConfigs.get("requestpaymd5", :request_payment) == :none

    bad =
      SigV4Request.signed_conn(:put, "/requestpaymd5",
        query: %{"requestPayment" => ""},
        body: @requester,
        headers: [{"content-md5", content_md5("different")}]
      )
      |> call()

    assert bad.status == 400
    assert bad.resp_body =~ "BadDigest"
    assert BucketConfigs.get("requestpaymd5", :request_payment) == :none
  end

  test "PutBucketRequestPayment validates modeled flexible checksum headers" do
    assert (SigV4Request.signed_conn(:put, "/requestpayflex") |> call()).status == 200

    missing_value =
      SigV4Request.signed_conn(:put, "/requestpayflex",
        query: %{"requestPayment" => ""},
        body: @requester,
        headers: [
          {"content-md5", content_md5(@requester)},
          {"x-amz-sdk-checksum-algorithm", "SHA256"}
        ]
      )
      |> call()

    assert missing_value.status == 400
    assert missing_value.resp_body =~ "InvalidRequest"
    assert BucketConfigs.get("requestpayflex", :request_payment) == :none

    bad_sha256 =
      SigV4Request.signed_conn(:put, "/requestpayflex",
        query: %{"requestPayment" => ""},
        body: @requester,
        headers: [
          {"content-md5", content_md5(@requester)},
          {"x-amz-sdk-checksum-algorithm", "SHA256"},
          {"x-amz-checksum-sha256", :crypto.hash(:sha256, "different") |> Base.encode64()}
        ]
      )
      |> call()

    assert bad_sha256.status == 400
    assert bad_sha256.resp_body =~ "BadDigest"
    assert BucketConfigs.get("requestpayflex", :request_payment) == :none

    ok =
      SigV4Request.signed_conn(:put, "/requestpayflex",
        query: %{"requestPayment" => ""},
        body: @requester,
        headers: [
          {"content-md5", content_md5(@requester)},
          {"x-amz-sdk-checksum-algorithm", "SHA256"},
          {"x-amz-checksum-sha256", :crypto.hash(:sha256, @requester) |> Base.encode64()}
        ]
      )
      |> call()

    assert ok.status == 200

    assert {:ok, %{"Payer" => "Requester"}} =
             BucketConfigs.get("requestpayflex", :request_payment)
  end

  test "x-amz-expected-bucket-owner is enforced on Get and Put" do
    assert (SigV4Request.signed_conn(:put, "/requestpayowner") |> call()).status == 200

    denied_put =
      put_request_payment("requestpayowner", @requester,
        headers: [{"x-amz-expected-bucket-owner", "999999999999"}]
      )

    assert denied_put.status == 403
    assert denied_put.resp_body =~ "AccessDenied"
    assert BucketConfigs.get("requestpayowner", :request_payment) == :none

    allowed_put =
      put_request_payment("requestpayowner", @requester,
        headers: [{"x-amz-expected-bucket-owner", "000000000000"}]
      )

    assert allowed_put.status == 200

    denied_get =
      SigV4Request.signed_conn(:get, "/requestpayowner",
        query: %{"requestPayment" => ""},
        headers: [{"x-amz-expected-bucket-owner", "999999999999"}]
      )
      |> call()

    assert denied_get.status == 403
    assert denied_get.resp_body =~ "AccessDenied"

    allowed_get =
      SigV4Request.signed_conn(:get, "/requestpayowner",
        query: %{"requestPayment" => ""},
        headers: [{"x-amz-expected-bucket-owner", "000000000000"}]
      )
      |> call()

    assert allowed_get.status == 200
    assert allowed_get.resp_body =~ "<Payer>Requester</Payer>"
  end

  test "checksum trailers and aws-chunked XML bodies require Content-MD5 and validate before storing config" do
    assert (SigV4Request.signed_conn(:put, "/requestpaychunked") |> call()).status == 200

    plain_trailer =
      put_request_payment("requestpaychunked", @requester,
        headers: [
          {"x-amz-sdk-checksum-algorithm", "SHA256"},
          {"x-amz-trailer", "x-amz-checksum-sha256"}
        ]
      )

    assert plain_trailer.status == 400
    assert plain_trailer.resp_body =~ "InvalidRequest"
    assert BucketConfigs.get("requestpaychunked", :request_payment) == :none

    missing_md5 =
      SigV4Request.signed_chunked_conn(:put, "/requestpaychunked", @requester,
        query: %{"requestPayment" => ""},
        headers: [{"x-amz-sdk-checksum-algorithm", "SHA256"}],
        trailer_headers: [{"x-amz-checksum-sha256", content_sha256(@requester)}]
      )
      |> call()

    assert missing_md5.status == 400
    assert missing_md5.resp_body =~ "MissingSecurityHeader"
    assert BucketConfigs.get("requestpaychunked", :request_payment) == :none

    missing_trailer =
      SigV4Request.signed_chunked_conn(:put, "/requestpaychunked", @requester,
        query: %{"requestPayment" => ""},
        headers: [
          {"content-md5", content_md5(@requester)},
          {"x-amz-sdk-checksum-algorithm", "SHA256"},
          {"x-amz-trailer", "x-amz-checksum-sha256"}
        ],
        streaming_payload_hash: "STREAMING-UNSIGNED-PAYLOAD-TRAILER"
      )
      |> call()

    assert missing_trailer.status == 400
    assert missing_trailer.resp_body =~ "IncompleteBody"
    assert BucketConfigs.get("requestpaychunked", :request_payment) == :none

    bad =
      SigV4Request.signed_chunked_conn(:put, "/requestpaychunked", @requester,
        query: %{"requestPayment" => ""},
        headers: [
          {"content-md5", content_md5(@requester)},
          {"x-amz-sdk-checksum-algorithm", "SHA256"}
        ],
        trailer_headers: [{"x-amz-checksum-sha256", content_sha256("different")}]
      )
      |> call()

    assert bad.status == 400
    assert bad.resp_body =~ "BadDigest"
    assert BucketConfigs.get("requestpaychunked", :request_payment) == :none

    ok_trailer =
      SigV4Request.signed_chunked_conn(:put, "/requestpaychunked", @requester,
        query: %{"requestPayment" => ""},
        headers: [
          {"content-md5", content_md5(@requester)},
          {"x-amz-sdk-checksum-algorithm", "SHA256"}
        ],
        trailer_headers: [{"x-amz-checksum-sha256", content_sha256(@requester)}]
      )
      |> call()

    assert ok_trailer.status == 200

    assert {:ok, %{"Payer" => "Requester"}} =
             BucketConfigs.get("requestpaychunked", :request_payment)

    signed_trailer =
      SigV4Request.signed_chunked_conn(:put, "/requestpaychunked", @bucket_owner,
        query: %{"requestPayment" => ""},
        headers: [
          {"content-md5", content_md5(@bucket_owner)},
          {"x-amz-sdk-checksum-algorithm", "SHA256"}
        ],
        trailer_headers: [{"x-amz-checksum-sha256", content_sha256(@bucket_owner)}],
        streaming_payload_hash: "STREAMING-AWS4-HMAC-SHA256-PAYLOAD-TRAILER"
      )
      |> call()

    assert signed_trailer.status == 200

    assert {:ok, %{"Payer" => "BucketOwner"}} =
             BucketConfigs.get("requestpaychunked", :request_payment)

    bad_signed_trailer =
      SigV4Request.signed_chunked_conn(:put, "/requestpaychunked", @requester,
        query: %{"requestPayment" => ""},
        headers: [
          {"content-md5", content_md5(@requester)},
          {"x-amz-sdk-checksum-algorithm", "SHA256"}
        ],
        trailer_headers: [{"x-amz-checksum-sha256", content_sha256(@requester)}],
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

    assert {:ok, %{"Payer" => "BucketOwner"}} =
             BucketConfigs.get("requestpaychunked", :request_payment)

    ok_chunked =
      SigV4Request.signed_chunked_conn(:put, "/requestpaychunked", @requester,
        query: %{"requestPayment" => ""},
        headers: [{"content-md5", content_md5(@requester)}]
      )
      |> call()

    assert ok_chunked.status == 200

    assert {:ok, %{"Payer" => "Requester"}} =
             BucketConfigs.get("requestpaychunked", :request_payment)

    oversized = String.duplicate("x", 131_073)

    too_large =
      SigV4Request.signed_chunked_conn(:put, "/requestpaychunked", oversized,
        query: %{"requestPayment" => ""},
        chunk_size: byte_size(oversized),
        decoded_length_override: 131_072,
        headers: [{"content-md5", content_md5(oversized)}]
      )
      |> call()

    assert too_large.status == 400
    assert too_large.resp_body =~ "MalformedXML"
    assert too_large.resp_body =~ "RequestPaymentConfiguration exceeds 128KB"

    assert {:ok, %{"Payer" => "Requester"}} =
             BucketConfigs.get("requestpaychunked", :request_payment)
  end

  test "object-level requestPayment subresource and unsupported methods are method not allowed" do
    assert (SigV4Request.signed_conn(:put, "/requestpaymethod") |> call()).status == 200

    object_get =
      SigV4Request.signed_conn(:get, "/requestpaymethod/object.txt",
        query: %{"requestPayment" => ""}
      )
      |> call()

    assert object_get.status == 405
    assert object_get.resp_body =~ "MethodNotAllowed"

    delete =
      SigV4Request.signed_conn(:delete, "/requestpaymethod", query: %{"requestPayment" => ""})
      |> call()

    assert delete.status == 405
    assert delete.resp_body =~ "MethodNotAllowed"
  end

  test "GetBucketRequestPayment and PutBucketRequestPayment use distinct IAM actions" do
    assert (SigV4Request.signed_conn(:put, "/requestpayauthz") |> call()).status == 200

    get_policy =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:GetBucketRequestPayment","Resource":"arn:aws:s3:::requestpayauthz"}})

    assert :ok = Store.put_principal_policy(@alice_arn, "get-request-payment-only", get_policy)

    get =
      alice(:get, "/requestpayauthz", query: %{"requestPayment" => ""})
      |> call()

    assert get.status == 200
    assert get.resp_body =~ "<Payer>BucketOwner</Payer>"

    denied =
      alice(:put, "/requestpayauthz",
        query: %{"requestPayment" => ""},
        body: @requester,
        headers: [{"content-md5", content_md5(@requester)}]
      )
      |> call()

    assert denied.status == 403
    assert denied.resp_body =~ "AccessDenied"
    assert BucketConfigs.get("requestpayauthz", :request_payment) == :none

    put_policy =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:PutBucketRequestPayment","Resource":"arn:aws:s3:::requestpayauthz"}})

    assert :ok = Store.put_principal_policy(@alice_arn, "put-request-payment", put_policy)

    allowed =
      alice(:put, "/requestpayauthz",
        query: %{"requestPayment" => ""},
        body: @requester,
        headers: [{"content-md5", content_md5(@requester)}]
      )
      |> call()

    assert allowed.status == 200

    assert {:ok, %{"Payer" => "Requester"}} =
             BucketConfigs.get("requestpayauthz", :request_payment)
  end

  test "bucket resource tags can gate request payment actions" do
    assert (SigV4Request.signed_conn(:put, "/requestpaytag") |> call()).status == 200

    tag_xml = """
    <Tagging><TagSet><Tag><Key>env</Key><Value>prod</Value></Tag></TagSet></Tagging>
    """

    assert (SigV4Request.signed_conn(:put, "/requestpaytag",
              query: %{"tagging" => ""},
              body: tag_xml
            )
            |> call()).status == 204

    conditioned =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:GetBucketRequestPayment","Resource":"arn:aws:s3:::requestpaytag","Condition":{"StringEquals":{"aws:ResourceTag/env":"prod"}}}})

    assert :ok = Store.put_principal_policy(@alice_arn, "get-request-payment-tagged", conditioned)

    allowed =
      alice(:get, "/requestpaytag", query: %{"requestPayment" => ""})
      |> call()

    assert allowed.status == 200

    dev_tag_xml = """
    <Tagging><TagSet><Tag><Key>env</Key><Value>dev</Value></Tag></TagSet></Tagging>
    """

    assert (SigV4Request.signed_conn(:put, "/requestpaytag",
              query: %{"tagging" => ""},
              body: dev_tag_xml
            )
            |> call()).status == 204

    denied =
      alice(:get, "/requestpaytag", query: %{"requestPayment" => ""})
      |> call()

    assert denied.status == 403
    assert denied.resp_body =~ "AccessDenied"
  end

  test "Requester Pays data plane requires payer for non-owner object and list requests" do
    bucket = "requestpaydata"

    assert (SigV4Request.signed_conn(:put, "/#{bucket}") |> call()).status == 200

    assert (SigV4Request.signed_conn(:put, "/#{bucket}/owner.txt", body: "owner-data")
            |> call()).status == 200

    assert put_request_payment(bucket, @requester).status == 200
    assert :ok = allow_alice_data_plane(bucket)

    owner_get = SigV4Request.signed_conn(:get, "/#{bucket}/owner.txt") |> call()
    assert owner_get.status == 200
    assert owner_get.resp_body == "owner-data"
    refute_charged(owner_get)

    missing_get =
      alice(:get, "/#{bucket}/owner.txt", [])
      |> call()

    assert missing_get.status == 403
    assert missing_get.resp_body =~ "AccessDenied"

    header_get =
      alice(:get, "/#{bucket}/owner.txt", headers: [{"x-amz-request-payer", "requester"}])
      |> call()

    assert header_get.status == 200
    assert header_get.resp_body == "owner-data"
    assert_charged(header_get)

    missing_head =
      alice(:head, "/#{bucket}/owner.txt", [])
      |> call()

    assert missing_head.status == 403

    charged_head =
      alice(:head, "/#{bucket}/owner.txt", headers: [{"x-amz-request-payer", "requester"}])
      |> call()

    assert charged_head.status == 200
    assert get_resp_header(charged_head, "content-length") == ["10"]
    assert_charged(charged_head)

    query_get =
      alice(:get, "/#{bucket}/owner.txt", query: %{"x-amz-request-payer" => "requester"})
      |> call()

    assert query_get.status == 200
    assert query_get.resp_body == "owner-data"
    assert_charged(query_get)

    encoded_space_query =
      alice_raw_query(:get, "/#{bucket}/owner.txt", "x-amz-request-payer=requester%20")
      |> call()

    assert encoded_space_query.status == 403
    assert encoded_space_query.resp_body =~ "AccessDenied"

    plus_query =
      alice_raw_query(:get, "/#{bucket}/owner.txt", "x-amz-request-payer=requester+")
      |> call()

    assert plus_query.status == 403
    assert plus_query.resp_body =~ "AccessDenied"

    unsigned_header =
      alice(:get, "/#{bucket}/owner.txt", [])
      |> put_req_header("x-amz-request-payer", "requester")
      |> call()

    assert unsigned_header.status == 403
    assert unsigned_header.resp_body =~ "AccessDenied"

    missing_list =
      alice(:get, "/#{bucket}", query: %{"list-type" => "2"})
      |> call()

    assert missing_list.status == 403
    assert missing_list.resp_body =~ "AccessDenied"

    charged_list =
      alice(:get, "/#{bucket}",
        query: %{"list-type" => "2", "x-amz-request-payer" => "requester"}
      )
      |> call()

    assert charged_list.status == 200
    assert charged_list.resp_body =~ "<Key>owner.txt</Key>"
    assert_charged(charged_list)

    missing_put =
      alice(:put, "/#{bucket}/alice.txt", body: "alice-data")
      |> call()

    assert missing_put.status == 403
    assert missing_put.resp_body =~ "AccessDenied"
    assert (SigV4Request.signed_conn(:head, "/#{bucket}/alice.txt") |> call()).status == 404

    charged_put =
      alice(:put, "/#{bucket}/alice.txt",
        body: "alice-data",
        headers: [{"x-amz-request-payer", "requester"}]
      )
      |> call()

    assert charged_put.status == 200
    assert_charged(charged_put)

    missing_delete =
      alice(:delete, "/#{bucket}/alice.txt", [])
      |> call()

    assert missing_delete.status == 403
    assert missing_delete.resp_body =~ "AccessDenied"

    assert (SigV4Request.signed_conn(:get, "/#{bucket}/alice.txt") |> call()).resp_body ==
             "alice-data"

    charged_delete =
      alice(:delete, "/#{bucket}/alice.txt", headers: [{"x-amz-request-payer", "requester"}])
      |> call()

    assert charged_delete.status == 204
    assert_charged(charged_delete)

    assert (SigV4Request.signed_conn(:put, "/#{bucket}/bulk-1.txt", body: "one") |> call()).status ==
             200

    assert (SigV4Request.signed_conn(:put, "/#{bucket}/bulk-2.txt", body: "two") |> call()).status ==
             200

    delete_xml =
      "<Delete><Object><Key>bulk-1.txt</Key></Object><Object><Key>bulk-2.txt</Key></Object></Delete>"

    missing_delete_objects =
      alice(:post, "/#{bucket}", query: %{"delete" => ""}, body: delete_xml)
      |> call()

    assert missing_delete_objects.status == 403
    assert missing_delete_objects.resp_body =~ "AccessDenied"
    assert (SigV4Request.signed_conn(:head, "/#{bucket}/bulk-1.txt") |> call()).status == 200
    assert (SigV4Request.signed_conn(:head, "/#{bucket}/bulk-2.txt") |> call()).status == 200

    charged_delete_objects =
      alice(:post, "/#{bucket}",
        query: %{"delete" => ""},
        body: delete_xml,
        headers: [{"x-amz-request-payer", "requester"}]
      )
      |> call()

    assert charged_delete_objects.status == 200
    assert charged_delete_objects.resp_body =~ "<Key>bulk-1.txt</Key>"
    assert charged_delete_objects.resp_body =~ "<Key>bulk-2.txt</Key>"
    assert_charged(charged_delete_objects)
    assert (SigV4Request.signed_conn(:head, "/#{bucket}/bulk-1.txt") |> call()).status == 404
    assert (SigV4Request.signed_conn(:head, "/#{bucket}/bulk-2.txt") |> call()).status == 404
  end

  test "Requester Pays GET and HEAD preserve Range, conditional, version, and delete marker semantics" do
    bucket = "requestpaycross"
    key = "object.txt"
    body = "0123456789"

    assert (SigV4Request.signed_conn(:put, "/#{bucket}") |> call()).status == 200
    assert enable_versioning(bucket).status == 200

    put = SigV4Request.signed_conn(:put, "/#{bucket}/#{key}", body: body) |> call()
    assert put.status == 200
    [version_id] = get_resp_header(put, "x-amz-version-id")
    [etag] = get_resp_header(put, "etag")

    assert put_request_payment(bucket, @requester).status == 200
    assert :ok = allow_alice_data_plane(bucket, ["s3:GetObject"])

    delete_marker = SigV4Request.signed_conn(:delete, "/#{bucket}/#{key}") |> call()
    assert delete_marker.status == 204
    [delete_marker_version_id] = get_resp_header(delete_marker, "x-amz-version-id")

    missing_payer =
      alice(:get, "/#{bucket}/#{key}", [])
      |> call()

    assert missing_payer.status == 403
    assert missing_payer.resp_body =~ "AccessDenied"

    latest_delete_marker =
      alice(:get, "/#{bucket}/#{key}", headers: [{"x-amz-request-payer", "requester"}])
      |> call()

    assert latest_delete_marker.status == 404
    assert get_resp_header(latest_delete_marker, "x-amz-delete-marker") == ["true"]
    assert get_resp_header(latest_delete_marker, "x-amz-version-id") == [delete_marker_version_id]

    latest_delete_marker_head =
      alice(:head, "/#{bucket}/#{key}", headers: [{"x-amz-request-payer", "requester"}])
      |> call()

    assert latest_delete_marker_head.status == 404
    assert latest_delete_marker_head.resp_body == ""
    assert get_resp_header(latest_delete_marker_head, "x-amz-delete-marker") == ["true"]

    assert get_resp_header(latest_delete_marker_head, "x-amz-version-id") == [
             delete_marker_version_id
           ]

    ranged_get =
      alice(:get, "/#{bucket}/#{key}",
        query: %{"versionId" => version_id},
        headers: [
          {"x-amz-request-payer", "requester"},
          {"range", "bytes=2-5"},
          {"if-match", etag}
        ]
      )
      |> call()

    assert ranged_get.status == 206
    assert ranged_get.resp_body == "2345"
    assert get_resp_header(ranged_get, "content-length") == ["4"]
    assert get_resp_header(ranged_get, "content-range") == ["bytes 2-5/10"]
    assert get_resp_header(ranged_get, "x-amz-version-id") == [version_id]
    assert get_resp_header(ranged_get, "etag") == [etag]
    assert_charged(ranged_get)

    ranged_head =
      alice(:head, "/#{bucket}/#{key}",
        query: %{"versionId" => version_id},
        headers: [
          {"x-amz-request-payer", "requester"},
          {"range", "bytes=2-5"},
          {"if-match", etag}
        ]
      )
      |> call()

    assert ranged_head.status == 200
    assert ranged_head.resp_body == ""
    assert get_resp_header(ranged_head, "content-length") == ["4"]
    assert get_resp_header(ranged_head, "content-range") == []
    assert get_resp_header(ranged_head, "x-amz-version-id") == [version_id]
    assert get_resp_header(ranged_head, "etag") == [etag]
    assert_charged(ranged_head)

    not_modified_get =
      alice(:get, "/#{bucket}/#{key}",
        query: %{"versionId" => version_id},
        headers: [
          {"x-amz-request-payer", "requester"},
          {"if-none-match", etag},
          {"range", "bytes=99-100"}
        ]
      )
      |> call()

    assert not_modified_get.status == 304
    assert not_modified_get.resp_body == ""
    assert get_resp_header(not_modified_get, "x-amz-version-id") == [version_id]
    assert get_resp_header(not_modified_get, "etag") == [etag]
    assert [_] = get_resp_header(not_modified_get, "last-modified")
    assert_charged(not_modified_get)

    not_modified_head =
      alice(:head, "/#{bucket}/#{key}",
        query: %{"versionId" => version_id},
        headers: [
          {"x-amz-request-payer", "requester"},
          {"if-none-match", etag},
          {"range", "bytes=99-100"}
        ]
      )
      |> call()

    assert not_modified_head.status == 304
    assert not_modified_head.resp_body == ""
    assert get_resp_header(not_modified_head, "x-amz-version-id") == [version_id]
    assert get_resp_header(not_modified_head, "etag") == [etag]
    assert [_] = get_resp_header(not_modified_head, "last-modified")
    assert_charged(not_modified_head)

    invalid_head_range =
      alice(:head, "/#{bucket}/#{key}",
        query: %{"versionId" => version_id},
        headers: [
          {"x-amz-request-payer", "requester"},
          {"if-match", etag},
          {"range", "bytes=99-100"}
        ]
      )
      |> call()

    assert invalid_head_range.status == 416
    assert invalid_head_range.resp_body == ""
    refute_charged(invalid_head_range)
  end

  test "Requester Pays rejects anonymous access even when bucket policy is public" do
    bucket = "requestpayanon"

    assert (SigV4Request.signed_conn(:put, "/#{bucket}") |> call()).status == 200

    assert (SigV4Request.signed_conn(:put, "/#{bucket}/public.txt", body: "public")
            |> call()).status == 200

    assert put_request_payment(bucket, @requester).status == 200

    policy =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Principal":"*","Action":"s3:GetObject","Resource":"arn:aws:s3:::#{bucket}/*"}})

    assert (SigV4Request.signed_conn(:put, "/#{bucket}",
              query: %{"policy" => ""},
              body: policy,
              headers: [{"content-type", "application/json"}]
            )
            |> call()).status == 204

    denied =
      SigV4Request.anon_conn(:get, "/#{bucket}/public.txt",
        headers: [{"x-amz-request-payer", "requester"}]
      )
      |> call()

    assert denied.status == 403
    assert denied.resp_body =~ "AccessDenied"
  end

  test "Requester Pays applies to CopyObject when either source or destination bucket is requester pays" do
    src_bucket = "requestpaysrc"
    dst_bucket = "requestpaydst"

    assert (SigV4Request.signed_conn(:put, "/#{src_bucket}") |> call()).status == 200
    assert (SigV4Request.signed_conn(:put, "/#{dst_bucket}") |> call()).status == 200

    assert (SigV4Request.signed_conn(:put, "/#{src_bucket}/src.txt", body: "copy-source")
            |> call()).status == 200

    assert put_request_payment(src_bucket, @requester).status == 200
    assert :ok = allow_alice_data_plane(src_bucket, ["s3:GetObject"])
    assert :ok = allow_alice_data_plane(dst_bucket, ["s3:PutObject"])

    source_missing =
      alice(:put, "/#{dst_bucket}/dst.txt",
        headers: [{"x-amz-copy-source", "/#{src_bucket}/src.txt"}]
      )
      |> call()

    assert source_missing.status == 403
    assert source_missing.resp_body =~ "AccessDenied"
    assert (SigV4Request.signed_conn(:head, "/#{dst_bucket}/dst.txt") |> call()).status == 404

    source_charged =
      alice(:put, "/#{dst_bucket}/dst.txt",
        headers: [
          {"x-amz-copy-source", "/#{src_bucket}/src.txt"},
          {"x-amz-request-payer", "requester"}
        ]
      )
      |> call()

    assert source_charged.status == 200
    assert source_charged.resp_body =~ "CopyObjectResult"
    assert_charged(source_charged)

    assert (SigV4Request.signed_conn(:get, "/#{dst_bucket}/dst.txt") |> call()).resp_body ==
             "copy-source"

    assert put_request_payment(dst_bucket, @requester).status == 200

    dest_missing =
      alice(:put, "/#{dst_bucket}/dst2.txt",
        headers: [{"x-amz-copy-source", "/#{src_bucket}/src.txt"}]
      )
      |> call()

    assert dest_missing.status == 403
    assert dest_missing.resp_body =~ "AccessDenied"

    dest_charged =
      alice(:put, "/#{dst_bucket}/dst2.txt",
        headers: [
          {"x-amz-copy-source", "/#{src_bucket}/src.txt"},
          {"x-amz-request-payer", "requester"}
        ]
      )
      |> call()

    assert dest_charged.status == 200
    assert_charged(dest_charged)
  end

  test "Requester Pays applies across multipart upload lifecycle" do
    bucket = "requestpaympu"

    assert (SigV4Request.signed_conn(:put, "/#{bucket}") |> call()).status == 200
    assert put_request_payment(bucket, @requester).status == 200
    assert :ok = allow_alice_data_plane(bucket)

    denied_create =
      alice(:post, "/#{bucket}/big.bin", query: %{"uploads" => ""})
      |> call()

    assert denied_create.status == 403
    assert denied_create.resp_body =~ "AccessDenied"

    create =
      alice(:post, "/#{bucket}/big.bin",
        query: %{"uploads" => ""},
        headers: [{"x-amz-request-payer", "requester"}]
      )
      |> call()

    assert create.status == 200
    assert_charged(create)
    upload_id = upload_id(create.resp_body)

    denied_part =
      alice(:put, "/#{bucket}/big.bin",
        query: %{"partNumber" => "1", "uploadId" => upload_id},
        body: "multipart-body"
      )
      |> call()

    assert denied_part.status == 403

    part =
      alice(:put, "/#{bucket}/big.bin",
        query: %{"partNumber" => "1", "uploadId" => upload_id},
        body: "multipart-body",
        headers: [{"x-amz-request-payer", "requester"}]
      )
      |> call()

    assert part.status == 200
    assert_charged(part)
    [etag] = get_resp_header(part, "etag")

    denied_list =
      alice(:get, "/#{bucket}/big.bin", query: %{"uploadId" => upload_id})
      |> call()

    assert denied_list.status == 403

    list_parts =
      alice(:get, "/#{bucket}/big.bin",
        query: %{"uploadId" => upload_id},
        headers: [{"x-amz-request-payer", "requester"}]
      )
      |> call()

    assert list_parts.status == 200
    assert_charged(list_parts)

    complete_xml = """
    <CompleteMultipartUpload><Part><PartNumber>1</PartNumber><ETag>#{etag}</ETag></Part></CompleteMultipartUpload>
    """

    denied_complete =
      alice(:post, "/#{bucket}/big.bin",
        query: %{"uploadId" => upload_id},
        body: complete_xml
      )
      |> call()

    assert denied_complete.status == 403

    complete =
      alice(:post, "/#{bucket}/big.bin",
        query: %{"uploadId" => upload_id},
        body: complete_xml,
        headers: [{"x-amz-request-payer", "requester"}]
      )
      |> call()

    assert complete.status == 200
    assert_charged(complete)

    assert (SigV4Request.signed_conn(:get, "/#{bucket}/big.bin") |> call()).resp_body ==
             "multipart-body"
  end

  test "Requester Pays applies to UploadPartCopy source buckets" do
    src_bucket = "requestpaympusrc"
    dst_bucket = "requestpaympudst"

    assert (SigV4Request.signed_conn(:put, "/#{src_bucket}") |> call()).status == 200
    assert (SigV4Request.signed_conn(:put, "/#{dst_bucket}") |> call()).status == 200

    assert (SigV4Request.signed_conn(:put, "/#{src_bucket}/src.txt", body: "part-copy-body")
            |> call()).status == 200

    assert put_request_payment(src_bucket, @requester).status == 200
    assert :ok = allow_alice_data_plane(src_bucket, ["s3:GetObject"])
    assert :ok = allow_alice_data_plane(dst_bucket, ["s3:PutObject"])

    create =
      alice(:post, "/#{dst_bucket}/dst.txt", query: %{"uploads" => ""})
      |> call()

    assert create.status == 200
    upload_id = upload_id(create.resp_body)

    denied =
      alice(:put, "/#{dst_bucket}/dst.txt",
        query: %{"partNumber" => "1", "uploadId" => upload_id},
        headers: [{"x-amz-copy-source", "/#{src_bucket}/src.txt"}]
      )
      |> call()

    assert denied.status == 403
    assert denied.resp_body =~ "AccessDenied"

    copied =
      alice(:put, "/#{dst_bucket}/dst.txt",
        query: %{"partNumber" => "1", "uploadId" => upload_id},
        headers: [
          {"x-amz-copy-source", "/#{src_bucket}/src.txt"},
          {"x-amz-request-payer", "requester"}
        ]
      )
      |> call()

    assert copied.status == 200
    assert copied.resp_body =~ "CopyPartResult"
    assert_charged(copied)
  end

  test "Requester Pays applies to object tagging and ACL subresources" do
    bucket = "requestpaysubres"

    assert (SigV4Request.signed_conn(:put, "/#{bucket}",
              headers: [{"x-amz-object-ownership", "ObjectWriter"}]
            )
            |> call()).status == 200

    assert (SigV4Request.signed_conn(:put, "/#{bucket}/object.txt", body: "subresource")
            |> call()).status == 200

    assert put_request_payment(bucket, @requester).status == 200
    assert :ok = allow_alice_data_plane(bucket)

    tagging_xml =
      "<Tagging><TagSet><Tag><Key>env</Key><Value>prod</Value></Tag></TagSet></Tagging>"

    denied_tagging =
      alice(:put, "/#{bucket}/object.txt", query: %{"tagging" => ""}, body: tagging_xml)
      |> call()

    assert denied_tagging.status == 403

    put_tagging =
      alice(:put, "/#{bucket}/object.txt",
        query: %{"tagging" => ""},
        body: tagging_xml,
        headers: [{"x-amz-request-payer", "requester"}]
      )
      |> call()

    assert put_tagging.status == 200
    assert_charged(put_tagging)

    get_tagging =
      alice(:get, "/#{bucket}/object.txt",
        query: %{"tagging" => ""},
        headers: [{"x-amz-request-payer", "requester"}]
      )
      |> call()

    assert get_tagging.status == 200
    assert get_tagging.resp_body =~ "<Value>prod</Value>"
    assert_charged(get_tagging)

    denied_acl =
      alice(:get, "/#{bucket}/object.txt", query: %{"acl" => ""})
      |> call()

    assert denied_acl.status == 403

    get_acl =
      alice(:get, "/#{bucket}/object.txt",
        query: %{"acl" => ""},
        headers: [{"x-amz-request-payer", "requester"}]
      )
      |> call()

    assert get_acl.status == 200
    assert get_acl.resp_body =~ "AccessControlPolicy"
    assert_charged(get_acl)

    denied_put_acl =
      alice(:put, "/#{bucket}/object.txt",
        query: %{"acl" => ""},
        headers: [{"x-amz-acl", "public-read"}]
      )
      |> call()

    assert denied_put_acl.status == 403
    refute_charged(denied_put_acl)

    invalid_put_acl =
      alice(:put, "/#{bucket}/object.txt",
        query: %{"acl" => ""},
        headers: [
          {"x-amz-acl", "public-read"},
          {"x-amz-request-payer", "owner"}
        ]
      )
      |> call()

    assert invalid_put_acl.status == 403
    refute_charged(invalid_put_acl)

    unsigned_put_acl =
      alice(:put, "/#{bucket}/object.txt",
        query: %{"acl" => ""},
        headers: [{"x-amz-acl", "public-read"}]
      )
      |> put_req_header("x-amz-request-payer", "requester")
      |> call()

    assert unsigned_put_acl.status == 403
    refute_charged(unsigned_put_acl)

    still_private_acl =
      SigV4Request.signed_conn(:get, "/#{bucket}/object.txt", query: %{"acl" => ""})
      |> call()

    assert still_private_acl.status == 200
    refute still_private_acl.resp_body =~ "AllUsers"

    query_put_acl =
      alice(:put, "/#{bucket}/object.txt",
        query: %{"acl" => "", "x-amz-request-payer" => "requester"},
        headers: [{"x-amz-acl", "public-read"}]
      )
      |> call()

    assert query_put_acl.status == 200
    assert_charged(query_put_acl)

    public_acl =
      alice(:get, "/#{bucket}/object.txt",
        query: %{"acl" => ""},
        headers: [{"x-amz-request-payer", "requester"}]
      )
      |> call()

    assert public_acl.status == 200
    assert public_acl.resp_body =~ "AllUsers"
    assert_charged(public_acl)

    owner_put_acl =
      SigV4Request.signed_conn(:put, "/#{bucket}/object.txt",
        query: %{"acl" => ""},
        headers: [{"x-amz-acl", "private"}]
      )
      |> call()

    assert owner_put_acl.status == 200
    refute_charged(owner_put_acl)

    owner_private_acl =
      SigV4Request.signed_conn(:get, "/#{bucket}/object.txt", query: %{"acl" => ""})
      |> call()

    assert owner_private_acl.status == 200
    refute owner_private_acl.resp_body =~ "AllUsers"
  end
end
