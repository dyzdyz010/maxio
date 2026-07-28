defmodule Maxio.Auth.SigV4.PostPolicyTest do
  use ExUnit.Case, async: true

  alias Maxio.Auth.SigV4.PostPolicy

  @access_key "AKIAIOSFODNN7EXAMPLE"
  @secret "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
  @now ~U[2013-05-24 00:00:00Z]

  test "builds signed POST Object policy form fields" do
    assert {:ok, form} =
             PostPolicy.build_form(
               "http://localhost:9900",
               "bucket",
               "path/object.txt",
               credentials(),
               now: @now,
               region: "us-east-1",
               expires: 600,
               max_size: 1024,
               success_action_status: "201"
             )

    fields = Map.new(form.fields)
    policy = fields["policy"] |> Base.decode64!() |> Jason.decode!()

    assert form.url == "http://localhost:9900/bucket"
    assert fields["key"] == "path/object.txt"
    assert fields["x-amz-algorithm"] == "AWS4-HMAC-SHA256"
    assert fields["x-amz-credential"] == "#{@access_key}/20130524/us-east-1/s3/aws4_request"
    assert fields["x-amz-date"] == "20130524T000000Z"
    assert fields["success_action_status"] == "201"
    assert fields["x-amz-signature"] == form.signature
    assert byte_size(fields["x-amz-signature"]) == 64
    refute Map.has_key?(fields, "x-amz-security-token")

    assert policy["expiration"] == "2013-05-24T00:10:00Z"
    assert %{"bucket" => "bucket"} in policy["conditions"]
    assert %{"key" => "path/object.txt"} in policy["conditions"]
    assert ["content-length-range", 0, 1024] in policy["conditions"]
    assert %{"success_action_status" => "201"} in policy["conditions"]
  end

  test "includes session token as both field and exact policy condition" do
    assert {:ok, form} =
             PostPolicy.build_form(
               "https://s3.example.test",
               "bucket",
               "object.txt",
               Map.put(credentials(), :session_token, "token-123"),
               now: @now,
               region: "us-east-1"
             )

    fields = Map.new(form.fields)
    policy = fields["policy"] |> Base.decode64!() |> Jason.decode!()

    assert fields["x-amz-security-token"] == "token-123"
    assert %{"x-amz-security-token" => "token-123"} in policy["conditions"]
  end

  test "builds starts-with key policy for filename expansion forms" do
    assert {:ok, form} =
             PostPolicy.build_form(
               "https://s3.example.test",
               "bucket",
               {:starts_with, "docs/", "docs/${filename}"},
               credentials(),
               now: @now,
               region: "us-east-1",
               max_size: 512
             )

    fields = Map.new(form.fields)
    policy = fields["policy"] |> Base.decode64!() |> Jason.decode!()

    assert fields["key"] == "docs/${filename}"
    assert ["starts-with", "$key", "docs/"] in policy["conditions"]
    refute %{"key" => "docs/${filename}"} in policy["conditions"]
    assert ["content-length-range", 0, 512] in policy["conditions"]
  end

  test "signs additional exact POST form fields" do
    tagging = ~s(<Tagging><TagSet><Tag><Key>env</Key><Value>prod</Value></Tag></TagSet></Tagging>)
    content_md5 = :crypto.hash(:md5, "payload") |> Base.encode64()
    kms_context = Base.encode64(~s({"purpose":"console-post"}))

    assert {:ok, form} =
             PostPolicy.build_form(
               "https://s3.example.test",
               "bucket",
               "object.txt",
               credentials(),
               now: @now,
               region: "us-east-1",
               fields: [
                 {"acl", "bucket-owner-full-control"},
                 {"Content-MD5", content_md5},
                 {"Content-Type", "text/plain"},
                 {"x-amz-meta-origin", "console"},
                 {"tagging", tagging},
                 {"x-amz-server-side-encryption", "aws:kms"},
                 {"x-amz-server-side-encryption-context", kms_context},
                 {"x-amz-server-side-encryption-bucket-key-enabled", "true"},
                 {"x-amz-request-payer", "requester"}
               ]
             )

    fields = Map.new(form.fields)
    policy = fields["policy"] |> Base.decode64!() |> Jason.decode!()

    assert fields["acl"] == "bucket-owner-full-control"
    assert fields["Content-MD5"] == content_md5
    assert fields["Content-Type"] == "text/plain"
    assert fields["x-amz-meta-origin"] == "console"
    assert fields["tagging"] == tagging
    assert fields["x-amz-server-side-encryption"] == "aws:kms"
    assert fields["x-amz-server-side-encryption-context"] == kms_context
    assert fields["x-amz-server-side-encryption-bucket-key-enabled"] == "true"
    assert fields["x-amz-request-payer"] == "requester"
    assert %{"acl" => "bucket-owner-full-control"} in policy["conditions"]
    assert %{"Content-MD5" => content_md5} in policy["conditions"]
    assert %{"Content-Type" => "text/plain"} in policy["conditions"]
    assert %{"x-amz-meta-origin" => "console"} in policy["conditions"]
    assert %{"tagging" => tagging} in policy["conditions"]
    assert %{"x-amz-server-side-encryption" => "aws:kms"} in policy["conditions"]
    assert %{"x-amz-server-side-encryption-context" => kms_context} in policy["conditions"]
    assert %{"x-amz-server-side-encryption-bucket-key-enabled" => "true"} in policy["conditions"]
    assert %{"x-amz-request-payer" => "requester"} in policy["conditions"]
  end

  test "signs SSE-C and raw x-amz POST form fields exactly" do
    customer_key = :binary.copy(<<3>>, 32)
    customer_key_b64 = Base.encode64(customer_key)
    key_md5_b64 = :crypto.hash(:md5, customer_key) |> Base.encode64()

    assert {:ok, form} =
             PostPolicy.build_form(
               "https://s3.example.test",
               "bucket",
               "object.txt",
               credentials(),
               now: @now,
               region: "us-east-1",
               fields: [
                 {"x-amz-server-side-encryption-customer-algorithm", "AES256"},
                 {"x-amz-server-side-encryption-customer-key", customer_key_b64},
                 {"x-amz-server-side-encryption-customer-key-md5", key_md5_b64},
                 {"x-amz-storage-class", "STANDARD_IA"},
                 {"x-amz-website-redirect-location", "/landing.html"}
               ]
             )

    fields = Map.new(form.fields)
    policy = fields["policy"] |> Base.decode64!() |> Jason.decode!()

    assert fields["x-amz-server-side-encryption-customer-algorithm"] == "AES256"
    assert fields["x-amz-server-side-encryption-customer-key"] == customer_key_b64
    assert fields["x-amz-server-side-encryption-customer-key-md5"] == key_md5_b64
    assert fields["x-amz-storage-class"] == "STANDARD_IA"
    assert fields["x-amz-website-redirect-location"] == "/landing.html"

    assert %{"x-amz-server-side-encryption-customer-algorithm" => "AES256"} in policy[
             "conditions"
           ]

    assert %{"x-amz-server-side-encryption-customer-key" => customer_key_b64} in policy[
             "conditions"
           ]

    assert %{"x-amz-server-side-encryption-customer-key-md5" => key_md5_b64} in policy[
             "conditions"
           ]

    assert %{"x-amz-storage-class" => "STANDARD_IA"} in policy["conditions"]
    assert %{"x-amz-website-redirect-location" => "/landing.html"} in policy["conditions"]
  end

  test "rejects invalid public url, expiration, max size, and success status" do
    assert {:error, :invalid_base_url} =
             PostPolicy.build_form("http://localhost:9900/proxy", "bucket", "key", credentials())

    assert {:error, :invalid_base_url} =
             PostPolicy.build_form(
               "https://user:pass@s3.example.test",
               "bucket",
               "key",
               credentials()
             )

    assert {:error, :invalid_expires} =
             PostPolicy.build_form("http://localhost:9900", "bucket", "key", credentials(),
               expires: 0
             )

    assert {:error, :invalid_max_size} =
             PostPolicy.build_form("http://localhost:9900", "bucket", "key", credentials(),
               max_size: 0
             )

    assert {:error, :invalid_success_action_status} =
             PostPolicy.build_form("http://localhost:9900", "bucket", "key", credentials(),
               success_action_status: "303"
             )

    assert {:error, :invalid_bucket_key} =
             PostPolicy.build_form(
               "http://localhost:9900",
               "bucket",
               "docs/${filename}",
               credentials()
             )

    assert {:error, :invalid_bucket_key} =
             PostPolicy.build_form(
               "http://localhost:9900",
               "bucket",
               {:starts_with, "docs/", "other/${filename}"},
               credentials()
             )

    assert {:error, :invalid_field} =
             PostPolicy.build_form("http://localhost:9900", "bucket", "key", credentials(),
               fields: [{"key", "override"}]
             )

    assert {:error, :invalid_field} =
             PostPolicy.build_form("http://localhost:9900", "bucket", "key", credentials(),
               fields: [{"acl", "public-read\r\nx-bad: 1"}]
             )

    assert {:error, :invalid_field} =
             PostPolicy.build_form("http://localhost:9900", "bucket", "key", credentials(),
               fields: [{"x-amz-meta-bad\0name", "value"}]
             )

    assert {:error, :invalid_field} =
             PostPolicy.build_form("http://localhost:9900", "bucket", "key", credentials(),
               fields: [{"x-amz-meta-name", "value\0"}]
             )
  end

  defp credentials, do: %{access_key: @access_key, secret_key: @secret}
end
