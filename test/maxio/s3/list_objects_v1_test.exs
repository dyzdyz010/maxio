defmodule Maxio.S3.ListObjectsV1Test do
  use Maxio.DataCase, async: false

  alias Maxio.S3.Endpoint
  alias Maxio.Test.SigV4Request

  @data_dir Path.join(System.tmp_dir!(), "maxio_list_objects_v1")

  setup do
    File.rm_rf(@data_dir)
    File.mkdir_p!(@data_dir)
    prev = Application.get_env(:maxio, :s3)
    Application.put_env(:maxio, :s3, Keyword.put(prev, :data_dir, @data_dir))

    on_exit(fn ->
      Application.put_env(:maxio, :s3, prev)
      File.rm_rf(@data_dir)
    end)

    :ok
  end

  defp call(conn), do: Endpoint.call(conn, Endpoint.init([]))

  test "GET bucket without list-type returns ListObjects V1 XML" do
    SigV4Request.signed_conn(:put, "/lov1-basic") |> call()
    SigV4Request.signed_conn(:put, "/lov1-basic/a.txt", body: "a") |> call()
    SigV4Request.signed_conn(:put, "/lov1-basic/b.txt", body: "b") |> call()

    res = SigV4Request.signed_conn(:get, "/lov1-basic") |> call()

    assert res.status == 200
    assert res.resp_body =~ "<ListBucketResult xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\">"
    assert res.resp_body =~ "<Marker></Marker>"
    assert res.resp_body =~ "<Key>a.txt</Key>"
    assert res.resp_body =~ "<Key>b.txt</Key>"
    refute res.resp_body =~ "<KeyCount>"
    refute res.resp_body =~ "<ContinuationToken>"
    refute res.resp_body =~ "<NextContinuationToken>"
    refute res.resp_body =~ "<StartAfter>"
  end

  test "marker paginates keys strictly after the marker" do
    SigV4Request.signed_conn(:put, "/lov1-marker") |> call()

    for key <- ~w(a.txt b.txt c.txt) do
      SigV4Request.signed_conn(:put, "/lov1-marker/#{key}", body: key) |> call()
    end

    first =
      SigV4Request.signed_conn(:get, "/lov1-marker", query: %{"max-keys" => "2"}) |> call()

    assert first.status == 200
    assert first.resp_body =~ "<IsTruncated>true</IsTruncated>"
    assert first.resp_body =~ "<Key>a.txt</Key>"
    assert first.resp_body =~ "<Key>b.txt</Key>"
    refute first.resp_body =~ "<NextMarker>"

    second =
      SigV4Request.signed_conn(:get, "/lov1-marker", query: %{"marker" => "b.txt"})
      |> call()

    assert second.status == 200
    assert second.resp_body =~ "<Marker>b.txt</Marker>"
    assert second.resp_body =~ "<Key>c.txt</Key>"
    refute second.resp_body =~ "<Key>a.txt</Key>"
    refute second.resp_body =~ "<Key>b.txt</Key>"
  end

  test "delimiter pagination returns NextMarker for truncated common prefixes" do
    SigV4Request.signed_conn(:put, "/lov1-delim") |> call()

    for key <- ~w(photos/2006/a.txt photos/2007/a.txt photos/2008/a.txt) do
      SigV4Request.signed_conn(:put, "/lov1-delim/#{key}", body: key) |> call()
    end

    res =
      SigV4Request.signed_conn(:get, "/lov1-delim",
        query: %{"prefix" => "photos/", "delimiter" => "/", "max-keys" => "2"}
      )
      |> call()

    assert res.status == 200
    assert res.resp_body =~ "<CommonPrefixes><Prefix>photos/2006/</Prefix></CommonPrefixes>"
    assert res.resp_body =~ "<CommonPrefixes><Prefix>photos/2007/</Prefix></CommonPrefixes>"
    assert res.resp_body =~ "<IsTruncated>true</IsTruncated>"
    assert res.resp_body =~ "<NextMarker>photos/2007/</NextMarker>"

    next =
      SigV4Request.signed_conn(:get, "/lov1-delim",
        query: %{
          "prefix" => "photos/",
          "delimiter" => "/",
          "marker" => "photos/2007/"
        }
      )
      |> call()

    assert next.status == 200
    refute next.resp_body =~ "<CommonPrefixes><Prefix>photos/2007/</Prefix></CommonPrefixes>"
    assert next.resp_body =~ "<CommonPrefixes><Prefix>photos/2008/</Prefix></CommonPrefixes>"
  end

  test "only list-type=2 selects the V2 response shape" do
    SigV4Request.signed_conn(:put, "/lov1-list-type") |> call()

    v1 =
      SigV4Request.signed_conn(:get, "/lov1-list-type", query: %{"list-type" => "1"})
      |> call()

    v2 =
      SigV4Request.signed_conn(:get, "/lov1-list-type", query: %{"list-type" => "2"})
      |> call()

    assert v1.status == 200
    assert v1.resp_body =~ "<Marker></Marker>"
    refute v1.resp_body =~ "<KeyCount>"

    assert v2.status == 200
    assert v2.resp_body =~ "<KeyCount>0</KeyCount>"
    refute v2.resp_body =~ "<Marker>"
  end
end
