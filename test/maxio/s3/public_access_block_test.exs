defmodule Maxio.S3.PublicAccessBlockTest do
  use Maxio.DataCase, async: false

  import Plug.Conn

  alias Maxio.{Auth.CredentialStore, BucketConfigs, Objects, Policy.Store}
  alias Maxio.S3.Endpoint
  alias Maxio.Test.SigV4Request

  @data_dir Path.join(System.tmp_dir!(), "maxio_public_access_block_test")
  @all_users "http://acs.amazonaws.com/groups/global/AllUsers"
  @alice_ak "AKIAPABALICE000001"
  @alice_secret "alicepabsecretalicepabsecret12"
  @alice_arn "arn:aws:iam:::user/" <> @alice_ak

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

  defp create_acl_bucket(bucket) do
    SigV4Request.signed_conn(:put, "/#{bucket}",
      headers: [{"x-amz-object-ownership", "ObjectWriter"}]
    )
    |> call()
  end

  defp alice(method, path, opts \\ []) do
    SigV4Request.signed_conn(
      method,
      path,
      Keyword.merge([access_key: @alice_ak, secret: @alice_secret], opts)
    )
  end

  defp put_pab(bucket, values, opts \\ []) do
    body = pab_xml(values)

    SigV4Request.signed_conn(:put, "/#{bucket}",
      query: %{"publicAccessBlock" => ""},
      body: body,
      headers: [{"content-md5", content_md5(body)}] ++ Keyword.get(opts, :headers, [])
    )
    |> call()
  end

  defp content_md5(body), do: :crypto.hash(:md5, body) |> Base.encode64()
  defp content_sha256(body), do: :crypto.hash(:sha256, body) |> Base.encode64()

  defp pab_xml(values) do
    values =
      Map.merge(
        %{
          "BlockPublicAcls" => false,
          "IgnorePublicAcls" => false,
          "BlockPublicPolicy" => false,
          "RestrictPublicBuckets" => false
        },
        values
      )

    children =
      Enum.map_join(
        ~w(BlockPublicAcls IgnorePublicAcls BlockPublicPolicy RestrictPublicBuckets),
        "",
        fn key -> "<#{key}>#{values[key]}</#{key}>" end
      )

    ~s(<PublicAccessBlockConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/">#{children}</PublicAccessBlockConfiguration>)
  end

  test "Put/Get/DeletePublicAccessBlock round-trips bucket-level config" do
    SigV4Request.signed_conn(:put, "/pabrt") |> call()

    put =
      put_pab("pabrt", %{
        "BlockPublicAcls" => true,
        "IgnorePublicAcls" => false,
        "BlockPublicPolicy" => true,
        "RestrictPublicBuckets" => false
      })

    assert put.status == 200
    assert put.resp_body == ""

    get = SigV4Request.signed_conn(:get, "/pabrt", query: %{"publicAccessBlock" => ""}) |> call()
    assert get.status == 200
    assert get_resp_header(get, "content-type") |> hd() =~ "application/xml"
    assert get.resp_body =~ "<BlockPublicAcls>true</BlockPublicAcls>"
    assert get.resp_body =~ "<IgnorePublicAcls>false</IgnorePublicAcls>"
    assert get.resp_body =~ "<BlockPublicPolicy>true</BlockPublicPolicy>"
    assert get.resp_body =~ "<RestrictPublicBuckets>false</RestrictPublicBuckets>"

    del =
      SigV4Request.signed_conn(:delete, "/pabrt", query: %{"publicAccessBlock" => ""})
      |> call()

    assert del.status == 204

    get2 =
      SigV4Request.signed_conn(:get, "/pabrt", query: %{"publicAccessBlock" => ""})
      |> call()

    assert get2.status == 404
    assert get2.resp_body =~ "NoSuchPublicAccessBlockConfiguration"
  end

  test "PutPublicAccessBlock requires and validates Content-MD5" do
    SigV4Request.signed_conn(:put, "/pabmd5") |> call()
    body = pab_xml(%{"BlockPublicAcls" => true})

    missing =
      SigV4Request.signed_conn(:put, "/pabmd5",
        query: %{"publicAccessBlock" => ""},
        body: body,
        auto_content_md5: false
      )
      |> call()

    assert missing.status == 400
    assert missing.resp_body =~ "MissingSecurityHeader"
    assert BucketConfigs.get("pabmd5", :public_access_block) == :none

    bad =
      SigV4Request.signed_conn(:put, "/pabmd5",
        query: %{"publicAccessBlock" => ""},
        body: body,
        headers: [{"content-md5", content_md5("different")}]
      )
      |> call()

    assert bad.status == 400
    assert bad.resp_body =~ "BadDigest"
    assert BucketConfigs.get("pabmd5", :public_access_block) == :none
  end

  test "malformed strict PublicAccessBlock XML does not overwrite existing config" do
    bucket = "pabstrict"
    SigV4Request.signed_conn(:put, "/#{bucket}") |> call()
    assert put_pab(bucket, %{"BlockPublicAcls" => true}).status == 200

    duplicate =
      ~s(<PublicAccessBlockConfiguration><BlockPublicAcls>false</BlockPublicAcls><BlockPublicAcls>true</BlockPublicAcls></PublicAccessBlockConfiguration>)

    duplicate_res =
      SigV4Request.signed_conn(:put, "/#{bucket}",
        query: %{"publicAccessBlock" => ""},
        body: duplicate
      )
      |> call()

    assert duplicate_res.status == 400
    assert duplicate_res.resp_body =~ "<Code>MalformedXML</Code>"

    unknown =
      ~s(<PublicAccessBlockConfiguration><Unknown>true</Unknown></PublicAccessBlockConfiguration>)

    unknown_res =
      SigV4Request.signed_conn(:put, "/#{bucket}",
        query: %{"publicAccessBlock" => ""},
        body: unknown
      )
      |> call()

    assert unknown_res.status == 400
    assert unknown_res.resp_body =~ "<Code>MalformedXML</Code>"

    assert {:ok,
            %{
              "BlockPublicAcls" => true,
              "IgnorePublicAcls" => false,
              "BlockPublicPolicy" => false,
              "RestrictPublicBuckets" => false
            }} = BucketConfigs.get(bucket, :public_access_block)
  end

  test "PutPublicAccessBlock validates modeled flexible checksum headers" do
    SigV4Request.signed_conn(:put, "/pabflex") |> call()
    body = pab_xml(%{"BlockPublicPolicy" => true})

    missing_value =
      SigV4Request.signed_conn(:put, "/pabflex",
        query: %{"publicAccessBlock" => ""},
        body: body,
        headers: [
          {"content-md5", content_md5(body)},
          {"x-amz-sdk-checksum-algorithm", "SHA256"}
        ]
      )
      |> call()

    assert missing_value.status == 400
    assert missing_value.resp_body =~ "InvalidRequest"
    assert BucketConfigs.get("pabflex", :public_access_block) == :none

    bad_sha256 =
      SigV4Request.signed_conn(:put, "/pabflex",
        query: %{"publicAccessBlock" => ""},
        body: body,
        headers: [
          {"content-md5", content_md5(body)},
          {"x-amz-sdk-checksum-algorithm", "SHA256"},
          {"x-amz-checksum-sha256", content_sha256("different")}
        ]
      )
      |> call()

    assert bad_sha256.status == 400
    assert bad_sha256.resp_body =~ "BadDigest"
    assert BucketConfigs.get("pabflex", :public_access_block) == :none

    ok =
      SigV4Request.signed_conn(:put, "/pabflex",
        query: %{"publicAccessBlock" => ""},
        body: body,
        headers: [
          {"content-md5", content_md5(body)},
          {"x-amz-sdk-checksum-algorithm", "SHA256"},
          {"x-amz-checksum-sha256", content_sha256(body)}
        ]
      )
      |> call()

    assert ok.status == 200

    assert {:ok, %{"BlockPublicPolicy" => true}} =
             BucketConfigs.get("pabflex", :public_access_block)
  end

  test "x-amz-expected-bucket-owner is enforced on Get Put and Delete" do
    SigV4Request.signed_conn(:put, "/pabowner") |> call()

    denied_put =
      put_pab("pabowner", %{"BlockPublicAcls" => true},
        headers: [{"x-amz-expected-bucket-owner", "999999999999"}]
      )

    assert denied_put.status == 403
    assert denied_put.resp_body =~ "AccessDenied"
    assert BucketConfigs.get("pabowner", :public_access_block) == :none

    allowed_put =
      put_pab("pabowner", %{"BlockPublicAcls" => true},
        headers: [{"x-amz-expected-bucket-owner", "000000000000"}]
      )

    assert allowed_put.status == 200

    denied_get =
      SigV4Request.signed_conn(:get, "/pabowner",
        query: %{"publicAccessBlock" => ""},
        headers: [{"x-amz-expected-bucket-owner", "999999999999"}]
      )
      |> call()

    assert denied_get.status == 403
    assert denied_get.resp_body =~ "AccessDenied"

    allowed_get =
      SigV4Request.signed_conn(:get, "/pabowner",
        query: %{"publicAccessBlock" => ""},
        headers: [{"x-amz-expected-bucket-owner", "000000000000"}]
      )
      |> call()

    assert allowed_get.status == 200
    assert allowed_get.resp_body =~ "<BlockPublicAcls>true</BlockPublicAcls>"

    denied_delete =
      SigV4Request.signed_conn(:delete, "/pabowner",
        query: %{"publicAccessBlock" => ""},
        headers: [{"x-amz-expected-bucket-owner", "999999999999"}]
      )
      |> call()

    assert denied_delete.status == 403
    assert denied_delete.resp_body =~ "AccessDenied"
    assert {:ok, _config} = BucketConfigs.get("pabowner", :public_access_block)

    allowed_delete =
      SigV4Request.signed_conn(:delete, "/pabowner",
        query: %{"publicAccessBlock" => ""},
        headers: [{"x-amz-expected-bucket-owner", "000000000000"}]
      )
      |> call()

    assert allowed_delete.status == 204
    assert BucketConfigs.get("pabowner", :public_access_block) == :none
  end

  test "checksum trailers and aws-chunked XML bodies require Content-MD5 and validate before storing config" do
    SigV4Request.signed_conn(:put, "/pabchunked") |> call()
    body = pab_xml(%{"RestrictPublicBuckets" => true})

    plain_trailer =
      put_pab("pabchunked", %{"RestrictPublicBuckets" => true},
        headers: [
          {"x-amz-sdk-checksum-algorithm", "SHA256"},
          {"x-amz-trailer", "x-amz-checksum-sha256"}
        ]
      )

    assert plain_trailer.status == 400
    assert plain_trailer.resp_body =~ "InvalidRequest"
    assert BucketConfigs.get("pabchunked", :public_access_block) == :none

    missing_md5 =
      SigV4Request.signed_chunked_conn(:put, "/pabchunked", body,
        query: %{"publicAccessBlock" => ""},
        auto_content_md5: false,
        headers: [{"x-amz-sdk-checksum-algorithm", "SHA256"}],
        trailer_headers: [{"x-amz-checksum-sha256", content_sha256(body)}]
      )
      |> call()

    assert missing_md5.status == 400
    assert missing_md5.resp_body =~ "MissingSecurityHeader"
    assert BucketConfigs.get("pabchunked", :public_access_block) == :none

    missing_trailer =
      SigV4Request.signed_chunked_conn(:put, "/pabchunked", body,
        query: %{"publicAccessBlock" => ""},
        headers: [
          {"content-md5", content_md5(body)},
          {"x-amz-sdk-checksum-algorithm", "SHA256"},
          {"x-amz-trailer", "x-amz-checksum-sha256"}
        ],
        streaming_payload_hash: "STREAMING-UNSIGNED-PAYLOAD-TRAILER"
      )
      |> call()

    assert missing_trailer.status == 400
    assert missing_trailer.resp_body =~ "IncompleteBody"
    assert BucketConfigs.get("pabchunked", :public_access_block) == :none

    bad =
      SigV4Request.signed_chunked_conn(:put, "/pabchunked", body,
        query: %{"publicAccessBlock" => ""},
        headers: [
          {"content-md5", content_md5(body)},
          {"x-amz-sdk-checksum-algorithm", "SHA256"}
        ],
        trailer_headers: [{"x-amz-checksum-sha256", content_sha256("different")}]
      )
      |> call()

    assert bad.status == 400
    assert bad.resp_body =~ "BadDigest"
    assert BucketConfigs.get("pabchunked", :public_access_block) == :none

    ok_trailer =
      SigV4Request.signed_chunked_conn(:put, "/pabchunked", body,
        query: %{"publicAccessBlock" => ""},
        headers: [
          {"content-md5", content_md5(body)},
          {"x-amz-sdk-checksum-algorithm", "SHA256"}
        ],
        trailer_headers: [{"x-amz-checksum-sha256", content_sha256(body)}]
      )
      |> call()

    assert ok_trailer.status == 200

    assert {:ok, %{"RestrictPublicBuckets" => true}} =
             BucketConfigs.get("pabchunked", :public_access_block)

    signed_trailer =
      SigV4Request.signed_chunked_conn(:put, "/pabchunked", body,
        query: %{"publicAccessBlock" => ""},
        headers: [
          {"content-md5", content_md5(body)},
          {"x-amz-sdk-checksum-algorithm", "SHA256"}
        ],
        trailer_headers: [{"x-amz-checksum-sha256", content_sha256(body)}],
        streaming_payload_hash: "STREAMING-AWS4-HMAC-SHA256-PAYLOAD-TRAILER"
      )
      |> call()

    assert signed_trailer.status == 200

    bad_signed_trailer =
      SigV4Request.signed_chunked_conn(:put, "/pabchunked", body,
        query: %{"publicAccessBlock" => ""},
        headers: [
          {"content-md5", content_md5(body)},
          {"x-amz-sdk-checksum-algorithm", "SHA256"}
        ],
        trailer_headers: [{"x-amz-checksum-sha256", content_sha256(body)}],
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
    assert {:ok, _config} = BucketConfigs.get("pabchunked", :public_access_block)

    ok_chunked =
      SigV4Request.signed_chunked_conn(:put, "/pabchunked", body,
        query: %{"publicAccessBlock" => ""},
        headers: [{"content-md5", content_md5(body)}]
      )
      |> call()

    assert ok_chunked.status == 200

    oversized = String.duplicate("x", 1_048_577)

    too_large =
      SigV4Request.signed_chunked_conn(:put, "/pabchunked", oversized,
        query: %{"publicAccessBlock" => ""},
        chunk_size: byte_size(oversized),
        decoded_length_override: 1_048_576,
        headers: [{"content-md5", content_md5(oversized)}]
      )
      |> call()

    assert too_large.status == 400
    assert too_large.resp_body =~ "MalformedXML"
    assert too_large.resp_body =~ "PublicAccessBlock config too large"

    assert {:ok, %{"RestrictPublicBuckets" => true}} =
             BucketConfigs.get("pabchunked", :public_access_block)
  end

  test "BlockPublicAcls rejects new public ACL writes before side effects" do
    create_acl_bucket("pabacl")
    assert put_pab("pabacl", %{"BlockPublicAcls" => true}).status == 200

    put_bucket_acl =
      SigV4Request.signed_conn(:put, "/pabacl",
        query: %{"acl" => ""},
        headers: [{"x-amz-grant-read", ~s(uri="#{@all_users}")}]
      )
      |> call()

    assert put_bucket_acl.status == 403
    assert put_bucket_acl.resp_body =~ "AccessDenied"

    bucket_acl = SigV4Request.signed_conn(:get, "/pabacl", query: %{"acl" => ""}) |> call()
    refute bucket_acl.resp_body =~ "AllUsers"

    put_object =
      SigV4Request.signed_conn(:put, "/pabacl/pub.txt",
        body: "public",
        headers: [{"x-amz-acl", "public-read"}]
      )
      |> call()

    assert put_object.status == 403
    assert {:error, :not_found} = Objects.get_metadata("pabacl", "pub.txt")

    ok = SigV4Request.signed_conn(:put, "/pabacl/private.txt", body: "private") |> call()
    assert ok.status == 200

    put_object_acl =
      SigV4Request.signed_conn(:put, "/pabacl/private.txt",
        query: %{"acl" => ""},
        headers: [{"x-amz-acl", "authenticated-read"}]
      )
      |> call()

    assert put_object_acl.status == 403

    copy =
      SigV4Request.signed_conn(:put, "/pabacl/copy.txt",
        headers: [
          {"x-amz-copy-source", "/pabacl/private.txt"},
          {"x-amz-acl", "public-read"}
        ]
      )
      |> call()

    assert copy.status == 403
    assert {:error, :not_found} = Objects.get_metadata("pabacl", "copy.txt")

    mpu =
      SigV4Request.signed_conn(:post, "/pabacl/mpu.txt",
        query: %{"uploads" => ""},
        headers: [{"x-amz-acl", "public-read"}]
      )
      |> call()

    assert mpu.status == 403
  end

  test "IgnorePublicAcls keeps stored ACL but removes public ACL from authz and GetObjectAcl" do
    create_acl_bucket("pabignore")

    put =
      SigV4Request.signed_conn(:put, "/pabignore/pub.txt",
        body: "hello",
        headers: [{"x-amz-acl", "public-read"}]
      )
      |> call()

    assert put.status == 200

    anon_before = SigV4Request.anon_conn(:get, "/pabignore/pub.txt") |> call()
    assert anon_before.status == 200
    assert anon_before.resp_body == "hello"

    assert put_pab("pabignore", %{"IgnorePublicAcls" => true}).status == 200

    {:ok, obj} = Objects.get_metadata("pabignore", "pub.txt")
    assert obj.acl_canned == "public-read"

    anon_after = SigV4Request.anon_conn(:get, "/pabignore/pub.txt") |> call()
    assert anon_after.status == 403

    owner_after = SigV4Request.signed_conn(:get, "/pabignore/pub.txt") |> call()
    assert owner_after.status == 200
    assert owner_after.resp_body == "hello"

    acl =
      SigV4Request.signed_conn(:get, "/pabignore/pub.txt", query: %{"acl" => ""})
      |> call()

    assert acl.status == 200
    refute acl.resp_body =~ "AllUsers"
    assert acl.resp_body =~ "<Permission>FULL_CONTROL</Permission>"
  end

  test "BlockPublicPolicy rejects public bucket policy and preserves existing policy" do
    SigV4Request.signed_conn(:put, "/pabpol") |> call()

    existing =
      ~s({"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"AWS":"arn:aws:iam:::root"},"Action":["s3:GetObject"],"Resource":["arn:aws:s3:::pabpol/*"]}]})

    assert (SigV4Request.signed_conn(:put, "/pabpol",
              query: %{"policy" => ""},
              body: existing
            )
            |> call()).status == 204

    assert put_pab("pabpol", %{"BlockPublicPolicy" => true}).status == 200

    public =
      ~s({"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":"*","Action":["s3:GetObject"],"Resource":["arn:aws:s3:::pabpol/*"]}]})

    rejected =
      SigV4Request.signed_conn(:put, "/pabpol", query: %{"policy" => ""}, body: public)
      |> call()

    assert rejected.status == 403
    assert rejected.resp_body =~ "AccessDenied"

    assert {:ok, stored} = Store.get_bucket_policy("pabpol")
    assert Jason.decode!(stored) == Jason.decode!(existing)
  end

  test "BlockPublicPolicy treats missing-key-true fixed conditions as public" do
    SigV4Request.signed_conn(:put, "/pabifexists") |> call()
    assert put_pab("pabifexists", %{"BlockPublicPolicy" => true}).status == 200

    for condition <- [
          %{"StringEqualsIfExists" => %{"aws:SourceVpc" => "vpc-1"}},
          %{"ForAllValues:StringEquals" => %{"aws:SourceVpc" => "vpc-1"}}
        ] do
      policy =
        Jason.encode!(%{
          "Version" => "2012-10-17",
          "Statement" => [
            %{
              "Effect" => "Allow",
              "Principal" => "*",
              "Action" => ["s3:GetObject"],
              "Resource" => ["arn:aws:s3:::pabifexists/*"],
              "Condition" => condition
            }
          ]
        })

      rejected =
        SigV4Request.signed_conn(:put, "/pabifexists",
          query: %{"policy" => ""},
          body: policy
        )
        |> call()

      assert rejected.status == 403
      assert rejected.resp_body =~ "AccessDenied"
      assert :none = Store.get_bucket_policy("pabifexists")
    end
  end

  test "RestrictPublicBuckets suppresses public bucket policy grants during authz" do
    SigV4Request.signed_conn(:put, "/pabrestrict") |> call()
    SigV4Request.signed_conn(:put, "/pabrestrict/pub.txt", body: "hello") |> call()

    policy =
      ~s({"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":"*","Action":["s3:GetObject"],"Resource":["arn:aws:s3:::pabrestrict/*"]}]})

    assert (SigV4Request.signed_conn(:put, "/pabrestrict",
              query: %{"policy" => ""},
              body: policy
            )
            |> call()).status == 204

    anon_before = SigV4Request.anon_conn(:get, "/pabrestrict/pub.txt") |> call()
    assert anon_before.status == 200

    assert put_pab("pabrestrict", %{"RestrictPublicBuckets" => true}).status == 200

    anon_after = SigV4Request.anon_conn(:get, "/pabrestrict/pub.txt") |> call()
    assert anon_after.status == 403
  end

  test "RestrictPublicBuckets suppresses explicit principal grants when policy is public" do
    SigV4Request.signed_conn(:put, "/pabmixed") |> call()
    SigV4Request.signed_conn(:put, "/pabmixed/private.txt", body: "private") |> call()

    policy =
      Jason.encode!(%{
        "Version" => "2012-10-17",
        "Statement" => [
          %{
            "Effect" => "Allow",
            "Principal" => "*",
            "Action" => ["s3:GetObject"],
            "Resource" => ["arn:aws:s3:::pabmixed/public/*"]
          },
          %{
            "Effect" => "Allow",
            "Principal" => %{"AWS" => @alice_arn},
            "Action" => ["s3:GetObject"],
            "Resource" => ["arn:aws:s3:::pabmixed/*"]
          }
        ]
      })

    assert (SigV4Request.signed_conn(:put, "/pabmixed",
              query: %{"policy" => ""},
              body: policy
            )
            |> call()).status == 204

    assert (alice(:get, "/pabmixed/private.txt") |> call()).status == 200
    assert put_pab("pabmixed", %{"RestrictPublicBuckets" => true}).status == 200

    denied = alice(:get, "/pabmixed/private.txt") |> call()
    assert denied.status == 403

    owner = SigV4Request.signed_conn(:get, "/pabmixed/private.txt") |> call()
    assert owner.status == 200
    assert owner.resp_body == "private"
  end
end
