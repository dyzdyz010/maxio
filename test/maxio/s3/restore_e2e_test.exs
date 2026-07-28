defmodule Maxio.S3.RestoreE2ETest do
  use Maxio.DataCase, async: false

  import Plug.Conn, only: [get_resp_header: 2]

  alias Maxio.Auth.CredentialStore
  alias Maxio.Objects
  alias Maxio.Policy.Store
  alias Maxio.S3.{Endpoint, RestoreExpiry}
  alias Maxio.Test.SigV4Request

  @data_dir Path.join(System.tmp_dir!(), "maxio_restore_e2e")
  @alice_ak "AKIARESTOREALICE001"
  @alice_secret "restorealicealicesecret12345"
  @alice_arn "arn:aws:iam:::user/" <> @alice_ak
  @requester """
  <RequestPaymentConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
    <Payer>Requester</Payer>
  </RequestPaymentConfiguration>
  """

  setup do
    File.rm_rf(@data_dir)
    File.mkdir_p!(@data_dir)
    prev = Application.get_env(:maxio, :s3)
    prev_authoritative_source = Application.get_env(:maxio, :authoritative_source)
    Application.put_env(:maxio, :s3, Keyword.put(prev, :data_dir, @data_dir))
    Application.put_env(:maxio, :authoritative_source, read: :pg, list: :pg, write: :pg)

    :ok =
      CredentialStore.put_access_key(%{
        access_key: @alice_ak,
        secret_key: @alice_secret,
        principal: %{type: :iam_user, access_key: @alice_ak, arn: @alice_arn}
      })

    on_exit(fn ->
      Application.put_env(:maxio, :s3, prev)
      restore_env(:authoritative_source, prev_authoritative_source)
      File.rm_rf(@data_dir)
    end)

    :ok
  end

  test "RestoreObject records restore metadata and unblocks archive GET" do
    SigV4Request.signed_conn(:put, "/restore") |> call()

    put =
      SigV4Request.signed_conn(:put, "/restore/cold.txt",
        body: "cold bytes",
        headers: [{"x-amz-storage-class", "GLACIER"}]
      )
      |> call()

    assert put.status == 200

    before_restore = SigV4Request.signed_conn(:get, "/restore/cold.txt") |> call()
    assert before_restore.status == 403
    assert before_restore.resp_body =~ "<Code>InvalidObjectState</Code>"

    xml =
      ~s(<RestoreRequest><Days>3</Days><GlacierJobParameters><Tier>Standard</Tier></GlacierJobParameters></RestoreRequest>)

    restore =
      SigV4Request.signed_conn(:post, "/restore/cold.txt", query: %{"restore" => ""}, body: xml)
      |> call()

    assert restore.status == 202
    {:ok, object} = Objects.get_metadata("restore", "cold.txt")
    assert object.restore_status == "restored"
    assert %DateTime{} = object.restore_expiry

    head = SigV4Request.signed_conn(:head, "/restore/cold.txt") |> call()
    assert head.status == 200
    [restore_header] = get_resp_header(head, "x-amz-restore")
    assert restore_header =~ ~s(ongoing-request="false")
    assert restore_header =~ "expiry-date="

    get = SigV4Request.signed_conn(:get, "/restore/cold.txt") |> call()
    assert get.status == 200
    assert get.resp_body == "cold bytes"
    assert get_resp_header(get, "x-amz-restore") == [restore_header]

    second =
      SigV4Request.signed_conn(:post, "/restore/cold.txt", query: %{"restore" => ""}, body: xml)
      |> call()

    assert second.status == 200
  end

  test "List APIs include RestoreStatus only when optional object attributes request it" do
    SigV4Request.signed_conn(:put, "/restorelist") |> call()
    assert enable_versioning("restorelist").status == 200

    put = put_archive("restorelist", "cold.txt", "cold bytes")
    [version_id] = get_resp_header(put, "x-amz-version-id")

    restore =
      SigV4Request.signed_conn(:post, "/restorelist/cold.txt",
        query: %{"restore" => "", "versionId" => version_id},
        body: restore_xml()
      )
      |> call()

    assert restore.status == 202

    default =
      SigV4Request.signed_conn(:get, "/restorelist", query: %{"list-type" => "2"})
      |> call()

    assert default.status == 200
    refute default.resp_body =~ "<RestoreStatus>"

    v2 =
      SigV4Request.signed_conn(:get, "/restorelist",
        query: %{"list-type" => "2"},
        headers: [{"x-amz-optional-object-attributes", "RestoreStatus"}]
      )
      |> call()

    assert v2.status == 200
    assert v2.resp_body =~ "<RestoreStatus>"
    assert v2.resp_body =~ "<IsRestoreInProgress>false</IsRestoreInProgress>"
    assert v2.resp_body =~ "<RestoreExpiryDate>"

    v1 =
      SigV4Request.signed_conn(:get, "/restorelist",
        headers: [{"x-amz-optional-object-attributes", "RestoreStatus"}]
      )
      |> call()

    assert v1.status == 200
    assert v1.resp_body =~ "<RestoreStatus>"

    versions =
      SigV4Request.signed_conn(:get, "/restorelist",
        query: %{"versions" => ""},
        headers: [{"x-amz-optional-object-attributes", "RestoreStatus"}]
      )
      |> call()

    assert versions.status == 200
    assert versions.resp_body =~ "<VersionId>#{version_id}</VersionId>"
    assert versions.resp_body =~ "<RestoreStatus>"

    invalid =
      SigV4Request.signed_conn(:get, "/restorelist",
        query: %{"list-type" => "2"},
        headers: [{"x-amz-optional-object-attributes", "Checksum"}]
      )
      |> call()

    assert invalid.status == 400
    assert invalid.resp_body =~ "<Code>InvalidArgument</Code>"
  end

  test "sidecar list authority includes optional RestoreStatus from sidecar metadata" do
    SigV4Request.signed_conn(:put, "/restorelistsidecar") |> call()
    put_archive("restorelistsidecar", "cold.txt", "cold bytes")

    restore =
      SigV4Request.signed_conn(:post, "/restorelistsidecar/cold.txt",
        query: %{"restore" => ""},
        body: restore_xml()
      )
      |> call()

    assert restore.status == 202

    {:ok, object} = Objects.get_metadata("restorelistsidecar", "cold.txt")

    {:ok, _pg_only} =
      Objects.put_restore_state("restorelistsidecar", "cold.txt", object.version_id, %{
        restore_status: nil,
        restore_expiry: nil
      })

    Application.put_env(:maxio, :authoritative_source, read: :pg, list: :sidecar, write: :pg)

    list =
      SigV4Request.signed_conn(:get, "/restorelistsidecar",
        query: %{"list-type" => "2"},
        headers: [{"x-amz-optional-object-attributes", "RestoreStatus"}]
      )
      |> call()

    assert list.status == 200
    assert list.resp_body =~ "<Key>cold.txt</Key>"
    assert list.resp_body =~ "<RestoreStatus>"

    versions =
      SigV4Request.signed_conn(:get, "/restorelistsidecar",
        query: %{"versions" => ""},
        headers: [{"x-amz-optional-object-attributes", "RestoreStatus"}]
      )
      |> call()

    assert versions.status == 200
    assert versions.resp_body =~ "<Key>cold.txt</Key>"
    assert versions.resp_body =~ "<RestoreStatus>"
  end

  test "restore expiry runner clears due restored copies without touching extended restores" do
    SigV4Request.signed_conn(:put, "/restoreexpire") |> call()
    put_archive("restoreexpire", "cold.txt", "cold bytes")
    put_archive("restoreexpire", "fresh.txt", "fresh bytes")

    assert (SigV4Request.signed_conn(:post, "/restoreexpire/cold.txt",
              query: %{"restore" => ""},
              body: restore_xml()
            )
            |> call()).status == 202

    assert (SigV4Request.signed_conn(:post, "/restoreexpire/fresh.txt",
              query: %{"restore" => ""},
              body: restore_xml()
            )
            |> call()).status == 202

    past = ~U[2026-06-01 00:00:00Z]
    now = ~U[2026-06-28 00:00:00Z]
    future = ~U[2026-07-01 00:00:00Z]

    {:ok, cold} = Objects.get_metadata("restoreexpire", "cold.txt")

    {:ok, _cold} =
      Objects.put_restore_state("restoreexpire", "cold.txt", cold.version_id, %{
        restore_status: "restored",
        restore_expiry: past
      })

    {:ok, fresh} = Objects.get_metadata("restoreexpire", "fresh.txt")
    stale_candidate = %{fresh | restore_expiry: past}

    {:ok, _fresh} =
      Objects.put_restore_state("restoreexpire", "fresh.txt", fresh.version_id, %{
        restore_status: "restored",
        restore_expiry: future
      })

    assert :stale = Objects.expire_restore_state(stale_candidate, now)

    summary = RestoreExpiry.run(bucket: "restoreexpire", now: now)
    assert %{scanned: 1, expired: 1, stale: 0, failed: 0} = summary

    {:ok, expired} = Objects.get_metadata("restoreexpire", "cold.txt")
    assert expired.restore_status == nil
    assert expired.restore_expiry == nil

    {:ok, still_restored} = Objects.get_metadata("restoreexpire", "fresh.txt")
    assert still_restored.restore_status == "restored"
    assert DateTime.compare(still_restored.restore_expiry, future) == :eq

    get = SigV4Request.signed_conn(:get, "/restoreexpire/cold.txt") |> call()
    assert get.status == 403
    assert get.resp_body =~ "<Code>InvalidObjectState</Code>"
  end

  test "RestoreObject rejects non archive storage classes" do
    SigV4Request.signed_conn(:put, "/restorestd") |> call()
    SigV4Request.signed_conn(:put, "/restorestd/std.txt", body: "plain") |> call()

    xml = ~s(<RestoreRequest><Days>1</Days></RestoreRequest>)

    restore =
      SigV4Request.signed_conn(:post, "/restorestd/std.txt",
        query: %{"restore" => ""},
        body: xml
      )
      |> call()

    assert restore.status == 403
    assert restore.resp_body =~ "<Code>InvalidObjectState</Code>"
  end

  test "RestoreObject select restore writes query output without mutating source restore state" do
    SigV4Request.signed_conn(:put, "/restoreselect") |> call()
    SigV4Request.signed_conn(:put, "/restoreselectout") |> call()

    SigV4Request.signed_conn(:put, "/restoreselect/cold.txt",
      body: "Ada,keep\nBob,drop\n",
      headers: [{"x-amz-storage-class", "DEEP_ARCHIVE"}]
    )
    |> call()

    xml =
      select_restore_xml(
        "restoreselectout",
        "results",
        "SELECT _1 FROM S3Object WHERE _2 = 'keep'"
      )

    restore =
      SigV4Request.signed_conn(:post, "/restoreselect/cold.txt",
        query: %{"restore" => ""},
        body: xml
      )
      |> call()

    assert restore.status == 200
    {output_prefix, output_key} = select_output_prefix_and_key(restore)
    assert String.starts_with?(output_prefix, "results/")
    assert String.ends_with?(output_prefix, "/")
    assert output_key == output_prefix <> "part-00000"

    {:ok, object} = Objects.get_metadata("restoreselect", "cold.txt")
    assert object.restore_status == nil

    output =
      SigV4Request.signed_conn(:get, "/restoreselectout/#{output_key}")
      |> call()

    assert output.status == 200
    assert output.resp_body == "Ada\n"
    assert get_resp_header(output, "content-type") == ["text/csv"]
  end

  test "RestoreObject select restore additionally requires source GetObject permission" do
    source_bucket = "restoreselectreadz"
    output_bucket = "restoreselectreadzout"

    SigV4Request.signed_conn(:put, "/#{source_bucket}") |> call()
    SigV4Request.signed_conn(:put, "/#{output_bucket}") |> call()

    SigV4Request.signed_conn(:put, "/#{source_bucket}/cold.txt",
      body: "Ada,keep\n",
      headers: [{"x-amz-storage-class", "GLACIER"}]
    )
    |> call()

    base_policy = %{
      "Version" => "2012-10-17",
      "Statement" => [
        %{
          "Effect" => "Allow",
          "Action" => "s3:RestoreObject",
          "Resource" => "arn:aws:s3:::#{source_bucket}/cold.txt"
        },
        %{
          "Effect" => "Allow",
          "Action" => "s3:PutObject",
          "Resource" => "arn:aws:s3:::#{output_bucket}/results/*"
        }
      ]
    }

    put_alice_policy("restore-select-source-read", base_policy)

    xml =
      select_restore_xml(
        output_bucket,
        "results",
        "SELECT _1 FROM S3Object WHERE _2 = 'keep'"
      )

    denied =
      alice(:post, "/#{source_bucket}/cold.txt", query: %{"restore" => ""}, body: xml)
      |> call()

    assert denied.status == 403
    assert denied.resp_body =~ "<Code>AccessDenied</Code>"
    assert get_resp_header(denied, "x-amz-restore-output-path") == []

    allowed_policy =
      update_in(base_policy, ["Statement"], fn statements ->
        statements ++
          [
            %{
              "Effect" => "Allow",
              "Action" => "s3:GetObject",
              "Resource" => "arn:aws:s3:::#{source_bucket}/cold.txt"
            }
          ]
      end)

    put_alice_policy("restore-select-source-read", allowed_policy)

    allowed =
      alice(:post, "/#{source_bucket}/cold.txt", query: %{"restore" => ""}, body: xml)
      |> call()

    assert allowed.status == 200
    {output_prefix, output_key} = select_output_prefix_and_key(allowed)
    assert String.ends_with?(output_prefix, "/")
    assert {:ok, _written} = Objects.get_metadata(output_bucket, output_key)
  end

  test "RestoreObject select restore enforces Requester Pays on source and output buckets" do
    source_bucket = "restoreselectpayer"
    output_bucket = "restoreselectpayerout"

    SigV4Request.signed_conn(:put, "/#{source_bucket}") |> call()
    SigV4Request.signed_conn(:put, "/#{output_bucket}") |> call()
    assert put_request_payment(source_bucket).status == 200
    assert put_request_payment(output_bucket).status == 200

    SigV4Request.signed_conn(:put, "/#{source_bucket}/cold.txt",
      body: "Ada,keep\nBob,drop\n",
      headers: [{"x-amz-storage-class", "GLACIER"}]
    )
    |> call()

    put_alice_policy("restore-select-requester-pays", %{
      "Version" => "2012-10-17",
      "Statement" => [
        %{
          "Effect" => "Allow",
          "Action" => "s3:RestoreObject",
          "Resource" => "arn:aws:s3:::#{source_bucket}/cold.txt"
        },
        %{
          "Effect" => "Allow",
          "Action" => "s3:GetObject",
          "Resource" => "arn:aws:s3:::#{source_bucket}/cold.txt"
        },
        %{
          "Effect" => "Allow",
          "Action" => "s3:PutObject",
          "Resource" => "arn:aws:s3:::#{output_bucket}/results/*"
        }
      ]
    })

    xml =
      select_restore_xml(
        output_bucket,
        "results",
        "SELECT _1 FROM S3Object WHERE _2 = 'keep'"
      )

    denied =
      alice(:post, "/#{source_bucket}/cold.txt", query: %{"restore" => ""}, body: xml)
      |> call()

    assert denied.status == 403
    assert denied.resp_body =~ "<Code>AccessDenied</Code>"
    assert get_resp_header(denied, "x-amz-restore-output-path") == []
    assert_restore_status(source_bucket, "cold.txt", nil)

    allowed =
      alice(:post, "/#{source_bucket}/cold.txt",
        query: %{"restore" => ""},
        body: xml,
        headers: [{"x-amz-request-payer", "requester"}]
      )
      |> call()

    assert allowed.status == 200
    assert get_resp_header(allowed, "x-amz-request-charged") == ["requester"]
    {_output_prefix, output_key} = select_output_prefix_and_key(allowed)

    output = SigV4Request.signed_conn(:get, "/#{output_bucket}/#{output_key}") |> call()
    assert output.status == 200
    assert output.resp_body == "Ada\n"
    assert_restore_status(source_bucket, "cold.txt", nil)
  end

  test "RestoreObject select restore independently enforces Requester Pays on output bucket" do
    source_bucket = "restoreselectoutpayer"
    output_bucket = "restoreselectoutpayerout"

    SigV4Request.signed_conn(:put, "/#{source_bucket}") |> call()
    SigV4Request.signed_conn(:put, "/#{output_bucket}") |> call()
    assert put_request_payment(output_bucket).status == 200

    SigV4Request.signed_conn(:put, "/#{source_bucket}/cold.txt",
      body: "Ada,keep\nBob,drop\n",
      headers: [{"x-amz-storage-class", "GLACIER"}]
    )
    |> call()

    put_alice_policy("restore-select-output-requester-pays", %{
      "Version" => "2012-10-17",
      "Statement" => [
        %{
          "Effect" => "Allow",
          "Action" => "s3:RestoreObject",
          "Resource" => "arn:aws:s3:::#{source_bucket}/cold.txt"
        },
        %{
          "Effect" => "Allow",
          "Action" => "s3:GetObject",
          "Resource" => "arn:aws:s3:::#{source_bucket}/cold.txt"
        },
        %{
          "Effect" => "Allow",
          "Action" => "s3:PutObject",
          "Resource" => "arn:aws:s3:::#{output_bucket}/results/*"
        }
      ]
    })

    xml =
      select_restore_xml(
        output_bucket,
        "results",
        "SELECT _1 FROM S3Object WHERE _2 = 'keep'"
      )

    denied =
      alice(:post, "/#{source_bucket}/cold.txt", query: %{"restore" => ""}, body: xml)
      |> call()

    assert denied.status == 403
    assert denied.resp_body =~ "<Code>AccessDenied</Code>"
    assert get_resp_header(denied, "x-amz-restore-output-path") == []
    assert_restore_status(source_bucket, "cold.txt", nil)

    empty_output =
      SigV4Request.signed_conn(:get, "/#{output_bucket}", query: %{"list-type" => "2"})
      |> call()

    assert empty_output.status == 200
    refute empty_output.resp_body =~ "<Key>results/"

    allowed =
      alice(:post, "/#{source_bucket}/cold.txt",
        query: %{"restore" => ""},
        body: xml,
        headers: [{"x-amz-request-payer", "requester"}]
      )
      |> call()

    assert allowed.status == 200
    assert get_resp_header(allowed, "x-amz-request-charged") == ["requester"]
    {_output_prefix, output_key} = select_output_prefix_and_key(allowed)

    output = SigV4Request.signed_conn(:get, "/#{output_bucket}/#{output_key}") |> call()
    assert output.status == 200
    assert output.resp_body == "Ada\n"
    assert_restore_status(source_bucket, "cold.txt", nil)
  end

  test "RestoreObject select restore rejects empty output access control list before writing" do
    SigV4Request.signed_conn(:put, "/restoreselectunsupported") |> call()
    SigV4Request.signed_conn(:put, "/restoreselectunsupportedout") |> call()

    SigV4Request.signed_conn(:put, "/restoreselectunsupported/cold.txt",
      body: "Ada,keep\n",
      headers: [{"x-amz-storage-class", "GLACIER"}]
    )
    |> call()

    xml =
      select_restore_xml(
        "restoreselectunsupportedout",
        "results",
        "SELECT * FROM S3Object",
        "<AccessControlList></AccessControlList>"
      )

    restore =
      SigV4Request.signed_conn(:post, "/restoreselectunsupported/cold.txt",
        query: %{"restore" => ""},
        body: xml
      )
      |> call()

    assert restore.status == 400
    assert restore.resp_body =~ "<Code>MalformedXML</Code>"
    assert get_resp_header(restore, "x-amz-restore-output-path") == []

    {:ok, object} = Objects.get_metadata("restoreselectunsupported", "cold.txt")
    assert object.restore_status == nil
  end

  test "RestoreObject select restore rejects invalid output access control list grants" do
    SigV4Request.signed_conn(:put, "/restoreselectbadgrant") |> call()
    assert create_object_writer_bucket("restoreselectbadgrantout").status == 200

    SigV4Request.signed_conn(:put, "/restoreselectbadgrant/cold.txt",
      body: "Ada,keep\n",
      headers: [{"x-amz-storage-class", "GLACIER"}]
    )
    |> call()

    xml =
      select_restore_xml(
        "restoreselectbadgrantout",
        "results",
        "SELECT * FROM S3Object",
        """
        <AccessControlList>
          <Grant>
            <Grantee xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:type="Group">
              <URI>http://example.com/not-an-s3-group</URI>
            </Grantee>
            <Permission>READ</Permission>
          </Grant>
        </AccessControlList>
        """
      )

    restore =
      SigV4Request.signed_conn(:post, "/restoreselectbadgrant/cold.txt",
        query: %{"restore" => ""},
        body: xml
      )
      |> call()

    assert restore.status == 400
    assert restore.resp_body =~ "<Code>MalformedXML</Code>"
    assert get_resp_header(restore, "x-amz-restore-output-path") == []

    {:ok, object} = Objects.get_metadata("restoreselectbadgrant", "cold.txt")
    assert object.restore_status == nil
  end

  test "RestoreObject select restore honors target bucket default encryption" do
    SigV4Request.signed_conn(:put, "/restoreselectsse") |> call()
    SigV4Request.signed_conn(:put, "/restoreselectsseout") |> call()
    assert put_bucket_encryption("restoreselectsseout").status == 200

    SigV4Request.signed_conn(:put, "/restoreselectsse/cold.txt",
      body: "Ada,keep\n",
      headers: [{"x-amz-storage-class", "DEEP_ARCHIVE"}]
    )
    |> call()

    restore =
      SigV4Request.signed_conn(:post, "/restoreselectsse/cold.txt",
        query: %{"restore" => ""},
        body:
          select_restore_xml(
            "restoreselectsseout",
            "results",
            "SELECT * FROM S3Object"
          )
      )
      |> call()

    assert restore.status == 200
    {_output_prefix, output_key} = select_output_prefix_and_key(restore)

    output =
      SigV4Request.signed_conn(:get, "/restoreselectsseout/#{output_key}")
      |> call()

    assert output.status == 200
    assert output.resp_body == "Ada,keep\n"
    assert get_resp_header(output, "x-amz-server-side-encryption") == ["AES256"]

    {:ok, source} = Objects.get_metadata("restoreselectsse", "cold.txt")
    assert source.restore_status == nil

    {:ok, written} = Objects.get_metadata("restoreselectsseout", output_key)
    assert written.size == byte_size("Ada,keep\n")
    assert written.sse_algorithm == "AES256"
    assert is_map(written.sse_envelope)
  end

  test "RestoreObject select restore applies output encryption tags metadata and canned ACL" do
    SigV4Request.signed_conn(:put, "/restoreselectattrs") |> call()
    SigV4Request.signed_conn(:put, "/restoreselectattrsout") |> call()

    SigV4Request.signed_conn(:put, "/restoreselectattrs/cold.txt",
      body: "Ada,keep\nBob,drop\n",
      headers: [{"x-amz-storage-class", "GLACIER"}]
    )
    |> call()

    context = %{"restore" => "select"} |> Jason.encode!() |> Base.encode64()

    xml =
      select_restore_xml(
        "restoreselectattrsout",
        "results",
        "SELECT _1 FROM S3Object WHERE _2 = 'keep'",
        """
        <CannedACL>bucket-owner-full-control</CannedACL>
        <Tagging>
          <TagSet>
            <Tag><Key>job</Key><Value>restore</Value></Tag>
          </TagSet>
        </Tagging>
        <UserMetadata>
          <MetadataEntry><Name>Trace</Name><Value>restore-42</Value></MetadataEntry>
        </UserMetadata>
        <Encryption>
          <EncryptionType>aws:kms</EncryptionType>
          <KMSKeyId>restore-output-key</KMSKeyId>
          <KMSContext>#{context}</KMSContext>
        </Encryption>
        """
      )

    restore =
      SigV4Request.signed_conn(:post, "/restoreselectattrs/cold.txt",
        query: %{"restore" => ""},
        body: xml
      )
      |> call()

    assert restore.status == 200
    {_output_prefix, output_key} = select_output_prefix_and_key(restore)

    output =
      SigV4Request.signed_conn(:get, "/restoreselectattrsout/#{output_key}")
      |> call()

    assert output.status == 200
    assert output.resp_body == "Ada\n"
    assert get_resp_header(output, "x-amz-server-side-encryption") == ["aws:kms"]

    assert get_resp_header(output, "x-amz-server-side-encryption-aws-kms-key-id") == [
             "restore-output-key"
           ]

    assert get_resp_header(output, "x-amz-meta-trace") == ["restore-42"]
    assert get_resp_header(output, "x-amz-tagging-count") == ["1"]

    tags =
      SigV4Request.signed_conn(:get, "/restoreselectattrsout/#{output_key}",
        query: %{"tagging" => ""}
      )
      |> call()

    assert tags.status == 200
    assert tags.resp_body =~ "<Key>job</Key>"
    assert tags.resp_body =~ "<Value>restore</Value>"

    {:ok, written} = Objects.get_metadata("restoreselectattrsout", output_key)
    assert written.size == byte_size("Ada\n")
    assert written.metadata == %{"trace" => "restore-42"}
    assert written.tags == %{"job" => "restore"}
    assert written.acl_canned == "bucket-owner-full-control"
    assert written.sse_algorithm == "aws:kms"
    assert written.sse_envelope["kms_key_id"] == "restore-output-key"
    assert written.sse_envelope["kms_encryption_context_b64"] == context
  end

  test "RestoreObject select restore authorizes output XML attributes as target PutObject conditions" do
    source_bucket = "restoreselectauthz"
    output_bucket = "restoreselectauthzout"

    SigV4Request.signed_conn(:put, "/#{source_bucket}") |> call()
    SigV4Request.signed_conn(:put, "/#{output_bucket}") |> call()

    SigV4Request.signed_conn(:put, "/#{source_bucket}/cold.txt",
      body: "Ada,finance\nBob,engineering\n",
      headers: [{"x-amz-storage-class", "GLACIER"}]
    )
    |> call()

    put_alice_policy(
      "restore-select-output-conditions",
      %{
        "Version" => "2012-10-17",
        "Statement" => [
          %{
            "Effect" => "Allow",
            "Action" => "s3:RestoreObject",
            "Resource" => "arn:aws:s3:::#{source_bucket}/cold.txt"
          },
          %{
            "Effect" => "Allow",
            "Action" => "s3:GetObject",
            "Resource" => "arn:aws:s3:::#{source_bucket}/cold.txt"
          },
          %{
            "Effect" => "Allow",
            "Action" => "s3:PutObject",
            "Resource" => "arn:aws:s3:::#{output_bucket}/results/*",
            "Condition" => %{
              "StringEquals" => %{
                "s3:x-amz-server-side-encryption" => "aws:kms",
                "s3:RequestObjectTag/department" => "finance"
              }
            }
          },
          %{
            "Effect" => "Allow",
            "Action" => "s3:PutObjectTagging",
            "Resource" => "arn:aws:s3:::#{output_bucket}/results/*",
            "Condition" => %{
              "StringEquals" => %{"s3:RequestObjectTag/department" => "finance"}
            }
          }
        ]
      }
    )

    xml =
      select_restore_xml(
        output_bucket,
        "results",
        "SELECT _1 FROM S3Object WHERE _2 = 'finance'",
        """
        <Tagging>
          <TagSet>
            <Tag><Key>department</Key><Value>finance</Value></Tag>
          </TagSet>
        </Tagging>
        <Encryption>
          <EncryptionType>aws:kms</EncryptionType>
          <KMSKeyId>restore-authz-key</KMSKeyId>
        </Encryption>
        """
      )

    restore =
      alice(:post, "/#{source_bucket}/cold.txt",
        query: %{"restore" => ""},
        body: xml,
        headers: [{"x-amz-tagging", "department=engineering"}]
      )
      |> call()

    assert restore.status == 200
    {_output_prefix, output_key} = select_output_prefix_and_key(restore)

    output = SigV4Request.signed_conn(:get, "/#{output_bucket}/#{output_key}") |> call()
    assert output.status == 200
    assert output.resp_body == "Ada\n"
    assert get_resp_header(output, "x-amz-server-side-encryption") == ["aws:kms"]
    assert get_resp_header(output, "x-amz-tagging-count") == ["1"]
  end

  test "RestoreObject select restore explicit CannedACL requires target PutObjectAcl permission" do
    source_bucket = "restoreselectaclz"
    output_bucket = "restoreselectaclzout"

    SigV4Request.signed_conn(:put, "/#{source_bucket}") |> call()
    assert create_object_writer_bucket(output_bucket).status == 200

    SigV4Request.signed_conn(:put, "/#{source_bucket}/cold.txt",
      body: "Ada,keep\n",
      headers: [{"x-amz-storage-class", "GLACIER"}]
    )
    |> call()

    base_policy = %{
      "Version" => "2012-10-17",
      "Statement" => [
        %{
          "Effect" => "Allow",
          "Action" => "s3:RestoreObject",
          "Resource" => "arn:aws:s3:::#{source_bucket}/cold.txt"
        },
        %{
          "Effect" => "Allow",
          "Action" => "s3:GetObject",
          "Resource" => "arn:aws:s3:::#{source_bucket}/cold.txt"
        },
        %{
          "Effect" => "Allow",
          "Action" => "s3:PutObject",
          "Resource" => "arn:aws:s3:::#{output_bucket}/results/*"
        }
      ]
    }

    put_alice_policy("restore-select-output-acl", base_policy)

    xml =
      select_restore_xml(
        output_bucket,
        "results",
        "SELECT * FROM S3Object",
        "<CannedACL>bucket-owner-full-control</CannedACL>"
      )

    denied =
      alice(:post, "/#{source_bucket}/cold.txt", query: %{"restore" => ""}, body: xml)
      |> call()

    assert denied.status == 403
    assert get_resp_header(denied, "x-amz-restore-output-path") == []

    allowed_policy =
      update_in(base_policy, ["Statement"], fn statements ->
        statements ++
          [
            %{
              "Effect" => "Allow",
              "Action" => "s3:PutObjectAcl",
              "Resource" => "arn:aws:s3:::#{output_bucket}/results/*"
            }
          ]
      end)

    put_alice_policy("restore-select-output-acl", allowed_policy)

    allowed =
      alice(:post, "/#{source_bucket}/cold.txt", query: %{"restore" => ""}, body: xml)
      |> call()

    assert allowed.status == 200
    assert [output_prefix] = get_resp_header(allowed, "x-amz-restore-output-path")
    assert String.ends_with?(output_prefix, "/")
  end

  test "RestoreObject select restore applies output access control list grants" do
    source_bucket = "restoreselectgrants"
    output_bucket = "restoreselectgrantsout"

    SigV4Request.signed_conn(:put, "/#{source_bucket}") |> call()
    assert create_object_writer_bucket(output_bucket).status == 200

    SigV4Request.signed_conn(:put, "/#{source_bucket}/cold.txt",
      body: "Ada,keep\nBob,drop\n",
      headers: [{"x-amz-storage-class", "GLACIER"}]
    )
    |> call()

    xml =
      select_restore_xml(
        output_bucket,
        "results",
        "SELECT _1 FROM S3Object WHERE _2 = 'keep'",
        """
        <AccessControlList>
          <Grant>
            <Grantee xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:type="Group">
              <URI>http://acs.amazonaws.com/groups/global/AllUsers</URI>
            </Grantee>
            <Permission>READ</Permission>
          </Grant>
        </AccessControlList>
        """
      )

    restore =
      SigV4Request.signed_conn(:post, "/#{source_bucket}/cold.txt",
        query: %{"restore" => ""},
        body: xml
      )
      |> call()

    assert restore.status == 200
    {_output_prefix, output_key} = select_output_prefix_and_key(restore)

    acl =
      SigV4Request.signed_conn(:get, "/#{output_bucket}/#{output_key}", query: %{"acl" => ""})
      |> call()

    assert acl.status == 200
    assert acl.resp_body =~ ~s(xsi:type="Group")
    assert acl.resp_body =~ "http://acs.amazonaws.com/groups/global/AllUsers"
    assert acl.resp_body =~ "<Permission>READ</Permission>"

    anon = SigV4Request.anon_conn(:get, "/#{output_bucket}/#{output_key}") |> call()
    assert anon.status == 200
    assert anon.resp_body == "Ada\n"

    {:ok, written} = Objects.get_metadata(output_bucket, output_key)
    assert written.acl_canned == "public-read"
    assert [%{"permission" => "READ"}] = written.acl_grants["grants"]

    {:ok, source} = Objects.get_metadata(source_bucket, "cold.txt")
    assert source.restore_status == nil
  end

  test "RestoreObject select restore access control list requires target PutObjectAcl permission" do
    source_bucket = "restoreselectgrantz"
    output_bucket = "restoreselectgrantzout"

    SigV4Request.signed_conn(:put, "/#{source_bucket}") |> call()
    assert create_object_writer_bucket(output_bucket).status == 200

    SigV4Request.signed_conn(:put, "/#{source_bucket}/cold.txt",
      body: "Ada,keep\n",
      headers: [{"x-amz-storage-class", "GLACIER"}]
    )
    |> call()

    base_policy = %{
      "Version" => "2012-10-17",
      "Statement" => [
        %{
          "Effect" => "Allow",
          "Action" => "s3:RestoreObject",
          "Resource" => "arn:aws:s3:::#{source_bucket}/cold.txt"
        },
        %{
          "Effect" => "Allow",
          "Action" => "s3:GetObject",
          "Resource" => "arn:aws:s3:::#{source_bucket}/cold.txt"
        },
        %{
          "Effect" => "Allow",
          "Action" => "s3:PutObject",
          "Resource" => "arn:aws:s3:::#{output_bucket}/results/*"
        }
      ]
    }

    put_alice_policy("restore-select-output-grants", base_policy)

    xml =
      select_restore_xml(
        output_bucket,
        "results",
        "SELECT * FROM S3Object",
        """
        <AccessControlList>
          <Grant>
            <Grantee xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:type="Group">
              <URI>http://acs.amazonaws.com/groups/global/AllUsers</URI>
            </Grantee>
            <Permission>READ</Permission>
          </Grant>
        </AccessControlList>
        """
      )

    denied =
      alice(:post, "/#{source_bucket}/cold.txt", query: %{"restore" => ""}, body: xml)
      |> call()

    assert denied.status == 403
    assert get_resp_header(denied, "x-amz-restore-output-path") == []

    allowed_policy =
      update_in(base_policy, ["Statement"], fn statements ->
        statements ++
          [
            %{
              "Effect" => "Allow",
              "Action" => "s3:PutObjectAcl",
              "Resource" => "arn:aws:s3:::#{output_bucket}/results/*",
              "Condition" => %{
                "StringEquals" => %{
                  "s3:x-amz-grant-read" =>
                    ~s(uri="http://acs.amazonaws.com/groups/global/AllUsers")
                }
              }
            }
          ]
      end)

    put_alice_policy("restore-select-output-grants", allowed_policy)

    allowed =
      alice(:post, "/#{source_bucket}/cold.txt", query: %{"restore" => ""}, body: xml)
      |> call()

    assert allowed.status == 200
    {_output_prefix, output_key} = select_output_prefix_and_key(allowed)

    {:ok, written} = Objects.get_metadata(output_bucket, output_key)
    assert written.acl_canned == "public-read"
  end

  test "RestoreObject select restore output access control list obeys bucket owner enforced rules" do
    source_bucket = "restoreselectboe"
    output_bucket = "restoreselectboeout"

    SigV4Request.signed_conn(:put, "/#{source_bucket}") |> call()
    SigV4Request.signed_conn(:put, "/#{output_bucket}") |> call()

    SigV4Request.signed_conn(:put, "/#{source_bucket}/cold.txt",
      body: "Ada,keep\n",
      headers: [{"x-amz-storage-class", "GLACIER"}]
    )
    |> call()

    public_xml =
      select_restore_xml(
        output_bucket,
        "results",
        "SELECT * FROM S3Object",
        """
        <AccessControlList>
          <Grant>
            <Grantee xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:type="Group">
              <URI>http://acs.amazonaws.com/groups/global/AllUsers</URI>
            </Grantee>
            <Permission>READ</Permission>
          </Grant>
        </AccessControlList>
        """
      )

    rejected =
      SigV4Request.signed_conn(:post, "/#{source_bucket}/cold.txt",
        query: %{"restore" => ""},
        body: public_xml
      )
      |> call()

    assert rejected.status == 400
    assert rejected.resp_body =~ "<Code>AccessControlListNotSupported</Code>"
    assert get_resp_header(rejected, "x-amz-restore-output-path") == []

    owner_xml =
      select_restore_xml(
        output_bucket,
        "results",
        "SELECT * FROM S3Object",
        """
        <AccessControlList>
          <Grant>
            <Grantee xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:type="CanonicalUser">
              <ID>maxio</ID>
            </Grantee>
            <Permission>FULL_CONTROL</Permission>
          </Grant>
        </AccessControlList>
        """
      )

    allowed =
      SigV4Request.signed_conn(:post, "/#{source_bucket}/cold.txt",
        query: %{"restore" => ""},
        body: owner_xml
      )
      |> call()

    assert allowed.status == 200
    {_output_prefix, output_key} = select_output_prefix_and_key(allowed)

    {:ok, written} = Objects.get_metadata(output_bucket, output_key)
    assert written.acl_canned == "private"
    assert written.acl_grants == %{"grants" => []}
  end

  test "RestoreObject select restore output access control list obeys BlockPublicAcls" do
    source_bucket = "restoreselectpab"
    output_bucket = "restoreselectpabout"

    SigV4Request.signed_conn(:put, "/#{source_bucket}") |> call()
    assert create_object_writer_bucket(output_bucket).status == 200
    assert put_public_access_block(output_bucket, %{"BlockPublicAcls" => true}).status == 200

    SigV4Request.signed_conn(:put, "/#{source_bucket}/cold.txt",
      body: "Ada,keep\n",
      headers: [{"x-amz-storage-class", "GLACIER"}]
    )
    |> call()

    xml =
      select_restore_xml(
        output_bucket,
        "results",
        "SELECT * FROM S3Object",
        """
        <AccessControlList>
          <Grant>
            <Grantee xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:type="Group">
              <URI>http://acs.amazonaws.com/groups/global/AllUsers</URI>
            </Grantee>
            <Permission>READ</Permission>
          </Grant>
        </AccessControlList>
        """
      )

    restore =
      SigV4Request.signed_conn(:post, "/#{source_bucket}/cold.txt",
        query: %{"restore" => ""},
        body: xml
      )
      |> call()

    assert restore.status == 403
    assert restore.resp_body =~ "<Code>AccessDenied</Code>"
    assert get_resp_header(restore, "x-amz-restore-output-path") == []
  end

  test "RestoreObject select restore output is visible under sidecar write authority" do
    SigV4Request.signed_conn(:put, "/restoreselectsidecar") |> call()
    SigV4Request.signed_conn(:put, "/restoreselectsidecarout") |> call()

    SigV4Request.signed_conn(:put, "/restoreselectsidecar/cold.txt",
      body: "Ada,keep\nBob,drop\n",
      headers: [{"x-amz-storage-class", "GLACIER"}]
    )
    |> call()

    Application.put_env(:maxio, :authoritative_source,
      read: :sidecar,
      list: :sidecar,
      write: :sidecar
    )

    restore =
      SigV4Request.signed_conn(:post, "/restoreselectsidecar/cold.txt",
        query: %{"restore" => ""},
        body:
          select_restore_xml(
            "restoreselectsidecarout",
            "results",
            "SELECT _1 FROM S3Object WHERE _2 = 'keep'"
          )
      )
      |> call()

    assert restore.status == 200
    {_output_prefix, output_key} = select_output_prefix_and_key(restore)

    output =
      SigV4Request.signed_conn(:get, "/restoreselectsidecarout/#{output_key}")
      |> call()

    assert output.status == 200
    assert output.resp_body == "Ada\n"

    list =
      SigV4Request.signed_conn(:get, "/restoreselectsidecarout", query: %{"list-type" => "2"})
      |> call()

    assert list.status == 200
    assert list.resp_body =~ "<Key>#{output_key}</Key>"
  end

  test "RestoreObject expected bucket owner is enforced before metadata update" do
    SigV4Request.signed_conn(:put, "/restoreowner") |> call()
    put_archive("restoreowner", "cold.txt", "cold bytes")

    restore =
      SigV4Request.signed_conn(:post, "/restoreowner/cold.txt",
        query: %{"restore" => ""},
        body: restore_xml(),
        headers: [{"x-amz-expected-bucket-owner", "999999999999"}]
      )
      |> call()

    assert restore.status == 403
    assert_restore_status("restoreowner", "cold.txt", nil)
  end

  test "RestoreObject checksum trailers and aws-chunked XML bodies are validated before metadata update" do
    SigV4Request.signed_conn(:put, "/restorechunked") |> call()

    put_archive("restorechunked", "cold.txt", "cold bytes")

    xml =
      ~s(<RestoreRequest><Days>3</Days><GlacierJobParameters><Tier>Standard</Tier></GlacierJobParameters></RestoreRequest>)

    plain_trailer =
      SigV4Request.signed_conn(:post, "/restorechunked/cold.txt",
        query: %{"restore" => ""},
        body: xml,
        headers: [
          {"x-amz-sdk-checksum-algorithm", "SHA256"},
          {"x-amz-trailer", "x-amz-checksum-sha256"}
        ]
      )
      |> call()

    assert plain_trailer.status == 400
    assert plain_trailer.resp_body =~ "InvalidRequest"
    assert_restore_status("restorechunked", "cold.txt", nil)

    bad =
      SigV4Request.signed_chunked_conn(:post, "/restorechunked/cold.txt", xml,
        query: %{"restore" => ""},
        headers: [{"x-amz-sdk-checksum-algorithm", "SHA256"}],
        trailer_headers: [{"x-amz-checksum-sha256", content_sha256("different")}]
      )
      |> call()

    assert bad.status == 400
    assert bad.resp_body =~ "BadDigest"
    assert_restore_status("restorechunked", "cold.txt", nil)

    ok_trailer =
      SigV4Request.signed_chunked_conn(:post, "/restorechunked/cold.txt", xml,
        query: %{"restore" => ""},
        headers: [{"x-amz-sdk-checksum-algorithm", "SHA256"}],
        trailer_headers: [{"x-amz-checksum-sha256", content_sha256(xml)}]
      )
      |> call()

    assert ok_trailer.status == 202
    assert_restore_status("restorechunked", "cold.txt", "restored")

    signed_trailer =
      SigV4Request.signed_chunked_conn(:post, "/restorechunked/cold.txt", xml,
        query: %{"restore" => ""},
        headers: [{"x-amz-sdk-checksum-algorithm", "SHA256"}],
        trailer_headers: [{"x-amz-checksum-sha256", content_sha256(xml)}],
        streaming_payload_hash: "STREAMING-AWS4-HMAC-SHA256-PAYLOAD-TRAILER"
      )
      |> call()

    assert signed_trailer.status == 200

    put_archive("restorechunked", "plain.txt", "plain cold bytes")

    ok_chunked =
      SigV4Request.signed_chunked_conn(:post, "/restorechunked/plain.txt", xml,
        query: %{"restore" => ""}
      )
      |> call()

    assert ok_chunked.status == 202
    assert_restore_status("restorechunked", "plain.txt", "restored")

    put_archive("restorechunked", "huge.txt", "huge cold bytes")
    oversized = String.duplicate("x", 131_073)

    too_large =
      SigV4Request.signed_chunked_conn(:post, "/restorechunked/huge.txt", oversized,
        query: %{"restore" => ""},
        chunk_size: byte_size(oversized),
        decoded_length_override: 131_072
      )
      |> call()

    assert too_large.status == 400
    assert too_large.resp_body =~ "MalformedXML"
    assert too_large.resp_body =~ "RestoreRequest exceeds 128KB"
    assert_restore_status("restorechunked", "huge.txt", nil)
  end

  test "RestoreObject modeled checksum headers are validated before metadata update" do
    SigV4Request.signed_conn(:put, "/restoremodeled") |> call()
    put_archive("restoremodeled", "cold.txt", "cold bytes")

    xml = restore_xml()

    bad =
      SigV4Request.signed_conn(:post, "/restoremodeled/cold.txt",
        query: %{"restore" => ""},
        body: xml,
        headers: [
          {"x-amz-sdk-checksum-algorithm", "SHA256"},
          {"x-amz-checksum-sha256", content_sha256("different")}
        ]
      )
      |> call()

    assert bad.status == 400
    assert bad.resp_body =~ "BadDigest"
    assert_restore_status("restoremodeled", "cold.txt", nil)

    ok =
      SigV4Request.signed_conn(:post, "/restoremodeled/cold.txt",
        query: %{"restore" => ""},
        body: xml,
        headers: [
          {"x-amz-sdk-checksum-algorithm", "SHA256"},
          {"x-amz-checksum-sha256", content_sha256(xml)}
        ]
      )
      |> call()

    assert ok.status == 202
    assert_restore_status("restoremodeled", "cold.txt", "restored")
  end

  test "RestoreObject versionId restores only the requested archived version" do
    SigV4Request.signed_conn(:put, "/restoreversioned") |> call()
    assert enable_versioning("restoreversioned").status == 200

    first = put_archive("restoreversioned", "cold.txt", "first cold")
    [first_version] = get_resp_header(first, "x-amz-version-id")

    second = put_archive("restoreversioned", "cold.txt", "second cold")
    [second_version] = get_resp_header(second, "x-amz-version-id")
    assert second_version != first_version

    restore =
      SigV4Request.signed_conn(:post, "/restoreversioned/cold.txt",
        query: %{"restore" => "", "versionId" => first_version},
        body: restore_xml()
      )
      |> call()

    assert restore.status == 202
    assert get_resp_header(restore, "x-amz-version-id") == [first_version]
    assert_version_restore_status("restoreversioned", "cold.txt", first_version, "restored")
    assert_version_restore_status("restoreversioned", "cold.txt", second_version, nil)
  end

  test "RestoreObject rejects current and explicit delete markers without restoring object versions" do
    SigV4Request.signed_conn(:put, "/restoredm") |> call()
    assert enable_versioning("restoredm").status == 200

    put = put_archive("restoredm", "cold.txt", "cold bytes")
    [object_version] = get_resp_header(put, "x-amz-version-id")

    delete = SigV4Request.signed_conn(:delete, "/restoredm/cold.txt") |> call()
    assert delete.status == 204
    [delete_marker_version] = get_resp_header(delete, "x-amz-version-id")

    latest =
      SigV4Request.signed_conn(:post, "/restoredm/cold.txt",
        query: %{"restore" => ""},
        body: restore_xml()
      )
      |> call()

    assert latest.status == 405
    assert latest.resp_body =~ "<Code>MethodNotAllowed</Code>"
    assert_version_restore_status("restoredm", "cold.txt", object_version, nil)

    explicit =
      SigV4Request.signed_conn(:post, "/restoredm/cold.txt",
        query: %{"restore" => "", "versionId" => delete_marker_version},
        body: restore_xml()
      )
      |> call()

    assert explicit.status == 405
    assert explicit.resp_body =~ "<Code>MethodNotAllowed</Code>"
    assert_version_restore_status("restoredm", "cold.txt", object_version, nil)
    assert_version_restore_status("restoredm", "cold.txt", delete_marker_version, nil)
  end

  test "RestoreObject maps invalid object names to structured S3 errors" do
    SigV4Request.signed_conn(:put, "/restorebadkey") |> call()
    xml = ~s(<RestoreRequest><Days>1</Days></RestoreRequest>)

    restore =
      SigV4Request.signed_conn(:post, "/restorebadkey/a/../b",
        query: %{"restore" => ""},
        body: xml
      )
      |> call()

    assert restore.status == 400
    assert restore.resp_body =~ "<Code>XMinioInvalidObjectName</Code>"
    refute restore.resp_body =~ "InternalError"
  end

  defp call(conn), do: Endpoint.call(conn, Endpoint.init([]))

  defp alice(method, path, opts) do
    SigV4Request.signed_conn(
      method,
      path,
      Keyword.merge([access_key: @alice_ak, secret: @alice_secret], opts)
    )
  end

  defp put_alice_policy(name, policy) when is_map(policy) do
    assert :ok = Store.put_principal_policy(@alice_arn, name, Jason.encode!(policy))
  end

  defp create_object_writer_bucket(bucket) do
    SigV4Request.signed_conn(:put, "/#{bucket}",
      headers: [{"x-amz-object-ownership", "ObjectWriter"}]
    )
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

  defp restore_xml do
    ~s(<RestoreRequest><Days>3</Days><GlacierJobParameters><Tier>Standard</Tier></GlacierJobParameters></RestoreRequest>)
  end

  defp select_restore_xml(output_bucket, output_prefix, expression, extra_output_s3 \\ "") do
    """
    <RestoreRequest>
      <Type>SELECT</Type>
      <SelectParameters>
        <Expression>#{expression}</Expression>
        <ExpressionType>SQL</ExpressionType>
        <InputSerialization><CSV/></InputSerialization>
        <OutputSerialization><CSV/></OutputSerialization>
      </SelectParameters>
      <OutputLocation>
        <S3>
          <BucketName>#{output_bucket}</BucketName>
          <Prefix>#{output_prefix}</Prefix>
          #{extra_output_s3}
        </S3>
      </OutputLocation>
    </RestoreRequest>
    """
  end

  defp put_bucket_encryption(bucket) do
    body =
      ~s(<ServerSideEncryptionConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Rule><ApplyServerSideEncryptionByDefault><SSEAlgorithm>AES256</SSEAlgorithm></ApplyServerSideEncryptionByDefault></Rule></ServerSideEncryptionConfiguration>)

    SigV4Request.signed_conn(:put, "/#{bucket}", query: %{"encryption" => ""}, body: body)
    |> call()
  end

  defp put_public_access_block(bucket, values) do
    body = public_access_block_xml(values)

    SigV4Request.signed_conn(:put, "/#{bucket}",
      query: %{"publicAccessBlock" => ""},
      body: body,
      headers: [{"content-md5", content_md5(body)}]
    )
    |> call()
  end

  defp public_access_block_xml(values) do
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

  defp enable_versioning(bucket) do
    body = ~s(<VersioningConfiguration><Status>Enabled</Status></VersioningConfiguration>)

    SigV4Request.signed_conn(:put, "/#{bucket}", query: %{"versioning" => ""}, body: body)
    |> call()
  end

  defp put_archive(bucket, key, body) do
    put =
      SigV4Request.signed_conn(:put, "/#{bucket}/#{key}",
        body: body,
        headers: [{"x-amz-storage-class", "GLACIER"}]
      )
      |> call()

    assert put.status == 200
    put
  end

  defp select_output_prefix_and_key(response) do
    [output_prefix] = get_resp_header(response, "x-amz-restore-output-path")
    {output_prefix, output_prefix <> "part-00000"}
  end

  defp assert_restore_status(bucket, key, status) do
    {:ok, object} = Objects.get_metadata(bucket, key)
    assert object.restore_status == status
  end

  defp assert_version_restore_status(bucket, key, version_id, status) do
    {:ok, object} = Objects.get_version(bucket, key, version_id)
    assert object.restore_status == status
  end

  defp content_sha256(body), do: :crypto.hash(:sha256, body) |> Base.encode64()
  defp content_md5(body), do: :crypto.hash(:md5, body) |> Base.encode64()

  defp restore_env(key, nil), do: Application.delete_env(:maxio, key)
  defp restore_env(key, value), do: Application.put_env(:maxio, key, value)
end
