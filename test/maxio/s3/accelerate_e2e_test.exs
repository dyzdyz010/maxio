defmodule Maxio.S3.AccelerateE2ETest do
  use Maxio.DataCase, async: false

  import Plug.Conn

  alias Maxio.Auth.CredentialStore
  alias Maxio.BucketConfigs
  alias Maxio.Policy.Store
  alias Maxio.S3.Endpoint
  alias Maxio.Test.SigV4Request

  @data_dir Path.join(System.tmp_dir!(), "maxio_accelerate_e2e")
  @alice_ak "AKIAACCELERATE01"
  @alice_secret "accelerateaccelerate1234"
  @alice_arn "arn:aws:iam:::user/" <> @alice_ak
  @enabled """
  <AccelerateConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
    <Status>Enabled</Status>
  </AccelerateConfiguration>
  """
  @suspended """
  <AccelerateConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
    <Status>Suspended</Status>
  </AccelerateConfiguration>
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

  defp put_accelerate(bucket, body, opts \\ []) do
    SigV4Request.signed_conn(:put, "/#{bucket}",
      query: %{"accelerate" => ""},
      body: body,
      headers: Keyword.get(opts, :headers, [])
    )
    |> call()
  end

  test "GetBucketAccelerateConfiguration returns empty default and Put round-trips Status" do
    assert (SigV4Request.signed_conn(:put, "/accelrt") |> call()).status == 200

    default =
      SigV4Request.signed_conn(:get, "/accelrt", query: %{"accelerate" => ""})
      |> call()

    assert default.status == 200
    assert get_resp_header(default, "content-type") |> hd() =~ "application/xml"
    assert default.resp_body =~ "<AccelerateConfiguration"
    refute default.resp_body =~ "<Status>"
    assert BucketConfigs.get("accelrt", :accelerate) == :none

    put_enabled = put_accelerate("accelrt", @enabled)
    assert put_enabled.status == 200
    assert put_enabled.resp_body == ""
    assert {:ok, %{"Status" => "Enabled"}} = BucketConfigs.get("accelrt", :accelerate)

    enabled =
      SigV4Request.signed_conn(:get, "/accelrt", query: %{"accelerate" => ""})
      |> call()

    assert enabled.status == 200
    assert enabled.resp_body =~ "<Status>Enabled</Status>"

    put_suspended = put_accelerate("accelrt", @suspended)
    assert put_suspended.status == 200
    assert {:ok, %{"Status" => "Suspended"}} = BucketConfigs.get("accelrt", :accelerate)
  end

  test "invalid XML and bad checksum headers fail closed" do
    assert (SigV4Request.signed_conn(:put, "/accelbad") |> call()).status == 200
    assert put_accelerate("accelbad", @enabled).status == 200

    bad_xml = "<AccelerateConfiguration><Status>Disabled</Status></AccelerateConfiguration>"
    bad = put_accelerate("accelbad", bad_xml)

    assert bad.status == 400
    assert bad.resp_body =~ "MalformedXML"
    assert {:ok, %{"Status" => "Enabled"}} = BucketConfigs.get("accelbad", :accelerate)

    bad_checksum =
      put_accelerate("accelbad", @suspended,
        headers: [
          {"x-amz-sdk-checksum-algorithm", "SHA256"},
          {"x-amz-checksum-sha256", :crypto.hash(:sha256, "different") |> Base.encode64()}
        ]
      )

    assert bad_checksum.status == 400
    assert bad_checksum.resp_body =~ "BadDigest"
    assert {:ok, %{"Status" => "Enabled"}} = BucketConfigs.get("accelbad", :accelerate)

    good_checksum =
      put_accelerate("accelbad", @suspended,
        headers: [
          {"x-amz-sdk-checksum-algorithm", "SHA256"},
          {"x-amz-checksum-sha256", content_sha256(@suspended)}
        ]
      )

    assert good_checksum.status == 200
    assert {:ok, %{"Status" => "Suspended"}} = BucketConfigs.get("accelbad", :accelerate)

    bad_checksum_after_config =
      put_accelerate("accelbad", @enabled,
        headers: [
          {"x-amz-sdk-checksum-algorithm", "SHA256"},
          {"x-amz-checksum-sha256", content_sha256("different")}
        ]
      )

    assert bad_checksum_after_config.status == 400
    assert bad_checksum_after_config.resp_body =~ "BadDigest"
    assert {:ok, %{"Status" => "Suspended"}} = BucketConfigs.get("accelbad", :accelerate)
  end

  test "checksum trailers and aws-chunked XML bodies are validated before storing config" do
    assert (SigV4Request.signed_conn(:put, "/acceltrailer") |> call()).status == 200

    plain_trailer =
      put_accelerate("acceltrailer", @enabled,
        headers: [
          {"x-amz-sdk-checksum-algorithm", "SHA256"},
          {"x-amz-trailer", "x-amz-checksum-sha256"}
        ]
      )

    assert plain_trailer.status == 400
    assert plain_trailer.resp_body =~ "InvalidRequest"
    assert BucketConfigs.get("acceltrailer", :accelerate) == :none

    bad =
      SigV4Request.signed_chunked_conn(:put, "/acceltrailer", @enabled,
        query: %{"accelerate" => ""},
        headers: [{"x-amz-sdk-checksum-algorithm", "SHA256"}],
        trailer_headers: [{"x-amz-checksum-sha256", content_sha256("different")}]
      )
      |> call()

    assert bad.status == 400
    assert bad.resp_body =~ "BadDigest"
    assert BucketConfigs.get("acceltrailer", :accelerate) == :none

    ok_trailer =
      SigV4Request.signed_chunked_conn(:put, "/acceltrailer", @enabled,
        query: %{"accelerate" => ""},
        headers: [{"x-amz-sdk-checksum-algorithm", "SHA256"}],
        trailer_headers: [{"x-amz-checksum-sha256", content_sha256(@enabled)}]
      )
      |> call()

    assert ok_trailer.status == 200
    assert {:ok, %{"Status" => "Enabled"}} = BucketConfigs.get("acceltrailer", :accelerate)

    signed_trailer =
      SigV4Request.signed_chunked_conn(:put, "/acceltrailer", @enabled,
        query: %{"accelerate" => ""},
        headers: [{"x-amz-sdk-checksum-algorithm", "SHA256"}],
        trailer_headers: [{"x-amz-checksum-sha256", content_sha256(@enabled)}],
        streaming_payload_hash: "STREAMING-AWS4-HMAC-SHA256-PAYLOAD-TRAILER"
      )
      |> call()

    assert signed_trailer.status == 200

    bad_signed_trailer =
      SigV4Request.signed_chunked_conn(:put, "/acceltrailer", @suspended,
        query: %{"accelerate" => ""},
        headers: [{"x-amz-sdk-checksum-algorithm", "SHA256"}],
        trailer_headers: [{"x-amz-checksum-sha256", content_sha256(@suspended)}],
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
    assert {:ok, %{"Status" => "Enabled"}} = BucketConfigs.get("acceltrailer", :accelerate)

    ok_chunked =
      SigV4Request.signed_chunked_conn(:put, "/acceltrailer", @suspended,
        query: %{"accelerate" => ""}
      )
      |> call()

    assert ok_chunked.status == 200

    assert {:ok, %{"Status" => "Suspended"}} =
             BucketConfigs.get("acceltrailer", :accelerate)

    oversized = String.duplicate("x", 131_073)

    too_large =
      SigV4Request.signed_chunked_conn(:put, "/acceltrailer", oversized,
        query: %{"accelerate" => ""},
        chunk_size: byte_size(oversized),
        decoded_length_override: 131_072
      )
      |> call()

    assert too_large.status == 400
    assert too_large.resp_body =~ "MalformedXML"
    assert too_large.resp_body =~ "AccelerateConfiguration exceeds 128KB"

    assert {:ok, %{"Status" => "Suspended"}} =
             BucketConfigs.get("acceltrailer", :accelerate)
  end

  test "x-amz-expected-bucket-owner is enforced on Get and Put" do
    assert (SigV4Request.signed_conn(:put, "/accelowner") |> call()).status == 200
    assert put_accelerate("accelowner", @enabled).status == 200

    wrong_get =
      SigV4Request.signed_conn(:get, "/accelowner",
        query: %{"accelerate" => ""},
        headers: [{"x-amz-expected-bucket-owner", "999999999999"}]
      )
      |> call()

    assert wrong_get.status == 403
    assert wrong_get.resp_body =~ "AccessDenied"

    wrong_put =
      put_accelerate("accelowner", @suspended,
        headers: [{"x-amz-expected-bucket-owner", "999999999999"}]
      )

    assert wrong_put.status == 403
    assert wrong_put.resp_body =~ "AccessDenied"
    assert {:ok, %{"Status" => "Enabled"}} = BucketConfigs.get("accelowner", :accelerate)

    correct_get =
      SigV4Request.signed_conn(:get, "/accelowner",
        query: %{"accelerate" => ""},
        headers: [{"x-amz-expected-bucket-owner", "000000000000"}]
      )
      |> call()

    assert correct_get.status == 200
  end

  test "dotted bucket and missing bucket fail without storing config" do
    assert (SigV4Request.signed_conn(:put, "/a.b.c") |> call()).status == 200

    dotted = put_accelerate("a.b.c", @enabled)
    assert dotted.status == 400
    assert dotted.resp_body =~ "InvalidRequest"
    assert BucketConfigs.get("a.b.c", :accelerate) == :none

    missing = put_accelerate("missing-accel", @enabled)
    assert missing.status == 404
    assert missing.resp_body =~ "NoSuchBucket"
  end

  test "object-level accelerate subresource and unsupported methods are method not allowed" do
    assert (SigV4Request.signed_conn(:put, "/accelmethod") |> call()).status == 200

    object_get =
      SigV4Request.signed_conn(:get, "/accelmethod/object.txt", query: %{"accelerate" => ""})
      |> call()

    assert object_get.status == 405
    assert object_get.resp_body =~ "MethodNotAllowed"

    delete =
      SigV4Request.signed_conn(:delete, "/accelmethod", query: %{"accelerate" => ""})
      |> call()

    assert delete.status == 405
    assert delete.resp_body =~ "MethodNotAllowed"
  end

  test "Get and Put use distinct IAM actions" do
    assert (SigV4Request.signed_conn(:put, "/accelauthz") |> call()).status == 200

    get_policy =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:GetAccelerateConfiguration","Resource":"arn:aws:s3:::accelauthz"}})

    assert :ok = Store.put_principal_policy(@alice_arn, "get-accelerate-only", get_policy)

    get = alice(:get, "/accelauthz", query: %{"accelerate" => ""}) |> call()
    assert get.status == 200

    denied = alice(:put, "/accelauthz", query: %{"accelerate" => ""}, body: @enabled) |> call()
    assert denied.status == 403
    assert denied.resp_body =~ "AccessDenied"

    put_policy =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:PutAccelerateConfiguration","Resource":"arn:aws:s3:::accelauthz"}})

    assert :ok = Store.put_principal_policy(@alice_arn, "put-accelerate", put_policy)

    allowed = alice(:put, "/accelauthz", query: %{"accelerate" => ""}, body: @enabled) |> call()
    assert allowed.status == 200
    assert {:ok, %{"Status" => "Enabled"}} = BucketConfigs.get("accelauthz", :accelerate)
  end

  test "bucket resource tag condition does not grant accelerate actions" do
    assert (SigV4Request.signed_conn(:put, "/accelnotagcond") |> call()).status == 200

    tag_xml = """
    <Tagging><TagSet><Tag><Key>env</Key><Value>prod</Value></Tag></TagSet></Tagging>
    """

    assert (SigV4Request.signed_conn(:put, "/accelnotagcond",
              query: %{"tagging" => ""},
              body: tag_xml
            )
            |> call()).status == 204

    policy =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:GetAccelerateConfiguration","Resource":"arn:aws:s3:::accelnotagcond","Condition":{"StringEquals":{"aws:ResourceTag/env":"prod"}}}})

    assert :ok = Store.put_principal_policy(@alice_arn, "get-accelerate-resource-tag", policy)

    denied = alice(:get, "/accelnotagcond", query: %{"accelerate" => ""}) |> call()
    assert denied.status == 403
    assert denied.resp_body =~ "AccessDenied"
  end

  defp content_sha256(body), do: :crypto.hash(:sha256, body) |> Base.encode64()
end
