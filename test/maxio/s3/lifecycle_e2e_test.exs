defmodule Maxio.S3.LifecycleE2ETest do
  use Maxio.DataCase, async: false
  alias Maxio.BucketConfigs
  alias Maxio.Test.SigV4Request
  alias Maxio.S3.Error
  alias Maxio.S3.Endpoint
  alias Maxio.S3.Handlers.Lifecycle, as: LifecycleHandler

  @lc ~s(<LifecycleConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Rule><ID>expire-tmp</ID><Filter><Prefix>tmp/</Prefix></Filter><Status>Enabled</Status><Expiration><Days>7</Days></Expiration></Rule></LifecycleConfiguration>)

  defp call(conn), do: Endpoint.call(conn, Endpoint.init([]))

  defp checksum_b64(algorithm, body), do: :crypto.hash(algorithm, body) |> Base.encode64()

  test "Put 200 → Get 回放（含 Prefix/Days/Status）→ Delete 204 → Get 404" do
    SigV4Request.signed_conn(:put, "/lcb") |> call()
    put = SigV4Request.signed_conn(:put, "/lcb", query: %{"lifecycle" => ""}, body: @lc) |> call()
    assert put.status == 200

    get = SigV4Request.signed_conn(:get, "/lcb", query: %{"lifecycle" => ""}) |> call()
    assert get.status == 200
    assert get.resp_body =~ "expire-tmp"
    assert get.resp_body =~ "<Prefix>tmp/</Prefix>"
    assert get.resp_body =~ "<Days>7</Days>"
    assert get.resp_body =~ "<Status>Enabled</Status>"

    del = SigV4Request.signed_conn(:delete, "/lcb", query: %{"lifecycle" => ""}) |> call()
    assert del.status == 204

    g2 = SigV4Request.signed_conn(:get, "/lcb", query: %{"lifecycle" => ""}) |> call()
    assert g2.status == 404
    assert g2.resp_body =~ "NoSuchLifecycleConfiguration"
  end

  test "Put/Get/DeleteBucketLifecycle validate checksums, trailers, and expected owner" do
    bucket = "lcchecksum"

    updated =
      ~s(<LifecycleConfiguration><Rule><ID>updated</ID><Filter><Prefix>logs/</Prefix></Filter><Status>Enabled</Status><Expiration><Days>3</Days></Expiration></Rule></LifecycleConfiguration>)

    trailer_xml =
      ~s(<LifecycleConfiguration><Rule><ID>trailer</ID><Filter><Prefix>cold/</Prefix></Filter><Status>Enabled</Status><Expiration><Days>9</Days></Expiration></Rule></LifecycleConfiguration>)

    SigV4Request.signed_conn(:put, "/#{bucket}") |> call()

    good_header =
      SigV4Request.signed_conn(:put, "/#{bucket}",
        query: %{"lifecycle" => ""},
        body: @lc,
        headers: [
          {"x-amz-sdk-checksum-algorithm", "SHA256"},
          {"x-amz-checksum-sha256", checksum_b64(:sha256, @lc)}
        ]
      )
      |> call()

    assert good_header.status == 200
    assert {:ok, [%{"id" => "expire-tmp"}]} = BucketConfigs.get(bucket, :lifecycle)

    bad_header =
      SigV4Request.signed_conn(:put, "/#{bucket}",
        query: %{"lifecycle" => ""},
        body: updated,
        headers: [
          {"x-amz-sdk-checksum-algorithm", "SHA256"},
          {"x-amz-checksum-sha256", checksum_b64(:sha256, "different")}
        ]
      )
      |> call()

    assert bad_header.status == 400
    assert bad_header.resp_body =~ "<Code>BadDigest</Code>"
    assert {:ok, [%{"id" => "expire-tmp"}]} = BucketConfigs.get(bucket, :lifecycle)

    plain_trailer =
      SigV4Request.signed_conn(:put, "/#{bucket}",
        query: %{"lifecycle" => ""},
        body: updated,
        headers: [
          {"x-amz-sdk-checksum-algorithm", "SHA256"},
          {"x-amz-trailer", "x-amz-checksum-sha256"}
        ]
      )
      |> call()

    assert plain_trailer.status == 400
    assert plain_trailer.resp_body =~ "<Code>InvalidRequest</Code>"
    assert {:ok, [%{"id" => "expire-tmp"}]} = BucketConfigs.get(bucket, :lifecycle)

    ok_trailer =
      SigV4Request.signed_chunked_conn(:put, "/#{bucket}", trailer_xml,
        query: %{"lifecycle" => ""},
        headers: [{"x-amz-sdk-checksum-algorithm", "SHA256"}],
        trailer_headers: [{"x-amz-checksum-sha256", checksum_b64(:sha256, trailer_xml)}]
      )
      |> call()

    assert ok_trailer.status == 200
    assert {:ok, [%{"id" => "trailer"}]} = BucketConfigs.get(bucket, :lifecycle)

    wrong_put =
      SigV4Request.signed_conn(:put, "/#{bucket}",
        query: %{"lifecycle" => ""},
        body: updated,
        headers: [{"x-amz-expected-bucket-owner", "111111111111"}]
      )
      |> call()

    assert wrong_put.status == 403
    assert {:ok, [%{"id" => "trailer"}]} = BucketConfigs.get(bucket, :lifecycle)

    wrong_get =
      SigV4Request.signed_conn(:get, "/#{bucket}",
        query: %{"lifecycle" => ""},
        headers: [{"x-amz-expected-bucket-owner", "111111111111"}]
      )
      |> call()

    assert wrong_get.status == 403

    wrong_delete =
      SigV4Request.signed_conn(:delete, "/#{bucket}",
        query: %{"lifecycle" => ""},
        headers: [{"x-amz-expected-bucket-owner", "111111111111"}]
      )
      |> call()

    assert wrong_delete.status == 403
    assert {:ok, [%{"id" => "trailer"}]} = BucketConfigs.get(bucket, :lifecycle)
  end

  test "空 LifecycleConfiguration → 400，不能存成空配置" do
    SigV4Request.signed_conn(:put, "/lcb-empty") |> call()

    bad = ~s(<LifecycleConfiguration></LifecycleConfiguration>)

    res =
      SigV4Request.signed_conn(:put, "/lcb-empty", query: %{"lifecycle" => ""}, body: bad)
      |> call()

    assert res.status == 400

    get = SigV4Request.signed_conn(:get, "/lcb-empty", query: %{"lifecycle" => ""}) |> call()
    assert get.status == 404
    assert get.resp_body =~ "NoSuchLifecycleConfiguration"
  end

  test "Rule 只有 Status/Filter 且没有 action → 400，不能覆盖旧配置" do
    SigV4Request.signed_conn(:put, "/lcb-noop") |> call()

    put =
      SigV4Request.signed_conn(:put, "/lcb-noop", query: %{"lifecycle" => ""}, body: @lc)
      |> call()

    assert put.status == 200

    bad =
      ~s(<LifecycleConfiguration><Rule><ID>noop</ID><Filter><Prefix>tmp/</Prefix></Filter><Status>Enabled</Status></Rule></LifecycleConfiguration>)

    res =
      SigV4Request.signed_conn(:put, "/lcb-noop", query: %{"lifecycle" => ""}, body: bad)
      |> call()

    assert res.status == 400

    get = SigV4Request.signed_conn(:get, "/lcb-noop", query: %{"lifecycle" => ""}) |> call()
    assert get.status == 200
    assert get.resp_body =~ "expire-tmp"
    refute get.resp_body =~ "noop"
  end

  test "malformed Lifecycle XML → 400，不能覆盖旧配置" do
    bucket = "lcb-malformed"
    SigV4Request.signed_conn(:put, "/#{bucket}") |> call()

    put =
      SigV4Request.signed_conn(:put, "/#{bucket}", query: %{"lifecycle" => ""}, body: @lc)
      |> call()

    assert put.status == 200

    bad_xmls = [
      {"wrong root",
       ~s(<BadLifecycle><Rule><Status>Enabled</Status><Filter></Filter><Expiration><Days>1</Days></Expiration></Rule></BadLifecycle>)},
      {"unknown child", ~s(<LifecycleConfiguration><Unknown /></LifecycleConfiguration>)},
      {"duplicate status",
       ~s(<LifecycleConfiguration><Rule><Status>Enabled</Status><Status>Enabled</Status><Filter></Filter><Expiration><Days>1</Days></Expiration></Rule></LifecycleConfiguration>)},
      {"lowercase status",
       ~s(<LifecycleConfiguration><Rule><Status>enabled</Status><Filter></Filter><Expiration><Days>1</Days></Expiration></Rule></LifecycleConfiguration>)},
      {"prefix and filter",
       ~s(<LifecycleConfiguration><Rule><Status>Enabled</Status><Prefix>logs/</Prefix><Filter></Filter><Expiration><Days>1</Days></Expiration></Rule></LifecycleConfiguration>)},
      {"multi direct filter predicates",
       ~s(<LifecycleConfiguration><Rule><Status>Enabled</Status><Filter><Prefix>logs/</Prefix><Tag><Key>class</Key><Value>tmp</Value></Tag></Filter><Expiration><Days>1</Days></Expiration></Rule></LifecycleConfiguration>)},
      {"repeated transition",
       ~s(<LifecycleConfiguration><Rule><Status>Enabled</Status><Filter></Filter><Transition><Days>1</Days><StorageClass>GLACIER</StorageClass></Transition><Transition><Days>2</Days><StorageClass>GLACIER</StorageClass></Transition></Rule></LifecycleConfiguration>)},
      {"nested leaf",
       ~s(<LifecycleConfiguration><Rule><Status>Enabled</Status><Filter></Filter><Expiration><Days><Value>1</Value></Days></Expiration></Rule></LifecycleConfiguration>)},
      {"lowercase storage class",
       ~s(<LifecycleConfiguration><Rule><Status>Enabled</Status><Filter></Filter><Transition><Days>1</Days><StorageClass>glacier</StorageClass></Transition></Rule></LifecycleConfiguration>)}
    ]

    for {label, xml} <- bad_xmls do
      res =
        SigV4Request.signed_conn(:put, "/#{bucket}", query: %{"lifecycle" => ""}, body: xml)
        |> call()

      assert res.status == 400, label
      assert res.resp_body =~ "<Code>MalformedXML</Code>", label
      assert {:ok, [%{"id" => "expire-tmp"}]} = BucketConfigs.get(bucket, :lifecycle)
    end
  end

  test "invalid Lifecycle semantics → 400，不能覆盖旧配置" do
    bucket = "lcb-semantic"
    SigV4Request.signed_conn(:put, "/#{bucket}") |> call()

    put =
      SigV4Request.signed_conn(:put, "/#{bucket}", query: %{"lifecycle" => ""}, body: @lc)
      |> call()

    assert put.status == 200

    long_id = String.duplicate("a", 256)

    bad_xmls = [
      {"missing selector",
       ~s(<LifecycleConfiguration><Rule><Status>Enabled</Status><Expiration><Days>1</Days></Expiration></Rule></LifecycleConfiguration>)},
      {"empty id",
       ~s(<LifecycleConfiguration><Rule><ID></ID><Status>Enabled</Status><Filter></Filter><Expiration><Days>1</Days></Expiration></Rule></LifecycleConfiguration>)},
      {"long id",
       ~s(<LifecycleConfiguration><Rule><ID>#{long_id}</ID><Status>Enabled</Status><Filter></Filter><Expiration><Days>1</Days></Expiration></Rule></LifecycleConfiguration>)},
      {"duplicate id",
       ~s(<LifecycleConfiguration><Rule><ID>dup</ID><Status>Enabled</Status><Filter></Filter><Expiration><Days>1</Days></Expiration></Rule><Rule><ID>dup</ID><Status>Enabled</Status><Filter></Filter><Expiration><Days>2</Days></Expiration></Rule></LifecycleConfiguration>)},
      {"invalid size range",
       ~s(<LifecycleConfiguration><Rule><Status>Enabled</Status><Filter><And><ObjectSizeGreaterThan>10</ObjectSizeGreaterThan><ObjectSizeLessThan>10</ObjectSizeLessThan></And></Filter><Expiration><Days>1</Days></Expiration></Rule></LifecycleConfiguration>)},
      {"tag filter with abort",
       ~s(<LifecycleConfiguration><Rule><Status>Enabled</Status><Filter><Tag><Key>class</Key><Value>tmp</Value></Tag></Filter><AbortIncompleteMultipartUpload><DaysAfterInitiation>1</DaysAfterInitiation></AbortIncompleteMultipartUpload></Rule></LifecycleConfiguration>)},
      {"tag filter with eodm",
       ~s(<LifecycleConfiguration><Rule><Status>Enabled</Status><Filter><Tag><Key>class</Key><Value>tmp</Value></Tag></Filter><Expiration><ExpiredObjectDeleteMarker>true</ExpiredObjectDeleteMarker></Expiration></Rule></LifecycleConfiguration>)}
    ]

    for {label, xml} <- bad_xmls do
      res =
        SigV4Request.signed_conn(:put, "/#{bucket}", query: %{"lifecycle" => ""}, body: xml)
        |> call()

      assert res.status == 400, label
      assert {:ok, [%{"id" => "expire-tmp"}]} = BucketConfigs.get(bucket, :lifecycle)
    end
  end

  test "Disabled Rule 没有 action → 400，不能作为空壳规则保存" do
    SigV4Request.signed_conn(:put, "/lcb-disabled-noop") |> call()

    bad =
      ~s(<LifecycleConfiguration><Rule><ID>disabled-noop</ID><Status>Disabled</Status><Filter></Filter></Rule></LifecycleConfiguration>)

    res =
      SigV4Request.signed_conn(:put, "/lcb-disabled-noop", query: %{"lifecycle" => ""}, body: bad)
      |> call()

    assert res.status == 400
  end

  test "ExpiredObjectDeleteMarker=false 不能算 lifecycle action" do
    SigV4Request.signed_conn(:put, "/lcb-eodm-false") |> call()

    bad =
      ~s(<LifecycleConfiguration><Rule><Status>Enabled</Status><Filter></Filter><Expiration><ExpiredObjectDeleteMarker>false</ExpiredObjectDeleteMarker></Expiration></Rule></LifecycleConfiguration>)

    res =
      SigV4Request.signed_conn(:put, "/lcb-eodm-false", query: %{"lifecycle" => ""}, body: bad)
      |> call()

    assert res.status == 400
  end

  test "ExpiredObjectDeleteMarker=false 仍不能与 Days 共存" do
    SigV4Request.signed_conn(:put, "/lcb-eodm-false-days") |> call()

    bad =
      ~s(<LifecycleConfiguration><Rule><Status>Enabled</Status><Filter></Filter><Expiration><Days>7</Days><ExpiredObjectDeleteMarker>false</ExpiredObjectDeleteMarker></Expiration></Rule></LifecycleConfiguration>)

    res =
      SigV4Request.signed_conn(:put, "/lcb-eodm-false-days",
        query: %{"lifecycle" => ""},
        body: bad
      )
      |> call()

    assert res.status == 400
  end

  test "ExpiredObjectDeleteMarker=false 仍不能与 Date 共存" do
    SigV4Request.signed_conn(:put, "/lcb-eodm-false-date") |> call()

    bad =
      ~s(<LifecycleConfiguration><Rule><Status>Enabled</Status><Filter></Filter><Expiration><Date>2026-12-31T00:00:00Z</Date><ExpiredObjectDeleteMarker>false</ExpiredObjectDeleteMarker></Expiration></Rule></LifecycleConfiguration>)

    res =
      SigV4Request.signed_conn(:put, "/lcb-eodm-false-date",
        query: %{"lifecycle" => ""},
        body: bad
      )
      |> call()

    assert res.status == 400
  end

  test "Expiration 同时 Days+Date → 400" do
    SigV4Request.signed_conn(:put, "/lcb2") |> call()

    bad =
      ~s(<LifecycleConfiguration><Rule><Status>Enabled</Status><Filter></Filter><Expiration><Days>7</Days><Date>2026-01-01T00:00:00.000Z</Date></Expiration></Rule></LifecycleConfiguration>)

    res =
      SigV4Request.signed_conn(:put, "/lcb2", query: %{"lifecycle" => ""}, body: bad) |> call()

    assert res.status == 400
  end

  test "Transition Date 不会被回放为 Expiration Date" do
    SigV4Request.signed_conn(:put, "/lcb3") |> call()

    xml =
      ~s(<LifecycleConfiguration><Rule><ID>transition-only</ID><Status>Enabled</Status><Filter><Prefix>cold/</Prefix></Filter><Transition><Date>2026-12-31T00:00:00Z</Date><StorageClass>GLACIER</StorageClass></Transition></Rule></LifecycleConfiguration>)

    put =
      SigV4Request.signed_conn(:put, "/lcb3", query: %{"lifecycle" => ""}, body: xml) |> call()

    assert put.status == 200

    get = SigV4Request.signed_conn(:get, "/lcb3", query: %{"lifecycle" => ""}) |> call()
    assert get.status == 200
    assert get.resp_body =~ "<Transition>"
    assert get.resp_body =~ "<Date>2026-12-31T00:00:00Z</Date>"
    refute get.resp_body =~ "<Expiration>"
  end

  test "非法 Transition storage class → 400，不能存成不可执行规则" do
    SigV4Request.signed_conn(:put, "/lcb3bad") |> call()

    bad =
      ~s(<LifecycleConfiguration><Rule><Status>Enabled</Status><Filter></Filter><Transition><Days>1</Days><StorageClass>STANDARD</StorageClass></Transition></Rule></LifecycleConfiguration>)

    res =
      SigV4Request.signed_conn(:put, "/lcb3bad", query: %{"lifecycle" => ""}, body: bad)
      |> call()

    assert res.status == 400
  end

  test "Transition Days=0 对 Glacier 目标合法但对 IA 目标需满足最小天数" do
    SigV4Request.signed_conn(:put, "/lcb3days") |> call()

    ok =
      ~s(<LifecycleConfiguration><Rule><Status>Enabled</Status><Filter></Filter><Transition><Days>0</Days><StorageClass>GLACIER</StorageClass></Transition></Rule></LifecycleConfiguration>)

    assert (SigV4Request.signed_conn(:put, "/lcb3days", query: %{"lifecycle" => ""}, body: ok)
            |> call()).status == 200

    bad =
      ~s(<LifecycleConfiguration><Rule><Status>Enabled</Status><Filter></Filter><Transition><Days>1</Days><StorageClass>STANDARD_IA</StorageClass></Transition></Rule></LifecycleConfiguration>)

    assert (SigV4Request.signed_conn(:put, "/lcb3days", query: %{"lifecycle" => ""}, body: bad)
            |> call()).status == 400
  end

  test "handler validation rejects lowercase lifecycle storage class from non-XML callers" do
    current_transition = %{
      "status" => "Enabled",
      "has_filter" => true,
      "filter_tags" => [],
      "transition_days" => 0,
      "transition_storage_class" => "glacier",
      "parse_errors" => []
    }

    noncurrent_transition = %{
      "status" => "Enabled",
      "has_filter" => true,
      "filter_tags" => [],
      "noncurrent_transition_days" => 0,
      "noncurrent_transition_storage_class" => "glacier",
      "parse_errors" => []
    }

    assert_raise Error, fn -> LifecycleHandler.validate!([current_transition]) end
    assert_raise Error, fn -> LifecycleHandler.validate!([noncurrent_transition]) end
  end

  test "非法对象大小 filter → 400，不能静默放宽删除选择器" do
    SigV4Request.signed_conn(:put, "/lcb4") |> call()

    bad =
      ~s(<LifecycleConfiguration><Rule><Status>Enabled</Status><Filter><ObjectSizeGreaterThan>100MB</ObjectSizeGreaterThan></Filter><Expiration><Days>1</Days></Expiration></Rule></LifecycleConfiguration>)

    res =
      SigV4Request.signed_conn(:put, "/lcb4", query: %{"lifecycle" => ""}, body: bad) |> call()

    assert res.status == 400
  end

  test "不完整 tag filter → 400，不能静默丢弃 tag 约束" do
    SigV4Request.signed_conn(:put, "/lcb5") |> call()

    bad =
      ~s(<LifecycleConfiguration><Rule><Status>Enabled</Status><Filter><Tag><Key>class</Key></Tag></Filter><Expiration><Days>1</Days></Expiration></Rule></LifecycleConfiguration>)

    res =
      SigV4Request.signed_conn(:put, "/lcb5", query: %{"lifecycle" => ""}, body: bad) |> call()

    assert res.status == 400
  end

  test "NewerNoncurrentVersions 无 Filter → 400（AWS 要求显式 Filter）" do
    SigV4Request.signed_conn(:put, "/lcb6") |> call()

    bad =
      ~s(<LifecycleConfiguration><Rule><Status>Enabled</Status><NoncurrentVersionExpiration><NoncurrentDays>30</NoncurrentDays><NewerNoncurrentVersions>5</NewerNoncurrentVersions></NoncurrentVersionExpiration></Rule></LifecycleConfiguration>)

    res =
      SigV4Request.signed_conn(:put, "/lcb6", query: %{"lifecycle" => ""}, body: bad) |> call()

    assert res.status == 400
  end

  test "NewerNoncurrentVersions 不能用 legacy Prefix 代替 Filter" do
    SigV4Request.signed_conn(:put, "/lcb9") |> call()

    bad =
      ~s(<LifecycleConfiguration><Rule><Status>Enabled</Status><Prefix>logs/</Prefix><NoncurrentVersionExpiration><NoncurrentDays>30</NoncurrentDays><NewerNoncurrentVersions>5</NewerNoncurrentVersions></NoncurrentVersionExpiration></Rule></LifecycleConfiguration>)

    res =
      SigV4Request.signed_conn(:put, "/lcb9", query: %{"lifecycle" => ""}, body: bad) |> call()

    assert res.status == 400
  end

  test "NewerNoncurrentVersions 超过 100 → 400" do
    SigV4Request.signed_conn(:put, "/lcb7") |> call()

    bad =
      ~s(<LifecycleConfiguration><Rule><Status>Enabled</Status><Filter></Filter><NoncurrentVersionExpiration><NoncurrentDays>30</NoncurrentDays><NewerNoncurrentVersions>101</NewerNoncurrentVersions></NoncurrentVersionExpiration></Rule></LifecycleConfiguration>)

    res =
      SigV4Request.signed_conn(:put, "/lcb7", query: %{"lifecycle" => ""}, body: bad) |> call()

    assert res.status == 400
  end

  test "NewerNoncurrentVersions 带 Filter 且 1..100 → 200" do
    SigV4Request.signed_conn(:put, "/lcb8") |> call()

    xml =
      ~s(<LifecycleConfiguration><Rule><Status>Enabled</Status><Filter></Filter><NoncurrentVersionExpiration><NoncurrentDays>30</NoncurrentDays><NewerNoncurrentVersions>100</NewerNoncurrentVersions></NoncurrentVersionExpiration></Rule></LifecycleConfiguration>)

    res =
      SigV4Request.signed_conn(:put, "/lcb8", query: %{"lifecycle" => ""}, body: xml) |> call()

    assert res.status == 200
  end

  test "NoncurrentVersionTransition NewerNoncurrentVersions 同样要求 Filter" do
    SigV4Request.signed_conn(:put, "/lcb10") |> call()

    bad =
      ~s(<LifecycleConfiguration><Rule><Status>Enabled</Status><NoncurrentVersionTransition><NoncurrentDays>30</NoncurrentDays><NewerNoncurrentVersions>5</NewerNoncurrentVersions><StorageClass>GLACIER</StorageClass></NoncurrentVersionTransition></Rule></LifecycleConfiguration>)

    res =
      SigV4Request.signed_conn(:put, "/lcb10", query: %{"lifecycle" => ""}, body: bad) |> call()

    assert res.status == 400
  end

  test "NoncurrentVersionTransition Days=0 对 Glacier 合法但 IA 目标需满足最小天数" do
    bucket = "lcb-nct-days"
    SigV4Request.signed_conn(:put, "/#{bucket}") |> call()

    ok =
      ~s(<LifecycleConfiguration><Rule><ID>nct-zero</ID><Status>Enabled</Status><Filter></Filter><NoncurrentVersionTransition><NoncurrentDays>0</NoncurrentDays><StorageClass>GLACIER</StorageClass></NoncurrentVersionTransition></Rule></LifecycleConfiguration>)

    assert (SigV4Request.signed_conn(:put, "/#{bucket}", query: %{"lifecycle" => ""}, body: ok)
            |> call()).status == 200

    assert {:ok, [%{"id" => "nct-zero", "noncurrent_transition_days" => 0}]} =
             BucketConfigs.get(bucket, :lifecycle)

    bad =
      ~s(<LifecycleConfiguration><Rule><ID>nct-ia</ID><Status>Enabled</Status><Filter></Filter><NoncurrentVersionTransition><NoncurrentDays>1</NoncurrentDays><StorageClass>STANDARD_IA</StorageClass></NoncurrentVersionTransition></Rule></LifecycleConfiguration>)

    assert (SigV4Request.signed_conn(:put, "/#{bucket}", query: %{"lifecycle" => ""}, body: bad)
            |> call()).status == 400

    assert {:ok, [%{"id" => "nct-zero", "noncurrent_transition_days" => 0}]} =
             BucketConfigs.get(bucket, :lifecycle)
  end

  test "NoncurrentVersionTransition NewerNoncurrentVersions 不能缺 NoncurrentDays" do
    SigV4Request.signed_conn(:put, "/lcb10days") |> call()

    bad =
      ~s(<LifecycleConfiguration><Rule><Status>Enabled</Status><Filter></Filter><NoncurrentVersionTransition><NewerNoncurrentVersions>5</NewerNoncurrentVersions><StorageClass>GLACIER</StorageClass></NoncurrentVersionTransition></Rule></LifecycleConfiguration>)

    res =
      SigV4Request.signed_conn(:put, "/lcb10days", query: %{"lifecycle" => ""}, body: bad)
      |> call()

    assert res.status == 400
  end

  test "NoncurrentVersionTransition NewerNoncurrentVersions 回放仍留在 transition 下" do
    SigV4Request.signed_conn(:put, "/lcb11") |> call()

    xml =
      ~s(<LifecycleConfiguration><Rule><Status>Enabled</Status><Filter></Filter><NoncurrentVersionTransition><NoncurrentDays>30</NoncurrentDays><NewerNoncurrentVersions>5</NewerNoncurrentVersions><StorageClass>GLACIER</StorageClass></NoncurrentVersionTransition></Rule></LifecycleConfiguration>)

    put =
      SigV4Request.signed_conn(:put, "/lcb11", query: %{"lifecycle" => ""}, body: xml) |> call()

    assert put.status == 200

    get = SigV4Request.signed_conn(:get, "/lcb11", query: %{"lifecycle" => ""}) |> call()
    assert get.status == 200
    assert get.resp_body =~ "<NoncurrentVersionTransition>"
    assert get.resp_body =~ "<NewerNoncurrentVersions>5</NewerNoncurrentVersions>"
    refute get.resp_body =~ "<NoncurrentVersionExpiration>"
  end
end
