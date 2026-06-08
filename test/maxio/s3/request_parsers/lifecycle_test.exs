defmodule Maxio.S3.RequestParsers.LifecycleTest do
  use ExUnit.Case, async: true
  alias Maxio.S3.RequestParsers.Lifecycle, as: P
  alias Maxio.S3.Views.Lifecycle, as: V

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
      ~s(<LifecycleConfiguration><Rule><Status>Enabled</Status><Filter></Filter><AbortIncompleteMultipartUpload><DaysAfterInitiation>3</DaysAfterInitiation></AbortIncompleteMultipartUpload><NoncurrentVersionExpiration><NoncurrentDays>10</NoncurrentDays></NoncurrentVersionExpiration></Rule></LifecycleConfiguration>)

    assert {:ok, [rule]} = P.parse(xml)
    assert rule["abort_days_after_initiation"] == 3
    assert rule["noncurrent_days"] == 10
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
