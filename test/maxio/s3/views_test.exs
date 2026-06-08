defmodule Maxio.S3.ViewsTest do
  use ExUnit.Case, async: true

  alias Maxio.S3.Views.{ListAllMyBuckets, ListBucket, LocationConstraint}

  test "ListAllMyBuckets：含命名空间、Owner、各 Bucket 名与 CreationDate（millis Z）" do
    data = %{
      owner: %{id: "rootid", display_name: "minio"},
      buckets: [
        %{name: "b1", creation_date: ~U[2019-12-11 23:32:47.000000Z]},
        %{name: "b2", creation_date: ~U[2019-11-10 23:32:13.000000Z]}
      ]
    }

    xml = data |> ListAllMyBuckets.render() |> IO.iodata_to_binary()
    assert xml =~ "<ListAllMyBucketsResult xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\">"
    assert xml =~ "<ID>rootid</ID>"
    assert xml =~ "<DisplayName>minio</DisplayName>"
    assert xml =~ "<Name>b1</Name>"
    assert xml =~ "<CreationDate>2019-12-11T23:32:47.000Z</CreationDate>"
    assert xml =~ "<Name>b2</Name>"
  end

  test "ListBucket：基础列举（Name/Prefix/KeyCount/MaxKeys/IsTruncated + Contents）" do
    data = %{
      name: "bucket",
      prefix: "",
      delimiter: nil,
      max_keys: 1000,
      key_count: 1,
      is_truncated: false,
      next_continuation_token: nil,
      start_after: nil,
      objects: [
        %{
          key: "my-image.jpg",
          last_modified: ~U[2009-10-12 17:50:30.000000Z],
          etag: "fba9dede5f27731c9771645a39863328",
          size: 434_234
        }
      ],
      common_prefixes: []
    }

    xml = data |> ListBucket.render() |> IO.iodata_to_binary()
    assert xml =~ "<ListBucketResult xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\">"
    assert xml =~ "<Name>bucket</Name>"
    assert xml =~ "<KeyCount>1</KeyCount>"
    assert xml =~ "<MaxKeys>1000</MaxKeys>"
    assert xml =~ "<IsTruncated>false</IsTruncated>"
    assert xml =~ "<Key>my-image.jpg</Key>"
    assert xml =~ "<ETag>\"fba9dede5f27731c9771645a39863328\"</ETag>"
    assert xml =~ "<Size>434234</Size>"
    assert xml =~ "<StorageClass>STANDARD</StorageClass>"
    refute xml =~ "<NextContinuationToken>"
  end

  test "ListBucket：截断时含 NextContinuationToken；delimiter 时含 CommonPrefixes" do
    data = %{
      name: "bucket",
      prefix: "photos/",
      delimiter: "/",
      max_keys: 2,
      key_count: 2,
      is_truncated: true,
      next_continuation_token: "tok",
      start_after: nil,
      objects: [],
      common_prefixes: ["photos/2006/", "photos/2007/"]
    }

    xml = data |> ListBucket.render() |> IO.iodata_to_binary()
    assert xml =~ "<NextContinuationToken>tok</NextContinuationToken>"
    assert xml =~ "<Delimiter>/</Delimiter>"
    assert xml =~ "<CommonPrefixes><Prefix>photos/2006/</Prefix></CommonPrefixes>"
    assert xml =~ "<CommonPrefixes><Prefix>photos/2007/</Prefix></CommonPrefixes>"
  end

  test "LocationConstraint：非默认区域返回区域文本" do
    xml = "us-west-2" |> LocationConstraint.render() |> IO.iodata_to_binary()

    assert xml =~
             "<LocationConstraint xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\">us-west-2</LocationConstraint>"
  end

  test "LocationConstraint：us-east-1 返回空体（最常见兼容坑）" do
    xml = "us-east-1" |> LocationConstraint.render() |> IO.iodata_to_binary()
    assert xml =~ "<LocationConstraint"
    refute xml =~ "us-east-1"
  end
end
