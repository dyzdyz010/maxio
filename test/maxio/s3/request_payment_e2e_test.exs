defmodule Maxio.S3.RequestPaymentE2ETest do
  use Maxio.DataCase, async: false

  import Plug.Conn

  alias Maxio.Auth.CredentialStore
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

  defp put_request_payment(bucket, body, opts \\ []) do
    SigV4Request.signed_conn(:put, "/#{bucket}",
      query: %{"requestPayment" => ""},
      body: body,
      headers: [{"content-md5", content_md5(body)}] ++ Keyword.get(opts, :headers, [])
    )
    |> call()
  end

  defp content_md5(body), do: :crypto.hash(:md5, body) |> Base.encode64()

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
end
