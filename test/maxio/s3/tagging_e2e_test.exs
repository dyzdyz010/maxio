defmodule Maxio.S3.TaggingE2ETest do
  use Maxio.DataCase, async: false
  import Plug.Conn
  alias Maxio.Auth.CredentialStore
  alias Maxio.{Buckets, Objects}
  alias Maxio.Policy.Store
  alias Maxio.Test.SigV4Request
  alias Maxio.S3.Endpoint

  @data_dir Path.join(System.tmp_dir!(), "maxio_tagging_e2e")
  @alice_ak "AKIATAGGINGALICE001"
  @alice_secret "alicetaggingsecretalicetagging12"
  @alice_arn "arn:aws:iam:::user/" <> @alice_ak
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

  defp checksum_b64(algorithm, body), do: :crypto.hash(algorithm, body) |> Base.encode64()
  defp content_md5(body), do: checksum_b64(:md5, body)

  defp enable_versioning(bucket) do
    body = ~s(<VersioningConfiguration><Status>Enabled</Status></VersioningConfiguration>)

    SigV4Request.signed_conn(:put, "/#{bucket}", query: %{"versioning" => ""}, body: body)
    |> call()
  end

  defp put_request_payment(bucket) do
    SigV4Request.signed_conn(:put, "/#{bucket}",
      query: %{"requestPayment" => ""},
      body: @requester,
      headers: [{"content-md5", content_md5(@requester)}]
    )
    |> call()
  end

  defp allow_alice_tagging(bucket, actions, policy_suffix \\ "tagging") do
    policy =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":#{Jason.encode!(actions)},"Resource":"arn:aws:s3:::#{bucket}/*"}})

    Store.put_principal_policy(@alice_arn, "#{policy_suffix}-#{bucket}", policy)
  end

  defp object_tagging_actions do
    ["s3:GetObjectTagging", "s3:PutObjectTagging", "s3:DeleteObjectTagging"]
  end

  defp object_version_tagging_actions do
    [
      "s3:GetObjectVersionTagging",
      "s3:PutObjectVersionTagging",
      "s3:DeleteObjectVersionTagging"
    ]
  end

  defp assert_charged(conn),
    do: assert(get_resp_header(conn, "x-amz-request-charged") == ["requester"])

  defp refute_charged(conn), do: assert(get_resp_header(conn, "x-amz-request-charged") == [])

  defp tag_value?(tags, key, value) do
    Enum.any?(tags, fn
      {^key, ^value} -> true
      %{"key" => ^key, "value" => ^value} -> true
      %{"Key" => ^key, "Value" => ^value} -> true
      _other -> false
    end)
  end

  @tagging ~s(<Tagging xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><TagSet><Tag><Key>env</Key><Value>prod</Value></Tag><Tag><Key>team</Key><Value>core</Value></Tag></TagSet></Tagging>)
  @updated_tagging ~s(<Tagging><TagSet><Tag><Key>env</Key><Value>dev</Value></Tag></TagSet></Tagging>)

  test "PutObjectTagging 200 → GetObjectTagging 200 回放 → DeleteObjectTagging 204" do
    SigV4Request.signed_conn(:put, "/tagb") |> call()
    SigV4Request.signed_conn(:put, "/tagb/k.txt", body: "x") |> call()

    put =
      SigV4Request.signed_conn(:put, "/tagb/k.txt", query: %{"tagging" => ""}, body: @tagging)
      |> call()

    assert put.status == 200

    get = SigV4Request.signed_conn(:get, "/tagb/k.txt", query: %{"tagging" => ""}) |> call()
    assert get.status == 200
    assert get.resp_body =~ "<Key>env</Key>"
    assert get.resp_body =~ "<Value>prod</Value>"

    # GET object 带 x-amz-tagging-count: 2
    obj = SigV4Request.signed_conn(:get, "/tagb/k.txt") |> call()
    assert get_resp_header(obj, "x-amz-tagging-count") == ["2"]

    del = SigV4Request.signed_conn(:delete, "/tagb/k.txt", query: %{"tagging" => ""}) |> call()
    assert del.status == 204

    get2 = SigV4Request.signed_conn(:get, "/tagb/k.txt", query: %{"tagging" => ""}) |> call()
    refute get2.resp_body =~ "<Key>"
  end

  test "PutObject 带 x-amz-tagging 头 → GET 回 x-amz-tagging-count" do
    SigV4Request.signed_conn(:put, "/tagb2") |> call()

    SigV4Request.signed_conn(:put, "/tagb2/k.txt",
      body: "x",
      headers: [{"x-amz-tagging", "a=1&b=2"}]
    )
    |> call()

    obj = SigV4Request.signed_conn(:get, "/tagb2/k.txt") |> call()
    assert get_resp_header(obj, "x-amz-tagging-count") == ["2"]
  end

  test "PutBucketTagging 204 → GetBucketTagging 200" do
    SigV4Request.signed_conn(:put, "/tagb3") |> call()

    put =
      SigV4Request.signed_conn(:put, "/tagb3", query: %{"tagging" => ""}, body: @tagging)
      |> call()

    assert put.status == 204
    get = SigV4Request.signed_conn(:get, "/tagb3", query: %{"tagging" => ""}) |> call()
    assert get.resp_body =~ "<Key>env</Key>"
  end

  test "object tagging enforces Requester Pays before mutation and charges acknowledged non-owner calls" do
    bucket = "tagrpguard"
    key = "object.txt"

    assert (SigV4Request.signed_conn(:put, "/#{bucket}") |> call()).status == 200

    assert (SigV4Request.signed_conn(:put, "/#{bucket}/#{key}", body: "x") |> call()).status ==
             200

    assert put_request_payment(bucket).status == 200
    assert :ok = allow_alice_tagging(bucket, object_tagging_actions())

    assert (SigV4Request.signed_conn(:put, "/#{bucket}/#{key}",
              query: %{"tagging" => ""},
              body: @tagging
            )
            |> call()).status == 200

    missing_put =
      alice(:put, "/#{bucket}/#{key}", query: %{"tagging" => ""}, body: @updated_tagging)
      |> call()

    assert missing_put.status == 403
    assert missing_put.resp_body =~ "<Code>AccessDenied</Code>"
    refute_charged(missing_put)

    invalid_put =
      alice(:put, "/#{bucket}/#{key}",
        query: %{"tagging" => ""},
        body: @updated_tagging,
        headers: [{"x-amz-request-payer", "owner"}]
      )
      |> call()

    assert invalid_put.status == 403
    refute_charged(invalid_put)

    unsigned_put =
      alice(:put, "/#{bucket}/#{key}", query: %{"tagging" => ""}, body: @updated_tagging)
      |> put_req_header("x-amz-request-payer", "requester")
      |> call()

    assert unsigned_put.status == 403
    refute_charged(unsigned_put)

    wrong_owner_put =
      alice(:put, "/#{bucket}/#{key}",
        query: %{"tagging" => ""},
        body: @updated_tagging,
        headers: [
          {"x-amz-request-payer", "requester"},
          {"x-amz-expected-bucket-owner", "111111111111"}
        ]
      )
      |> call()

    assert wrong_owner_put.status == 403
    refute_charged(wrong_owner_put)

    still_original =
      SigV4Request.signed_conn(:get, "/#{bucket}/#{key}", query: %{"tagging" => ""})
      |> call()

    assert still_original.status == 200
    assert still_original.resp_body =~ "<Value>prod</Value>"
    refute still_original.resp_body =~ "<Value>dev</Value>"

    query_put =
      alice(:put, "/#{bucket}/#{key}",
        query: %{"tagging" => "", "x-amz-request-payer" => "requester"},
        body: @updated_tagging
      )
      |> call()

    assert query_put.status == 200
    assert_charged(query_put)

    header_get =
      alice(:get, "/#{bucket}/#{key}",
        query: %{"tagging" => ""},
        headers: [{"x-amz-request-payer", "requester"}]
      )
      |> call()

    assert header_get.status == 200
    assert header_get.resp_body =~ "<Value>dev</Value>"
    assert_charged(header_get)

    query_get =
      alice(:get, "/#{bucket}/#{key}",
        query: %{"tagging" => "", "x-amz-request-payer" => "requester"}
      )
      |> call()

    assert query_get.status == 200
    assert_charged(query_get)

    owner_get =
      SigV4Request.signed_conn(:get, "/#{bucket}/#{key}", query: %{"tagging" => ""})
      |> call()

    assert owner_get.status == 200
    refute_charged(owner_get)

    missing_delete =
      alice(:delete, "/#{bucket}/#{key}", query: %{"tagging" => ""})
      |> call()

    assert missing_delete.status == 403
    refute_charged(missing_delete)

    invalid_delete =
      alice(:delete, "/#{bucket}/#{key}",
        query: %{"tagging" => ""},
        headers: [{"x-amz-request-payer", "owner"}]
      )
      |> call()

    assert invalid_delete.status == 403
    refute_charged(invalid_delete)

    unsigned_delete =
      alice(:delete, "/#{bucket}/#{key}", query: %{"tagging" => ""})
      |> put_req_header("x-amz-request-payer", "requester")
      |> call()

    assert unsigned_delete.status == 403
    refute_charged(unsigned_delete)

    tags_after_denied_delete =
      alice(:get, "/#{bucket}/#{key}",
        query: %{"tagging" => "", "x-amz-request-payer" => "requester"}
      )
      |> call()

    assert tags_after_denied_delete.resp_body =~ "<Value>dev</Value>"

    header_delete =
      alice(:delete, "/#{bucket}/#{key}",
        query: %{"tagging" => ""},
        headers: [{"x-amz-request-payer", "requester"}]
      )
      |> call()

    assert header_delete.status == 204
    assert_charged(header_delete)

    empty_tags =
      SigV4Request.signed_conn(:get, "/#{bucket}/#{key}", query: %{"tagging" => ""})
      |> call()

    assert empty_tags.status == 200
    refute empty_tags.resp_body =~ "<Key>"
  end

  test "versioned object tagging targets requested versions and requires version-specific IAM actions" do
    bucket = "tagversionguard"
    key = "doc.txt"

    assert (SigV4Request.signed_conn(:put, "/#{bucket}") |> call()).status == 200
    assert enable_versioning(bucket).status == 200

    v1_put = SigV4Request.signed_conn(:put, "/#{bucket}/#{key}", body: "old") |> call()
    assert [v1] = get_resp_header(v1_put, "x-amz-version-id")

    v2_put = SigV4Request.signed_conn(:put, "/#{bucket}/#{key}", body: "new") |> call()
    assert [v2] = get_resp_header(v2_put, "x-amz-version-id")
    assert v1 != v2

    current_put =
      SigV4Request.signed_conn(:put, "/#{bucket}/#{key}",
        query: %{"tagging" => ""},
        body: @updated_tagging
      )
      |> call()

    assert current_put.status == 200
    assert get_resp_header(current_put, "x-amz-version-id") == [v2]

    version_put =
      SigV4Request.signed_conn(:put, "/#{bucket}/#{key}",
        query: %{"tagging" => "", "versionId" => v1},
        body: @tagging
      )
      |> call()

    assert version_put.status == 200
    assert get_resp_header(version_put, "x-amz-version-id") == [v1]

    assert :ok = allow_alice_tagging(bucket, object_tagging_actions(), "non-version-tagging")

    current_get = alice(:get, "/#{bucket}/#{key}", query: %{"tagging" => ""}) |> call()
    assert current_get.status == 200
    assert get_resp_header(current_get, "x-amz-version-id") == [v2]

    denied_version_get =
      alice(:get, "/#{bucket}/#{key}", query: %{"tagging" => "", "versionId" => v1})
      |> call()

    assert denied_version_get.status == 403

    denied_version_put =
      alice(:put, "/#{bucket}/#{key}",
        query: %{"tagging" => "", "versionId" => v1},
        body: @updated_tagging
      )
      |> call()

    assert denied_version_put.status == 403

    denied_version_delete =
      alice(:delete, "/#{bucket}/#{key}", query: %{"tagging" => "", "versionId" => v1})
      |> call()

    assert denied_version_delete.status == 403

    assert :ok =
             allow_alice_tagging(
               bucket,
               object_version_tagging_actions(),
               "version-tagging"
             )

    invalid_get =
      alice(:get, "/#{bucket}/#{key}", query: %{"tagging" => "", "versionId" => "bad"})
      |> call()

    assert invalid_get.status == 400
    assert invalid_get.resp_body =~ "InvalidArgument"

    invalid_put =
      alice(:put, "/#{bucket}/#{key}",
        query: %{"tagging" => "", "versionId" => "bad"},
        body: @updated_tagging
      )
      |> call()

    assert invalid_put.status == 400
    assert invalid_put.resp_body =~ "InvalidArgument"

    invalid_delete =
      alice(:delete, "/#{bucket}/#{key}", query: %{"tagging" => "", "versionId" => "bad"})
      |> call()

    assert invalid_delete.status == 400
    assert invalid_delete.resp_body =~ "InvalidArgument"

    old_get =
      alice(:get, "/#{bucket}/#{key}", query: %{"tagging" => "", "versionId" => v1})
      |> call()

    assert old_get.status == 200
    assert get_resp_header(old_get, "x-amz-version-id") == [v1]
    assert old_get.resp_body =~ "<Value>prod</Value>"

    old_update =
      alice(:put, "/#{bucket}/#{key}",
        query: %{"tagging" => "", "versionId" => v1},
        body: @updated_tagging
      )
      |> call()

    assert old_update.status == 200
    assert get_resp_header(old_update, "x-amz-version-id") == [v1]

    latest_after_old_update =
      SigV4Request.signed_conn(:get, "/#{bucket}/#{key}", query: %{"tagging" => ""})
      |> call()

    assert latest_after_old_update.status == 200
    assert get_resp_header(latest_after_old_update, "x-amz-version-id") == [v2]
    assert latest_after_old_update.resp_body =~ "<Value>dev</Value>"

    old_delete =
      alice(:delete, "/#{bucket}/#{key}", query: %{"tagging" => "", "versionId" => v1})
      |> call()

    assert old_delete.status == 204
    assert get_resp_header(old_delete, "x-amz-version-id") == [v1]

    old_empty =
      SigV4Request.signed_conn(:get, "/#{bucket}/#{key}",
        query: %{"tagging" => "", "versionId" => v1}
      )
      |> call()

    assert old_empty.status == 200
    refute old_empty.resp_body =~ "<Key>"

    latest_still_tagged =
      SigV4Request.signed_conn(:get, "/#{bucket}/#{key}", query: %{"tagging" => ""})
      |> call()

    assert latest_still_tagged.resp_body =~ "<Value>dev</Value>"
  end

  test "object tagging treats delete markers as absent objects and never mutates marker tags" do
    bucket = "tagdeletemarker"
    key = "doc.txt"

    assert (SigV4Request.signed_conn(:put, "/#{bucket}") |> call()).status == 200
    assert enable_versioning(bucket).status == 200

    put = SigV4Request.signed_conn(:put, "/#{bucket}/#{key}", body: "live") |> call()
    assert [_object_version] = get_resp_header(put, "x-amz-version-id")

    assert (SigV4Request.signed_conn(:put, "/#{bucket}/#{key}",
              query: %{"tagging" => ""},
              body: @tagging
            )
            |> call()).status == 200

    delete = SigV4Request.signed_conn(:delete, "/#{bucket}/#{key}") |> call()
    assert delete.status == 204
    assert [delete_marker_version] = get_resp_header(delete, "x-amz-version-id")
    assert get_resp_header(delete, "x-amz-delete-marker") == ["true"]

    current_get =
      SigV4Request.signed_conn(:get, "/#{bucket}/#{key}", query: %{"tagging" => ""})
      |> call()

    assert current_get.status == 404
    assert current_get.resp_body == ""
    assert get_resp_header(current_get, "x-amz-delete-marker") == ["true"]
    assert get_resp_header(current_get, "x-amz-version-id") == [delete_marker_version]

    current_put =
      SigV4Request.signed_conn(:put, "/#{bucket}/#{key}",
        query: %{"tagging" => ""},
        body: @updated_tagging
      )
      |> call()

    assert current_put.status == 404
    assert get_resp_header(current_put, "x-amz-delete-marker") == ["true"]
    assert get_resp_header(current_put, "x-amz-version-id") == [delete_marker_version]

    current_delete =
      SigV4Request.signed_conn(:delete, "/#{bucket}/#{key}", query: %{"tagging" => ""})
      |> call()

    assert current_delete.status == 404
    assert get_resp_header(current_delete, "x-amz-delete-marker") == ["true"]
    assert get_resp_header(current_delete, "x-amz-version-id") == [delete_marker_version]

    {:ok, marker_after_current_ops} = Objects.get_version(bucket, key, delete_marker_version)
    assert marker_after_current_ops.is_delete_marker == true
    assert marker_after_current_ops.tags == %{}

    explicit_get =
      SigV4Request.signed_conn(:get, "/#{bucket}/#{key}",
        query: %{"tagging" => "", "versionId" => delete_marker_version}
      )
      |> call()

    assert explicit_get.status == 405
    assert explicit_get.resp_body == ""
    assert get_resp_header(explicit_get, "x-amz-delete-marker") == ["true"]
    assert get_resp_header(explicit_get, "x-amz-version-id") == [delete_marker_version]
    assert [_] = get_resp_header(explicit_get, "last-modified")

    explicit_put =
      SigV4Request.signed_conn(:put, "/#{bucket}/#{key}",
        query: %{"tagging" => "", "versionId" => delete_marker_version},
        body: @updated_tagging
      )
      |> call()

    assert explicit_put.status == 405
    assert get_resp_header(explicit_put, "x-amz-delete-marker") == ["true"]
    assert get_resp_header(explicit_put, "x-amz-version-id") == [delete_marker_version]
    assert [_] = get_resp_header(explicit_put, "last-modified")

    explicit_delete =
      SigV4Request.signed_conn(:delete, "/#{bucket}/#{key}",
        query: %{"tagging" => "", "versionId" => delete_marker_version}
      )
      |> call()

    assert explicit_delete.status == 405
    assert get_resp_header(explicit_delete, "x-amz-delete-marker") == ["true"]
    assert get_resp_header(explicit_delete, "x-amz-version-id") == [delete_marker_version]
    assert [_] = get_resp_header(explicit_delete, "last-modified")

    {:ok, marker_after_explicit_ops} = Objects.get_version(bucket, key, delete_marker_version)
    assert marker_after_explicit_ops.is_delete_marker == true
    assert marker_after_explicit_ops.tags == %{}
  end

  test "malformed strict tagging XML does not overwrite existing bucket or object tags" do
    bucket = "tagstrict"
    SigV4Request.signed_conn(:put, "/#{bucket}") |> call()

    assert (SigV4Request.signed_conn(:put, "/#{bucket}",
              query: %{"tagging" => ""},
              body: @tagging
            )
            |> call()).status == 204

    bad_bucket =
      SigV4Request.signed_conn(:put, "/#{bucket}",
        query: %{"tagging" => ""},
        body: ~s(<Tagging><Tag><Key>env</Key><Value>dev</Value></Tag></Tagging>)
      )
      |> call()

    assert bad_bucket.status == 400
    assert bad_bucket.resp_body =~ "<Code>MalformedXML</Code>"
    assert {:ok, tags} = Buckets.get_tags(bucket)
    assert tag_value?(tags, "env", "prod")

    bad_key =
      SigV4Request.signed_conn(:put, "/#{bucket}",
        query: %{"tagging" => ""},
        body: ~s(<Tagging><TagSet><Tag><Key></Key><Value>dev</Value></Tag></TagSet></Tagging>)
      )
      |> call()

    assert bad_key.status == 400
    assert bad_key.resp_body =~ "<Code>InvalidTag</Code>"
    assert {:ok, tags} = Buckets.get_tags(bucket)
    assert tag_value?(tags, "env", "prod")

    assert (SigV4Request.signed_conn(:put, "/#{bucket}/object.txt", body: "x") |> call()).status ==
             200

    assert (SigV4Request.signed_conn(:put, "/#{bucket}/object.txt",
              query: %{"tagging" => ""},
              body: @tagging
            )
            |> call()).status == 200

    bad_object =
      SigV4Request.signed_conn(:put, "/#{bucket}/object.txt",
        query: %{"tagging" => ""},
        body: ~s(<Tagging><TagSet><Tag><Key>env</Key></Tag></TagSet></Tagging>)
      )
      |> call()

    assert bad_object.status == 400
    assert bad_object.resp_body =~ "<Code>MalformedXML</Code>"

    object_tags =
      SigV4Request.signed_conn(:get, "/#{bucket}/object.txt", query: %{"tagging" => ""})
      |> call()

    assert object_tags.status == 200
    assert object_tags.resp_body =~ "<Value>prod</Value>"
    refute object_tags.resp_body =~ "<Value>dev</Value>"
  end

  test "bucket and object tagging validate Content-MD5, checksums, trailers, and expected owner" do
    bucket = "tagchecksum"
    SigV4Request.signed_conn(:put, "/#{bucket}") |> call()

    missing_md5 =
      SigV4Request.signed_conn(:put, "/#{bucket}",
        query: %{"tagging" => ""},
        body: @tagging,
        auto_content_md5: false
      )
      |> call()

    assert missing_md5.status == 400
    assert missing_md5.resp_body =~ "<Code>MissingSecurityHeader</Code>"
    assert {:ok, []} = Buckets.get_tags(bucket)

    good_bucket =
      SigV4Request.signed_conn(:put, "/#{bucket}",
        query: %{"tagging" => ""},
        body: @tagging
      )
      |> call()

    assert good_bucket.status == 204
    assert {:ok, tags} = Buckets.get_tags(bucket)
    assert tag_value?(tags, "env", "prod")

    bad_md5 =
      SigV4Request.signed_conn(:put, "/#{bucket}",
        query: %{"tagging" => ""},
        body: @updated_tagging,
        headers: [{"content-md5", checksum_b64(:md5, "different")}]
      )
      |> call()

    assert bad_md5.status == 400
    assert bad_md5.resp_body =~ "<Code>BadDigest</Code>"
    assert {:ok, tags} = Buckets.get_tags(bucket)
    assert tag_value?(tags, "env", "prod")

    bad_trailer =
      SigV4Request.signed_chunked_conn(:put, "/#{bucket}", @updated_tagging,
        query: %{"tagging" => ""},
        headers: [
          {"content-md5", checksum_b64(:md5, @updated_tagging)},
          {"x-amz-sdk-checksum-algorithm", "SHA256"}
        ],
        trailer_headers: [{"x-amz-checksum-sha256", checksum_b64(:sha256, "different")}]
      )
      |> call()

    assert bad_trailer.status == 400
    assert bad_trailer.resp_body =~ "<Code>BadDigest</Code>"
    assert {:ok, tags} = Buckets.get_tags(bucket)
    assert tag_value?(tags, "env", "prod")

    ok_trailer =
      SigV4Request.signed_chunked_conn(:put, "/#{bucket}", @updated_tagging,
        query: %{"tagging" => ""},
        headers: [
          {"content-md5", checksum_b64(:md5, @updated_tagging)},
          {"x-amz-sdk-checksum-algorithm", "SHA256"}
        ],
        trailer_headers: [{"x-amz-checksum-sha256", checksum_b64(:sha256, @updated_tagging)}]
      )
      |> call()

    assert ok_trailer.status == 204
    assert {:ok, tags} = Buckets.get_tags(bucket)
    assert tag_value?(tags, "env", "dev")

    wrong_bucket_put =
      SigV4Request.signed_conn(:put, "/#{bucket}",
        query: %{"tagging" => ""},
        body: @tagging,
        headers: [{"x-amz-expected-bucket-owner", "111111111111"}]
      )
      |> call()

    assert wrong_bucket_put.status == 403
    assert {:ok, tags} = Buckets.get_tags(bucket)
    assert tag_value?(tags, "env", "dev")

    wrong_bucket_get =
      SigV4Request.signed_conn(:get, "/#{bucket}",
        query: %{"tagging" => ""},
        headers: [{"x-amz-expected-bucket-owner", "111111111111"}]
      )
      |> call()

    assert wrong_bucket_get.status == 403

    wrong_bucket_delete =
      SigV4Request.signed_conn(:delete, "/#{bucket}",
        query: %{"tagging" => ""},
        headers: [{"x-amz-expected-bucket-owner", "111111111111"}]
      )
      |> call()

    assert wrong_bucket_delete.status == 403
    assert {:ok, tags} = Buckets.get_tags(bucket)
    assert tag_value?(tags, "env", "dev")

    assert (SigV4Request.signed_conn(:put, "/#{bucket}/object.txt", body: "x") |> call()).status ==
             200

    assert (SigV4Request.signed_conn(:put, "/#{bucket}/object.txt",
              query: %{"tagging" => ""},
              body: @tagging
            )
            |> call()).status == 200

    wrong_object_put =
      SigV4Request.signed_conn(:put, "/#{bucket}/object.txt",
        query: %{"tagging" => ""},
        body: @updated_tagging,
        headers: [{"x-amz-expected-bucket-owner", "111111111111"}]
      )
      |> call()

    assert wrong_object_put.status == 403

    object_tags =
      SigV4Request.signed_conn(:get, "/#{bucket}/object.txt", query: %{"tagging" => ""})
      |> call()

    assert object_tags.status == 200
    assert object_tags.resp_body =~ "<Value>prod</Value>"

    wrong_object_get =
      SigV4Request.signed_conn(:get, "/#{bucket}/object.txt",
        query: %{"tagging" => ""},
        headers: [{"x-amz-expected-bucket-owner", "111111111111"}]
      )
      |> call()

    assert wrong_object_get.status == 403

    wrong_object_delete =
      SigV4Request.signed_conn(:delete, "/#{bucket}/object.txt",
        query: %{"tagging" => ""},
        headers: [{"x-amz-expected-bucket-owner", "111111111111"}]
      )
      |> call()

    assert wrong_object_delete.status == 403

    object_tags_after =
      SigV4Request.signed_conn(:get, "/#{bucket}/object.txt", query: %{"tagging" => ""})
      |> call()

    assert object_tags_after.status == 200
    assert object_tags_after.resp_body =~ "<Value>prod</Value>"
  end

  test "超 10 tag → InvalidTag 400" do
    SigV4Request.signed_conn(:put, "/tagb4") |> call()
    SigV4Request.signed_conn(:put, "/tagb4/k.txt", body: "x") |> call()
    tags = for i <- 1..11, do: "<Tag><Key>k#{i}</Key><Value>v</Value></Tag>"
    body = "<Tagging><TagSet>#{Enum.join(tags)}</TagSet></Tagging>"

    bad =
      SigV4Request.signed_conn(:put, "/tagb4/k.txt", query: %{"tagging" => ""}, body: body)
      |> call()

    assert bad.status == 400
    assert bad.resp_body =~ "InvalidTag"
  end
end
