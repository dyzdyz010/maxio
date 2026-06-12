defmodule Maxio.S3.ListMaxKeysClampTest do
  use Maxio.DataCase, async: true

  alias Maxio.{Buckets, Objects}
  alias Maxio.S3.Endpoint
  alias Maxio.Test.SigV4Request

  defp call(conn), do: Endpoint.call(conn, Endpoint.init([]))

  defp bucket!(prefix) do
    name = "#{prefix}-#{System.unique_integer([:positive])}"
    {:ok, _bucket} = Buckets.create(name, "arn:aws:iam:::root")
    :ok = Buckets.put_versioning(name, "Enabled", nil)
    name
  end

  defp put(bucket, key),
    do: Objects.put_metadata(bucket, key, %{size: 1, etag: "e", content_type: "text/plain"})

  test "ListObjectsV2 renders clamped MaxKeys for oversized max-keys query" do
    bucket = bucket!("clamp-list")
    {:ok, _} = put(bucket, "a.txt")

    conn =
      SigV4Request.signed_conn(:get, "/#{bucket}",
        query: %{"list-type" => "2", "max-keys" => "5000"}
      )
      |> call()

    assert conn.status == 200
    assert conn.resp_body =~ "<MaxKeys>1000</MaxKeys>"
    refute conn.resp_body =~ "<MaxKeys>5000</MaxKeys>"
  end

  test "ListObjectVersions renders clamped MaxKeys for oversized max-keys query" do
    bucket = bucket!("clamp-versions")
    {:ok, _} = put(bucket, "a.txt")

    conn =
      SigV4Request.signed_conn(:get, "/#{bucket}",
        query: %{"versions" => "", "max-keys" => "5000"}
      )
      |> call()

    assert conn.status == 200
    assert conn.resp_body =~ "<MaxKeys>1000</MaxKeys>"
    refute conn.resp_body =~ "<MaxKeys>5000</MaxKeys>"
  end
end
