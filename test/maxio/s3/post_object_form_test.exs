defmodule Maxio.S3.PostObjectFormTest do
  use Maxio.DataCase, async: false

  import Plug.Conn

  alias Maxio.Auth.CredentialStore.MemoryStore
  alias Maxio.Auth.SigV4.{PostPolicy, Signer}
  alias Maxio.Objects
  alias Maxio.Policy.Store
  alias Maxio.S3.Endpoint
  alias Maxio.Test.SigV4Request

  @access_key "AKIAIOSFODNN7EXAMPLE"
  @secret "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
  @alice_ak "AKIAPOSTFORMPAYER01"
  @alice_secret "postformpayersecret12345"
  @alice_arn "arn:aws:iam:::user/" <> @alice_ak
  @region "us-east-1"
  @service "s3"
  @algorithm "AWS4-HMAC-SHA256"
  @data_dir Path.join(System.tmp_dir!(), "maxio_post_object_form_test")
  @requester """
  <RequestPaymentConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
    <Payer>Requester</Payer>
  </RequestPaymentConfiguration>
  """

  setup do
    %{user_arn: @alice_arn} =
      create_user_with_access_key!(
        user_name: @alice_ak,
        access_key_id: @alice_ak,
        secret_key: @alice_secret
      )

    MemoryStore.invalidate(:all)
    File.rm_rf(@data_dir)
    File.mkdir_p!(@data_dir)

    prev = Application.get_env(:maxio, :s3)
    Application.put_env(:maxio, :s3, Keyword.put(prev, :data_dir, @data_dir))

    on_exit(fn ->
      Application.put_env(:maxio, :s3, prev)
      MemoryStore.invalidate(:all)
      File.rm_rf(@data_dir)
    end)

    :ok
  end

  defp call(conn), do: Endpoint.call(conn, Endpoint.init([]))

  test "signed POST form writes object through shared PutObject path" do
    bucket = "postformwrite"
    create_bucket!(bucket)

    body = "hello from post"
    content_md5 = md5_b64(body)

    fields =
      signed_fields(bucket, "uploads/${filename}",
        conditions: [
          ["starts-with", "$key", "uploads/"],
          %{"Content-MD5" => content_md5},
          %{"Content-Type" => "text/plain"},
          %{"x-amz-meta-origin" => "post-form"},
          ["content-length-range", 1, 100]
        ],
        fields: %{
          "Content-MD5" => content_md5,
          "Content-Type" => "text/plain",
          "x-amz-meta-origin" => "post-form"
        }
      )

    post = post_form(bucket, fields, body, filename: "greeting.txt") |> call()

    assert post.status == 204
    assert get_resp_header(post, "etag") != []

    get = SigV4Request.signed_conn(:get, "/#{bucket}/uploads/greeting.txt") |> call()
    assert get.status == 200
    assert get.resp_body == body
    assert get_resp_header(get, "content-type") == ["text/plain"]
    assert get_resp_header(get, "x-amz-meta-origin") == ["post-form"]
  end

  test "signed POST form enforces Requester Pays with a signed payer field" do
    bucket = "postformrequester"
    key = "forms/requester.txt"
    create_bucket!(bucket)
    assert put_request_payment(bucket).status == 200
    allow_alice_put_object(bucket)

    :ok =
      MemoryStore.put_access_key(%{
        access_key: @alice_ak,
        secret_key: @alice_secret,
        principal: %{type: :iam_user, access_key: @alice_ak, arn: @alice_arn}
      })

    missing_payer_fields =
      signed_fields(bucket, key,
        access_key: @alice_ak,
        secret: @alice_secret,
        conditions: [["eq", "$key", key]]
      )

    missing = post_form(bucket, missing_payer_fields, "missing payer") |> call()

    assert missing.status == 403
    assert missing.resp_body =~ "<Code>AccessDenied</Code>"
    assert_missing(bucket, key)

    payer_fields =
      signed_fields(bucket, key,
        access_key: @alice_ak,
        secret: @alice_secret,
        fields: %{"x-amz-request-payer" => "requester"},
        conditions: [
          ["eq", "$key", key],
          %{"x-amz-request-payer" => "requester"}
        ]
      )

    paid = post_form(bucket, payer_fields, "paid by requester") |> call()

    assert paid.status == 204
    assert get_resp_header(paid, "x-amz-request-charged") == ["requester"]

    get = SigV4Request.signed_conn(:get, "/#{bucket}/#{key}") |> call()
    assert get.status == 200
    assert get.resp_body == "paid by requester"
  end

  test "signed POST form obeys BucketOwnerEnforced object ACL rules" do
    bucket = "postformboeacl"
    rejected_key = "forms/public.txt"
    allowed_key = "forms/owner-full-control.txt"
    create_bucket!(bucket)

    public_fields =
      signed_fields(bucket, rejected_key,
        fields: %{"acl" => "public-read"},
        conditions: [
          ["eq", "$key", rejected_key],
          %{"acl" => "public-read"}
        ]
      )

    rejected = post_form(bucket, public_fields, "public acl") |> call()

    assert rejected.status == 400
    assert rejected.resp_body =~ "<Code>AccessControlListNotSupported</Code>"
    assert_missing(bucket, rejected_key)

    owner_full_control_fields =
      signed_fields(bucket, allowed_key,
        fields: %{"acl" => "bucket-owner-full-control"},
        conditions: [
          ["eq", "$key", allowed_key],
          %{"acl" => "bucket-owner-full-control"}
        ]
      )

    allowed = post_form(bucket, owner_full_control_fields, "owner acl") |> call()

    assert allowed.status == 204

    get = SigV4Request.signed_conn(:get, "/#{bucket}/#{allowed_key}") |> call()
    assert get.status == 200
    assert get.resp_body == "owner acl"
  end

  test "signed POST form validates Content-MD5 before committing object" do
    bucket = "postformcontentmd5"
    key = "bad/md5.txt"
    bad_md5 = md5_b64("different bytes")
    create_bucket!(bucket)

    fields =
      signed_fields(bucket, key,
        conditions: [
          ["eq", "$key", key],
          %{"Content-MD5" => bad_md5},
          ["content-length-range", 1, 100]
        ],
        fields: %{"Content-MD5" => bad_md5}
      )

    post = post_form(bucket, fields, "real body") |> call()

    assert post.status == 400
    assert post.resp_body =~ "BadDigest"
    assert_missing(bucket, key)
  end

  test "signed POST form over bucket hard quota fails closed" do
    bucket = "postformquota"
    key = "forms/too-large.txt"
    create_bucket!(bucket)
    assert :ok = Maxio.BucketQuota.put_hard(bucket, 3)

    fields =
      signed_fields(bucket, key,
        conditions: [
          ["eq", "$key", key],
          ["content-length-range", 1, 10]
        ]
      )

    post = post_form(bucket, fields, "1234") |> call()

    assert post.status == 400
    assert post.resp_body =~ "XMinioAdminBucketQuotaExceeded"
    assert_missing(bucket, key)
  end

  test "success_action_status 201 returns PostResponse XML" do
    bucket = "postform201"
    key = "forms/ok.txt"
    create_bucket!(bucket)

    fields =
      signed_fields(bucket, key,
        conditions: [
          ["eq", "$key", key],
          %{"success_action_status" => "201"},
          ["content-length-range", 1, 32]
        ],
        fields: %{"success_action_status" => "201"}
      )

    post = post_form(bucket, fields, "created", filename: "ignored.txt") |> call()

    assert post.status == 201
    assert get_resp_header(post, "content-type") == ["application/xml; charset=utf-8"]
    assert post.resp_body =~ "<PostResponse"
    assert post.resp_body =~ "<Bucket>#{bucket}</Bucket>"
    assert post.resp_body =~ "<Key>#{key}</Key>"
    assert post.resp_body =~ "<ETag>\""

    get = SigV4Request.signed_conn(:get, "/#{bucket}/#{key}") |> call()
    assert get.status == 200
    assert get.resp_body == "created"
  end

  test "legacy redirect field returns 303 with S3 query before URL fragment" do
    bucket = "postformredirect"
    key = "forms/redirect.txt"
    redirect = "https://console.example.test/upload-complete?state=1#done"
    create_bucket!(bucket)

    fields =
      signed_fields(bucket, key,
        conditions: [
          ["eq", "$key", key],
          %{"redirect" => redirect},
          ["content-length-range", 1, 32]
        ],
        fields: %{"redirect" => redirect}
      )

    post = post_form(bucket, fields, "redirected", filename: "ignored.txt") |> call()

    assert post.status == 303
    assert post.resp_body == ""
    [location] = get_resp_header(post, "location")

    uri = URI.parse(location)
    query = URI.decode_query(uri.query)

    assert uri.scheme == "https"
    assert uri.host == "console.example.test"
    assert uri.path == "/upload-complete"
    assert uri.fragment == "done"
    assert query["state"] == "1"
    assert query["bucket"] == bucket
    assert query["key"] == key
    assert query["etag"] =~ ~r/^".+"$/

    get = SigV4Request.signed_conn(:get, "/#{bucket}/#{key}") |> call()
    assert get.status == 200
    assert get.resp_body == "redirected"
  end

  test "PostPolicy builder output is accepted by POST Object endpoint" do
    bucket = "postpolicybuilder"
    key = "forms/builder.txt"
    create_bucket!(bucket)

    assert {:ok, form} =
             PostPolicy.build_form(
               "http://localhost:9900",
               bucket,
               key,
               %{access_key: @access_key, secret_key: @secret},
               region: @region,
               max_size: 64,
               success_action_status: "201"
             )

    post = post_form(bucket, Map.new(form.fields), "built by policy") |> call()

    assert post.status == 201
    assert post.resp_body =~ "<PostResponse"
    assert post.resp_body =~ "<Key>#{key}</Key>"

    get = SigV4Request.signed_conn(:get, "/#{bucket}/#{key}") |> call()
    assert get.status == 200
    assert get.resp_body == "built by policy"
  end

  test "POST Object accepts AWS-style case-insensitive auth and control field names" do
    bucket = "postpolicybuildercase"
    key = "forms/aws-case.txt"
    create_bucket!(bucket)

    assert {:ok, form} =
             PostPolicy.build_form(
               "http://localhost:9900",
               bucket,
               key,
               %{access_key: @access_key, secret_key: @secret},
               region: @region,
               max_size: 64,
               success_action_status: "201",
               fields: [{"Content-Type", "text/plain"}]
             )

    fields =
      form.fields
      |> Map.new()
      |> aws_style_post_fields()

    post =
      post_form(bucket, fields, "aws case body",
        file_field_name: "File",
        filename: "ignored.txt"
      )
      |> call()

    assert post.status == 201

    get = SigV4Request.signed_conn(:get, "/#{bucket}/#{key}") |> call()
    assert get.status == 200
    assert get.resp_body == "aws case body"
    assert get_resp_header(get, "content-type") == ["text/plain"]
  end

  test "PostPolicy builder SSE-C output encrypts object and exact-signs customer key fields" do
    bucket = "postpolicybuilderssec"
    key = "forms/customer-encrypted.txt"
    body = "post policy sse-c body"
    customer_key = :binary.copy(<<5>>, 32)
    key_md5_b64 = :crypto.hash(:md5, customer_key) |> Base.encode64()
    create_bucket!(bucket)

    assert {:ok, form} =
             PostPolicy.build_form(
               "http://localhost:9900",
               bucket,
               key,
               %{access_key: @access_key, secret_key: @secret},
               region: @region,
               max_size: 64,
               success_action_status: "201",
               fields: sse_c_fields(customer_key)
             )

    fields = Map.new(form.fields)
    policy = fields["policy"] |> Base.decode64!() |> Jason.decode!()

    assert %{"x-amz-server-side-encryption-customer-key-md5" => key_md5_b64} in policy[
             "conditions"
           ]

    post = post_form(bucket, fields, body) |> call()

    assert post.status == 201

    assert get_resp_header(post, "x-amz-server-side-encryption-customer-algorithm") == [
             "AES256"
           ]

    assert get_resp_header(post, "x-amz-server-side-encryption-customer-key-md5") == [
             key_md5_b64
           ]

    assert {:ok, object} = Objects.get_metadata(bucket, key)
    assert object.sse_algorithm == "SSE-C"
    refute inspect(object.sse_envelope) =~ Base.encode64(customer_key)

    missing_key = SigV4Request.signed_conn(:get, "/#{bucket}/#{key}") |> call()
    assert missing_key.status == 400

    wrong_key =
      SigV4Request.signed_conn(:get, "/#{bucket}/#{key}",
        headers: sse_c_headers(:binary.copy(<<6>>, 32))
      )
      |> call()

    assert wrong_key.status == 400

    get =
      SigV4Request.signed_conn(:get, "/#{bucket}/#{key}", headers: sse_c_headers(customer_key))
      |> call()

    assert get.status == 200
    assert get.resp_body == body

    tampered_fields =
      fields
      |> Map.put(
        "x-amz-server-side-encryption-customer-key",
        Base.encode64(:binary.copy(<<7>>, 32))
      )

    tampered = post_form(bucket, tampered_fields, "tampered") |> call()
    assert tampered.status == 403
  end

  test "PostPolicy builder prefix form expands filename and constrains key prefix" do
    bucket = "postpolicybuilderprefix"
    create_bucket!(bucket)

    assert {:ok, form} =
             PostPolicy.build_form(
               "http://localhost:9900",
               bucket,
               {:starts_with, "docs/", "docs/${filename}"},
               %{access_key: @access_key, secret_key: @secret},
               region: @region,
               max_size: 32,
               success_action_status: "201"
             )

    post =
      post_form(bucket, Map.new(form.fields), "prefix body", filename: "upload.txt") |> call()

    assert post.status == 201
    assert post.resp_body =~ "<Key>docs/upload.txt</Key>"

    get = SigV4Request.signed_conn(:get, "/#{bucket}/docs/upload.txt") |> call()
    assert get.status == 200
    assert get.resp_body == "prefix body"

    tampered_fields =
      form.fields
      |> Map.new()
      |> Map.put("key", "outside/${filename}")

    post = post_form(bucket, tampered_fields, "bad", filename: "escape.txt") |> call()

    assert post.status == 403
    assert post.resp_body =~ "AccessDenied"
    assert_missing(bucket, "outside/escape.txt")
  end

  test "PostPolicy builder rejects tampered signed extra fields" do
    bucket = "postpolicybuildertamper"
    key = "forms/tampered-extra-field.txt"
    body = "tampered advanced body"
    checksum = sha256_b64(body)
    content_md5 = md5_b64(body)
    tagging = ~s(<Tagging><TagSet><Tag><Key>env</Key><Value>prod</Value></Tag></TagSet></Tagging>)
    kms_context = Base.encode64(~s({"purpose":"post-policy-tamper"}))
    create_bucket!(bucket)

    assert {:ok, form} =
             PostPolicy.build_form(
               "http://localhost:9900",
               bucket,
               key,
               %{access_key: @access_key, secret_key: @secret},
               region: @region,
               max_size: 64,
               success_action_status: "201",
               fields: [
                 {"acl", "private"},
                 {"Content-MD5", content_md5},
                 {"Content-Type", "text/plain"},
                 {"x-amz-meta-origin", "console"},
                 {"tagging", tagging},
                 {"x-amz-server-side-encryption", "aws:kms"},
                 {"x-amz-server-side-encryption-context", kms_context},
                 {"x-amz-server-side-encryption-bucket-key-enabled", "true"},
                 {"x-amz-request-payer", "requester"},
                 {"x-amz-sdk-checksum-algorithm", "SHA256"},
                 {"x-amz-checksum-sha256", checksum},
                 {"success_action_redirect", "https://console.example.test/done"}
               ]
             )

    tampered_cases = [
      {"acl", "public-read"},
      {"Content-MD5", md5_b64("other body")},
      {"Content-Type", "application/json"},
      {"x-amz-meta-origin", "browser"},
      {
        "tagging",
        ~s(<Tagging><TagSet><Tag><Key>env</Key><Value>dev</Value></Tag></TagSet></Tagging>)
      },
      {"x-amz-server-side-encryption", "AES256"},
      {"x-amz-server-side-encryption-context", Base.encode64(~s({"purpose":"tampered"}))},
      {"x-amz-server-side-encryption-bucket-key-enabled", "false"},
      {"x-amz-request-payer", "owner"},
      {"x-amz-sdk-checksum-algorithm", "SHA1"},
      {"x-amz-checksum-sha256", sha256_b64("other body")},
      {"success_action_redirect", "https://user:pass@console.example.test/done"}
    ]

    for {field, value} <- tampered_cases do
      tampered_fields =
        form.fields
        |> Map.new()
        |> Map.put(field, value)

      post = post_form(bucket, tampered_fields, body) |> call()

      assert post.status == 403
      assert post.resp_body =~ "AccessDenied"
      assert_missing(bucket, key)
    end
  end

  test "PostPolicy builder content-length-range fails closed" do
    bucket = "postpolicybuildersize"
    key = "forms/too-large.txt"
    create_bucket!(bucket)

    assert {:ok, form} =
             PostPolicy.build_form(
               "http://localhost:9900",
               bucket,
               key,
               %{access_key: @access_key, secret_key: @secret},
               region: @region,
               max_size: 3,
               success_action_status: "201"
             )

    post = post_form(bucket, Map.new(form.fields), "toolong") |> call()

    assert post.status == 400
    assert post.resp_body =~ "EntityTooLarge"
    assert_missing(bucket, key)
  end

  test "bad POST policy signature fails closed and leaves no object" do
    bucket = "postformsigbad"
    key = "bad/sig.txt"
    create_bucket!(bucket)

    fields =
      signed_fields(bucket, key, conditions: [["eq", "$key", key]])
      |> Map.put("x-amz-signature", String.duplicate("0", 64))

    post = post_form(bucket, fields, "nope") |> call()

    assert post.status == 403
    assert post.resp_body =~ "SignatureDoesNotMatch"
    assert_missing(bucket, key)
  end

  test "form fields not covered by policy conditions are rejected" do
    bucket = "postformcoverage"
    key = "bad/coverage.txt"
    create_bucket!(bucket)

    fields =
      signed_fields(bucket, key, conditions: [["eq", "$key", key]])
      |> Map.put("x-amz-meta-uncovered", "bad")

    post = post_form(bucket, fields, "nope") |> call()

    assert post.status == 403
    assert post.resp_body =~ "AccessDenied"
    assert_missing(bucket, key)
  end

  test "content-length-range is enforced while streaming file bytes" do
    bucket = "postformrange"
    key = "limits/too-large.txt"
    create_bucket!(bucket)

    fields =
      signed_fields(bucket, key,
        conditions: [["eq", "$key", key], ["content-length-range", 1, 3]]
      )

    post = post_form(bucket, fields, "toolong") |> call()

    assert post.status == 400
    assert post.resp_body =~ "EntityTooLarge"
    assert_missing(bucket, key)
  end

  test "file part must be last" do
    bucket = "postformfilelast"
    key = "bad/file-last.txt"
    create_bucket!(bucket)

    fields = signed_fields(bucket, key, conditions: [["eq", "$key", key]])

    post =
      post_form(bucket, fields, "body", trailing_fields: [{"x-ignore-after", "no"}]) |> call()

    assert post.status == 400
    assert post.resp_body =~ "MalformedPOSTRequest"
    assert_missing(bucket, key)
  end

  test "many empty non-file fields are rejected by cumulative form budget" do
    bucket = "postformfieldcount"
    key = "bad/too-many-fields.txt"
    create_bucket!(bucket)

    ignored_fields =
      1..130
      |> Map.new(fn index -> {"x-ignore-#{index}", ""} end)

    fields =
      signed_fields(bucket, key, conditions: [["eq", "$key", key]])
      |> Map.merge(ignored_fields)

    post = post_form(bucket, fields, "body") |> call()

    assert post.status == 400
    assert post.resp_body =~ "MalformedPOSTRequest"
    assert_missing(bucket, key)
  end

  test "POST policy authentication still goes through IAM authorization" do
    bucket = "postformauthz"
    key = "alice/denied.txt"
    create_bucket!(bucket)

    access_key = "AKIAPOSTFORMALICE"
    secret = "alice-post-secret"

    :ok =
      MemoryStore.put_access_key(%{
        access_key: access_key,
        secret_key: secret,
        principal: %{
          type: :iam_user,
          access_key: access_key,
          arn: "arn:aws:iam:::user/post-form-alice"
        }
      })

    fields =
      signed_fields(bucket, key,
        access_key: access_key,
        secret: secret,
        conditions: [["eq", "$key", key]]
      )

    post = post_form(bucket, fields, "denied") |> call()

    assert post.status == 403
    assert post.resp_body =~ "AccessDenied"
    assert_missing(bucket, key)
  end

  defp create_bucket!(bucket) do
    conn = SigV4Request.signed_conn(:put, "/#{bucket}") |> call()
    assert conn.status == 200
  end

  defp put_request_payment(bucket) do
    SigV4Request.signed_conn(:put, "/#{bucket}",
      query: %{"requestPayment" => ""},
      body: @requester,
      headers: [{"content-md5", md5_b64(@requester)}]
    )
    |> call()
  end

  defp allow_alice_put_object(bucket) do
    policy =
      Jason.encode!(%{
        "Version" => "2012-10-17",
        "Statement" => [
          %{
            "Effect" => "Allow",
            "Action" => "s3:PutObject",
            "Resource" => "arn:aws:s3:::#{bucket}/*"
          }
        ]
      })

    assert :ok = Store.put_principal_policy(@alice_arn, "post-form-put-#{bucket}", policy)
  end

  defp assert_missing(bucket, key) do
    get = SigV4Request.signed_conn(:get, "/#{bucket}/#{key}") |> call()
    assert get.status == 404
    assert get.resp_body =~ "NoSuchKey"
  end

  defp sha256_b64(body), do: :crypto.hash(:sha256, body) |> Base.encode64()
  defp md5_b64(body), do: :crypto.hash(:md5, body) |> Base.encode64()

  defp sse_c_fields(customer_key) do
    [
      {"x-amz-server-side-encryption-customer-algorithm", "AES256"},
      {"x-amz-server-side-encryption-customer-key", Base.encode64(customer_key)},
      {"x-amz-server-side-encryption-customer-key-md5",
       :crypto.hash(:md5, customer_key) |> Base.encode64()}
    ]
  end

  defp sse_c_headers(customer_key), do: sse_c_fields(customer_key)

  defp aws_style_post_fields(fields) do
    Map.new(fields, fn
      {"key", value} -> {"Key", value}
      {"policy", value} -> {"Policy", value}
      {"x-amz-algorithm", value} -> {"X-Amz-Algorithm", value}
      {"x-amz-credential", value} -> {"X-Amz-Credential", value}
      {"x-amz-date", value} -> {"X-Amz-Date", value}
      {"x-amz-security-token", value} -> {"X-Amz-Security-Token", value}
      {"x-amz-signature", value} -> {"X-Amz-Signature", value}
      {name, value} -> {name, value}
    end)
  end

  defp signed_fields(bucket, key, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    access_key = Keyword.get(opts, :access_key, @access_key)
    secret = Keyword.get(opts, :secret, @secret)
    extra_fields = Keyword.get(opts, :fields, %{})
    extra_conditions = Keyword.get(opts, :conditions, [])

    amz_date = Calendar.strftime(now, "%Y%m%dT%H%M%SZ")
    scope_date = Calendar.strftime(now, "%Y%m%d")
    credential = "#{access_key}/#{scope_date}/#{@region}/#{@service}/aws4_request"

    base_fields = %{
      "key" => key,
      "x-amz-algorithm" => @algorithm,
      "x-amz-credential" => credential,
      "x-amz-date" => amz_date
    }

    fields = Map.merge(base_fields, extra_fields)

    conditions =
      [
        %{"bucket" => bucket},
        %{"x-amz-algorithm" => @algorithm},
        %{"x-amz-credential" => credential},
        %{"x-amz-date" => amz_date}
      ] ++ extra_conditions

    policy =
      %{
        "expiration" => now |> DateTime.add(3600, :second) |> DateTime.to_iso8601(),
        "conditions" => conditions
      }

    policy_b64 = policy |> Jason.encode!() |> Base.encode64()
    signing_key = Signer.derive_signing_key(secret, scope_date, @region, @service)
    signature = Signer.signature(signing_key, policy_b64)

    fields
    |> Map.put("policy", policy_b64)
    |> Map.put("x-amz-signature", signature)
  end

  defp post_form(bucket, fields, file_body, opts \\ []) do
    filename = Keyword.get(opts, :filename, "upload.txt")
    file_field_name = Keyword.get(opts, :file_field_name, "file")
    trailing_fields = Keyword.get(opts, :trailing_fields, [])
    boundary = "----maxio-post-#{System.unique_integer([:positive])}"
    body = multipart_body(boundary, fields, file_body, filename, file_field_name, trailing_fields)

    SigV4Request.anon_conn(:post, "/#{bucket}",
      body: body,
      headers: [
        {"content-type", "multipart/form-data; boundary=#{boundary}"},
        {"content-length", Integer.to_string(byte_size(body))}
      ]
    )
  end

  defp multipart_body(boundary, fields, file_body, filename, file_field_name, trailing_fields) do
    leading =
      fields
      |> Enum.map(fn {name, value} ->
        [
          "--",
          boundary,
          "\r\ncontent-disposition: form-data; name=\"",
          name,
          "\"\r\n\r\n",
          value,
          "\r\n"
        ]
      end)

    file_part = [
      "--",
      boundary,
      "\r\ncontent-disposition: form-data; name=\"",
      file_field_name,
      "\"; filename=\"",
      filename,
      "\"\r\ncontent-type: application/octet-stream\r\n\r\n",
      file_body,
      "\r\n"
    ]

    trailing =
      trailing_fields
      |> Enum.map(fn {name, value} ->
        [
          "--",
          boundary,
          "\r\ncontent-disposition: form-data; name=\"",
          name,
          "\"\r\n\r\n",
          value,
          "\r\n"
        ]
      end)

    closing = ["--", boundary, "--\r\n"]

    IO.iodata_to_binary([leading, file_part, trailing, closing])
  end
end
