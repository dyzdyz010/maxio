defmodule Maxio.S3.ListBucketV1ViewTest do
  use ExUnit.Case, async: true

  alias Maxio.S3.Views.ListBucketV1

  test "renders Marker and omits V2-only elements" do
    data = %{
      name: "bucket",
      prefix: "photos/",
      marker: "photos/2006/",
      delimiter: "/",
      max_keys: 2,
      is_truncated: true,
      next_marker: "photos/2007/",
      objects: [],
      common_prefixes: ["photos/2007/"]
    }

    xml = data |> ListBucketV1.render() |> IO.iodata_to_binary()
    assert xml =~ "<ListBucketResult xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\">"
    assert xml =~ "<Marker>photos/2006/</Marker>"
    assert xml =~ "<NextMarker>photos/2007/</NextMarker>"
    assert xml =~ "<CommonPrefixes><Prefix>photos/2007/</Prefix></CommonPrefixes>"
    refute xml =~ "<KeyCount>"
    refute xml =~ "<ContinuationToken>"
    refute xml =~ "<NextContinuationToken>"
    refute xml =~ "<StartAfter>"
  end
end
