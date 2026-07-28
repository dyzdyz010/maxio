defmodule Maxio.S3.RequestParsers.LifecycleTest do
  use ExUnit.Case, async: true
  alias Maxio.S3.RequestParsers.Lifecycle, as: P
  alias Maxio.S3.Views.Lifecycle, as: V

  defp assert_malformed(xml) do
    assert {:error, :malformed_xml} = P.parse(xml)
  end

  test "解析单 rule：ID/Status/Filter Prefix/Expiration Days" do
    xml =
      ~s(<LifecycleConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Rule><ID>r1</ID><Filter><Prefix>logs/</Prefix></Filter><Status>Enabled</Status><Expiration><Days>30</Days></Expiration></Rule></LifecycleConfiguration>)

    assert {:ok, [rule]} = P.parse(xml)
    assert rule["id"] == "r1"
    assert rule["status"] == "Enabled"
    assert rule["filter_prefix"] == "logs/"
    assert rule["expiration_days"] == 30
    assert rule["expiration_date"] == nil
  end

  test "兼容旧示例 LifeCycleConfiguration root spelling" do
    xml =
      ~s(<LifeCycleConfiguration><Rule><Status>Enabled</Status><Filter></Filter><Expiration><Days>1</Days></Expiration></Rule></LifeCycleConfiguration>)

    assert {:ok, [rule]} = P.parse(xml)
    assert rule["status"] == "Enabled"
    assert rule["expiration_days"] == 1
  end

  test "legacy 顶层 Prefix → prefix（非 filter_prefix）" do
    xml =
      ~s(<LifecycleConfiguration><Rule><ID>r</ID><Prefix>old/</Prefix><Status>Enabled</Status><Expiration><Days>1</Days></Expiration></Rule></LifecycleConfiguration>)

    assert {:ok, [rule]} = P.parse(xml)
    assert rule["prefix"] == "old/"
    assert rule["filter_prefix"] == nil
  end

  test "ExpiredObjectDeleteMarker true" do
    xml =
      ~s(<LifecycleConfiguration><Rule><Status>Enabled</Status><Filter></Filter><Expiration><ExpiredObjectDeleteMarker>true</ExpiredObjectDeleteMarker></Expiration></Rule></LifecycleConfiguration>)

    assert {:ok, [rule]} = P.parse(xml)
    assert rule["expired_object_delete_marker"] == true
    assert rule["expiration_days"] == nil
  end

  test "AbortIncompleteMultipartUpload + NoncurrentVersionExpiration" do
    xml =
      ~s(<LifecycleConfiguration><Rule><Status>Enabled</Status><Filter></Filter><AbortIncompleteMultipartUpload><DaysAfterInitiation>3</DaysAfterInitiation></AbortIncompleteMultipartUpload><NoncurrentVersionExpiration><NoncurrentDays>10</NoncurrentDays><NewerNoncurrentVersions>5</NewerNoncurrentVersions></NoncurrentVersionExpiration></Rule></LifecycleConfiguration>)

    assert {:ok, [rule]} = P.parse(xml)
    assert rule["has_filter"] == true
    assert rule["abort_days_after_initiation"] == 3
    assert rule["noncurrent_days"] == 10
    assert rule["newer_noncurrent_versions"] == 5
  end

  test "Filter Tag conditions round-trip through parser and view" do
    xml =
      ~s(<LifecycleConfiguration><Rule><ID>tagged</ID><Status>Enabled</Status><Filter><And><Prefix>logs/</Prefix><Tag><Key>class</Key><Value>tmp</Value></Tag></And></Filter><Expiration><Days>1</Days></Expiration></Rule></LifecycleConfiguration>)

    assert {:ok, [rule]} = P.parse(xml)
    assert rule["filter_prefix"] == "logs/"
    assert rule["filter_tags"] == [%{"key" => "class", "value" => "tmp"}]

    out = [rule] |> V.render() |> IO.iodata_to_binary()
    assert out =~ "<And>"
    assert out =~ "<Tag>"
    assert out =~ "<Key>class</Key>"
    assert out =~ "<Value>tmp</Value>"
  end

  test "Transition Date stays under transition instead of becoming Expiration Date" do
    xml =
      ~s(<LifecycleConfiguration><Rule><ID>transition</ID><Status>Enabled</Status><Filter><Prefix>cold/</Prefix></Filter><Transition><Date>2026-12-31T00:00:00Z</Date><StorageClass>GLACIER</StorageClass></Transition></Rule></LifecycleConfiguration>)

    assert {:ok, [rule]} = P.parse(xml)
    assert rule["expiration_date"] == nil
    assert rule["transition_date"] == "2026-12-31T00:00:00Z"
    assert rule["transition_storage_class"] == "GLACIER"

    out = [rule] |> V.render() |> IO.iodata_to_binary()
    assert out =~ "<Transition>"
    assert out =~ "<Date>2026-12-31T00:00:00Z</Date>"
    refute out =~ "<Expiration>"
  end

  test "Transition Days accepts zero for immediate supported transitions" do
    xml =
      ~s(<LifecycleConfiguration><Rule><Status>Enabled</Status><Filter></Filter><Transition><Days>0</Days><StorageClass>GLACIER</StorageClass></Transition></Rule></LifecycleConfiguration>)

    assert {:ok, [rule]} = P.parse(xml)
    assert rule["transition_days"] == 0
    assert rule["transition_storage_class"] == "GLACIER"
    assert rule["parse_errors"] == []
  end

  test "NoncurrentVersionTransition stays distinct from NoncurrentVersionExpiration" do
    xml =
      ~s(<LifecycleConfiguration><Rule><ID>nct</ID><Status>Enabled</Status><Filter></Filter><NoncurrentVersionTransition><NoncurrentDays>7</NoncurrentDays><NewerNoncurrentVersions>1</NewerNoncurrentVersions><StorageClass>GLACIER</StorageClass></NoncurrentVersionTransition></Rule></LifecycleConfiguration>)

    assert {:ok, [rule]} = P.parse(xml)
    assert rule["noncurrent_days"] == nil
    assert rule["newer_noncurrent_versions"] == nil
    assert rule["noncurrent_transition_days"] == 7
    assert rule["noncurrent_transition_newer_noncurrent_versions"] == 1
    assert rule["noncurrent_transition_storage_class"] == "GLACIER"
    assert rule["transition_storage_class"] == nil

    out = [rule] |> V.render() |> IO.iodata_to_binary()
    assert out =~ "<NoncurrentVersionTransition>"
    assert out =~ "<NoncurrentDays>7</NoncurrentDays>"
    assert out =~ "<NewerNoncurrentVersions>1</NewerNoncurrentVersions>"
    assert out =~ "<StorageClass>GLACIER</StorageClass>"
    refute out =~ "<NoncurrentVersionExpiration>"
  end

  test "NoncurrentVersionTransition accepts zero days for supported immediate transition targets" do
    xml =
      ~s(<LifecycleConfiguration><Rule><Status>Enabled</Status><Filter></Filter><NoncurrentVersionTransition><NoncurrentDays>0</NoncurrentDays><StorageClass>GLACIER</StorageClass></NoncurrentVersionTransition></Rule></LifecycleConfiguration>)

    assert {:ok, [rule]} = P.parse(xml)
    assert rule["noncurrent_transition_days"] == 0
    assert rule["noncurrent_transition_storage_class"] == "GLACIER"
  end

  test "invalid lifecycle integers and incomplete tag filters fail closed as malformed XML" do
    xml =
      ~s(<LifecycleConfiguration><Rule><Status>Enabled</Status><Filter><And><Tag><Key>class</Key></Tag><ObjectSizeGreaterThan>100MB</ObjectSizeGreaterThan></And></Filter><Expiration><Days>-1</Days></Expiration></Rule></LifecycleConfiguration>)

    assert_malformed(xml)
  end

  test "rejects wrong root, unknown, misnested, mixed text, and nested leaf XML" do
    bad_xmls = [
      ~s(<BadLifecycle><Rule><Status>Enabled</Status><Filter></Filter><Expiration><Days>1</Days></Expiration></Rule></BadLifecycle>),
      ~s(<LifecycleConfiguration><Unknown /></LifecycleConfiguration>),
      ~s(<LifecycleConfiguration><Expiration><Days>1</Days></Expiration></LifecycleConfiguration>),
      ~s(<LifecycleConfiguration>text<Rule><Status>Enabled</Status><Filter></Filter><Expiration><Days>1</Days></Expiration></Rule></LifecycleConfiguration>),
      ~s(<LifecycleConfiguration><Rule><Status><Value>Enabled</Value></Status><Filter></Filter><Expiration><Days>1</Days></Expiration></Rule></LifecycleConfiguration>)
    ]

    for xml <- bad_xmls, do: assert_malformed(xml)
  end

  test "rejects duplicate singleton fields and repeated unsupported action containers" do
    bad_xmls = [
      ~s(<LifecycleConfiguration><Rule><Status>Enabled</Status><Status>Enabled</Status><Filter></Filter><Expiration><Days>1</Days></Expiration></Rule></LifecycleConfiguration>),
      ~s(<LifecycleConfiguration><Rule><Status>Enabled</Status><Filter></Filter><Expiration><Days>1</Days><Date>2026-12-31T00:00:00Z</Date></Expiration></Rule></LifecycleConfiguration>),
      ~s(<LifecycleConfiguration><Rule><Status>Enabled</Status><Filter></Filter><Transition><Days>1</Days><StorageClass>GLACIER</StorageClass></Transition><Transition><Days>2</Days><StorageClass>GLACIER</StorageClass></Transition></Rule></LifecycleConfiguration>),
      ~s(<LifecycleConfiguration><Rule><Status>Enabled</Status><Filter></Filter><NoncurrentVersionTransition><NoncurrentDays>1</NoncurrentDays><StorageClass>GLACIER</StorageClass></NoncurrentVersionTransition><NoncurrentVersionTransition><NoncurrentDays>2</NoncurrentDays><StorageClass>GLACIER</StorageClass></NoncurrentVersionTransition></Rule></LifecycleConfiguration>)
    ]

    for xml <- bad_xmls, do: assert_malformed(xml)
  end

  test "rejects invalid status and invalid Filter shapes" do
    bad_xmls = [
      ~s(<LifecycleConfiguration><Rule><Status>enabled</Status><Filter></Filter><Expiration><Days>1</Days></Expiration></Rule></LifecycleConfiguration>),
      ~s(<LifecycleConfiguration><Rule><Status>Enabled</Status><Prefix>logs/</Prefix><Filter></Filter><Expiration><Days>1</Days></Expiration></Rule></LifecycleConfiguration>),
      ~s(<LifecycleConfiguration><Rule><Status>Enabled</Status><Filter><Prefix>logs/</Prefix><Tag><Key>class</Key><Value>tmp</Value></Tag></Filter><Expiration><Days>1</Days></Expiration></Rule></LifecycleConfiguration>),
      ~s(<LifecycleConfiguration><Rule><Status>Enabled</Status><Filter><And><Prefix>logs/</Prefix></And></Filter><Expiration><Days>1</Days></Expiration></Rule></LifecycleConfiguration>),
      ~s(<LifecycleConfiguration><Rule><Status>Enabled</Status><Filter><And><Tag><Key>class</Key><Value>tmp</Value></Tag><Tag><Key>class</Key><Value>cold</Value></Tag></And></Filter><Expiration><Days>1</Days></Expiration></Rule></LifecycleConfiguration>),
      ~s(<LifecycleConfiguration><Rule><Status>Enabled</Status><Filter></Filter><Transition><Days>1</Days><StorageClass>glacier</StorageClass></Transition></Rule></LifecycleConfiguration>),
      ~s(<LifecycleConfiguration><Rule><Status>Enabled</Status><Filter></Filter><NoncurrentVersionTransition><NoncurrentDays>1</NoncurrentDays><StorageClass>glacier</StorageClass></NoncurrentVersionTransition></Rule></LifecycleConfiguration>)
    ]

    for xml <- bad_xmls, do: assert_malformed(xml)
  end

  test "Tag filter requires Key and Value but permits empty Value" do
    missing_value =
      ~s(<LifecycleConfiguration><Rule><Status>Enabled</Status><Filter><Tag><Key>class</Key></Tag></Filter><Expiration><Days>1</Days></Expiration></Rule></LifecycleConfiguration>)

    empty_value =
      ~s(<LifecycleConfiguration><Rule><Status>Enabled</Status><Filter><Tag><Key>class</Key><Value></Value></Tag></Filter><Expiration><Days>1</Days></Expiration></Rule></LifecycleConfiguration>)

    assert_malformed(missing_value)
    assert {:ok, [rule]} = P.parse(empty_value)
    assert rule["filter_tags"] == [%{"key" => "class", "value" => ""}]
  end

  test "多 rule 顺序保持" do
    xml =
      ~s(<LifecycleConfiguration><Rule><ID>a</ID><Status>Enabled</Status><Filter></Filter></Rule><Rule><ID>b</ID><Status>Disabled</Status><Filter></Filter></Rule></LifecycleConfiguration>)

    assert {:ok, [r1, r2]} = P.parse(xml)
    assert r1["id"] == "a"
    assert r2["id"] == "b"
    assert r2["status"] == "Disabled"
  end

  test "非法 XML → malformed_xml" do
    assert {:error, :malformed_xml} = P.parse("<bad")
  end

  test "round-trip：parse → view 重建保留 Prefix/Days/Status" do
    xml =
      ~s(<LifecycleConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Rule><ID>r1</ID><Filter><Prefix>tmp/</Prefix></Filter><Status>Enabled</Status><Expiration><Days>7</Days></Expiration></Rule></LifecycleConfiguration>)

    {:ok, rules} = P.parse(xml)
    out = rules |> V.render() |> IO.iodata_to_binary()
    assert out =~ "<ID>r1</ID>"
    assert out =~ "<Prefix>tmp/</Prefix>"
    assert out =~ "<Status>Enabled</Status>"
    assert out =~ "<Days>7</Days>"
  end

  test "view：多 filter 条件包进 And" do
    rule = %{
      "id" => "r",
      "status" => "Enabled",
      "prefix" => nil,
      "filter_prefix" => "logs/",
      "filter_tags" => [],
      "filter_size_gt" => 100,
      "filter_size_lt" => nil,
      "expiration_days" => 5,
      "expiration_date" => nil,
      "expired_object_delete_marker" => nil,
      "noncurrent_days" => nil,
      "newer_noncurrent_versions" => nil,
      "abort_days_after_initiation" => nil,
      "transition_days" => nil,
      "transition_storage_class" => nil
    }

    out = [rule] |> V.render() |> IO.iodata_to_binary()
    assert out =~ "<And>"
    assert out =~ "<ObjectSizeGreaterThan>100</ObjectSizeGreaterThan>"
  end
end
