defmodule Maxio.S3.ListConditionalMatrixTest do
  @moduledoc """
  Compact compatibility matrix for high-frequency object listing and
  conditional read semantics.
  """

  use Maxio.DataCase, async: false

  import Plug.Conn

  alias Maxio.S3.Endpoint
  alias Maxio.Test.SigV4Request

  @data_dir Path.join(System.tmp_dir!(), "maxio_list_conditional_matrix")
  @old_http_date "Mon, 01 Jan 2001 00:00:00 GMT"
  @future_http_date "Sat, 01 Jan 2050 00:00:00 GMT"

  setup do
    File.rm_rf(@data_dir)
    File.mkdir_p!(@data_dir)

    prev = Application.get_env(:maxio, :s3, [])
    Application.put_env(:maxio, :s3, Keyword.put(prev, :data_dir, @data_dir))

    on_exit(fn ->
      Application.put_env(:maxio, :s3, prev)
      File.rm_rf(@data_dir)
    end)

    :ok
  end

  defp call(conn), do: Endpoint.call(conn, Endpoint.init([]))

  test "ListObjectsV2 matrix paginates with continuation tokens and clamps max-keys" do
    bucket = "lcmv2page"
    create_bucket(bucket)

    for key <- ~w(a.txt b.txt c.txt) do
      put_object(bucket, key, key)
    end

    first = list_v2(bucket, %{"max-keys" => "2"})
    assert first.status == 200
    assert first.resp_body =~ "<KeyCount>2</KeyCount>"
    assert first.resp_body =~ "<MaxKeys>2</MaxKeys>"
    assert first.resp_body =~ "<IsTruncated>true</IsTruncated>"
    assert first.resp_body =~ "<Key>a.txt</Key>"
    assert first.resp_body =~ "<Key>b.txt</Key>"
    refute first.resp_body =~ "<Key>c.txt</Key>"
    assert first.resp_body =~ "<NextContinuationToken>b.txt</NextContinuationToken>"
    refute first.resp_body =~ "<ContinuationToken>"

    second = list_v2(bucket, %{"continuation-token" => "b.txt", "max-keys" => "2"})
    assert second.status == 200
    assert second.resp_body =~ "<ContinuationToken>b.txt</ContinuationToken>"
    assert second.resp_body =~ "<IsTruncated>false</IsTruncated>"
    assert second.resp_body =~ "<KeyCount>1</KeyCount>"
    assert second.resp_body =~ "<Key>c.txt</Key>"
    refute second.resp_body =~ "<Key>a.txt</Key>"
    refute second.resp_body =~ "<Key>b.txt</Key>"

    clamped = list_v2(bucket, %{"max-keys" => "5000"})
    assert clamped.status == 200
    assert clamped.resp_body =~ "<MaxKeys>1000</MaxKeys>"
    refute clamped.resp_body =~ "<MaxKeys>5000</MaxKeys>"
  end

  test "ListObjectsV2 matrix groups prefix/delimiter common prefixes and url-encodes visible fields" do
    bucket = "lcmv2enc"
    create_bucket(bucket)

    for key <- [
          "photos/2006/a.txt",
          "photos/2007/b.txt",
          "photos/sub%20dir/file%281%29.txt",
          "top.txt"
        ] do
      put_object(bucket, key, "x")
    end

    res =
      list_v2(bucket, %{
        "prefix" => "photos/",
        "delimiter" => "/",
        "encoding-type" => "url"
      })

    assert res.status == 200
    assert res.resp_body =~ "<EncodingType>url</EncodingType>"
    assert res.resp_body =~ "<Prefix>photos/</Prefix>"
    assert res.resp_body =~ "<Delimiter>/</Delimiter>"
    assert res.resp_body =~ "<CommonPrefixes><Prefix>photos/2006/</Prefix></CommonPrefixes>"
    assert res.resp_body =~ "<CommonPrefixes><Prefix>photos/2007/</Prefix></CommonPrefixes>"
    assert res.resp_body =~ "<CommonPrefixes><Prefix>photos/sub+dir/</Prefix></CommonPrefixes>"
    refute res.resp_body =~ "%2F"
    refute res.resp_body =~ "<Key>top.txt</Key>"
  end

  test "ListObjects V1 matrix uses marker, delimiter NextMarker, and V1 response shape" do
    bucket = "lcmv1"
    create_bucket(bucket)

    for key <- ~w(photos/2006/a.txt photos/2007/a.txt photos/2008/a.txt top.txt) do
      put_object(bucket, key, key)
    end

    first =
      list_v1(bucket, %{"prefix" => "photos/", "delimiter" => "/", "max-keys" => "2"})

    assert first.status == 200
    assert first.resp_body =~ "<Marker></Marker>"
    assert first.resp_body =~ "<MaxKeys>2</MaxKeys>"
    assert first.resp_body =~ "<IsTruncated>true</IsTruncated>"
    assert first.resp_body =~ "<CommonPrefixes><Prefix>photos/2006/</Prefix></CommonPrefixes>"
    assert first.resp_body =~ "<CommonPrefixes><Prefix>photos/2007/</Prefix></CommonPrefixes>"
    assert first.resp_body =~ "<NextMarker>photos/2007/</NextMarker>"
    refute first.resp_body =~ "<KeyCount>"
    refute first.resp_body =~ "<ContinuationToken>"

    second =
      list_v1(bucket, %{
        "prefix" => "photos/",
        "delimiter" => "/",
        "marker" => "photos/2007/"
      })

    assert second.status == 200
    assert second.resp_body =~ "<Marker>photos/2007/</Marker>"
    refute second.resp_body =~ "<CommonPrefixes><Prefix>photos/2007/</Prefix></CommonPrefixes>"
    assert second.resp_body =~ "<CommonPrefixes><Prefix>photos/2008/</Prefix></CommonPrefixes>"

    clamped = list_v1(bucket, %{"max-keys" => "5000"})
    assert clamped.resp_body =~ "<MaxKeys>1000</MaxKeys>"
    refute clamped.resp_body =~ "<MaxKeys>5000</MaxKeys>"
  end

  test "GET and HEAD conditional ETag matrix returns 304 or 412 without changing object bytes" do
    bucket = "lcmcondetag"
    key = "object.txt"

    create_bucket(bucket)
    put = put_object(bucket, key, "hello")
    [etag] = get_resp_header(put, "etag")

    get_not_modified = get_object(bucket, key, [{"if-none-match", etag}])
    assert get_not_modified.status == 304
    assert get_not_modified.resp_body == ""

    head_not_modified = head_object(bucket, key, [{"if-none-match", etag}])
    assert head_not_modified.status == 304
    assert head_not_modified.resp_body == ""

    get_precondition = get_object(bucket, key, [{"if-match", "\"wrong\""}])
    assert_s3_error(get_precondition, 412, "PreconditionFailed")

    head_precondition = head_object(bucket, key, [{"if-match", "\"wrong\""}])
    assert head_precondition.status == 412

    get_ok = get_object(bucket, key, [{"if-none-match", "\"not-current\""}])
    assert get_ok.status == 200
    assert get_ok.resp_body == "hello"
  end

  test "GET and HEAD conditional date precedence matrix follows S3 304/412 rules" do
    bucket = "lcmconddate"
    key = "object.txt"

    create_bucket(bucket)
    put = put_object(bucket, key, "dated")
    [etag] = get_resp_header(put, "etag")

    get_not_modified = get_object(bucket, key, [{"if-modified-since", @future_http_date}])
    assert get_not_modified.status == 304
    assert get_not_modified.resp_body == ""

    head_not_modified = head_object(bucket, key, [{"if-modified-since", @future_http_date}])
    assert head_not_modified.status == 304
    assert head_not_modified.resp_body == ""

    unmodified_failed = get_object(bucket, key, [{"if-unmodified-since", @old_http_date}])
    assert_s3_error(unmodified_failed, 412, "PreconditionFailed")

    if_match_wins =
      get_object(bucket, key, [
        {"if-match", etag},
        {"if-unmodified-since", @old_http_date}
      ])

    assert if_match_wins.status == 200
    assert if_match_wins.resp_body == "dated"

    invalid_date_ignored = get_object(bucket, key, [{"if-modified-since", "not-a-date"}])
    assert invalid_date_ignored.status == 200
    assert invalid_date_ignored.resp_body == "dated"
  end

  defp create_bucket(bucket) do
    conn = SigV4Request.signed_conn(:put, "/#{bucket}") |> call()
    assert conn.status == 200
    conn
  end

  defp put_object(bucket, key, body) do
    conn =
      SigV4Request.signed_conn(:put, "/#{bucket}/#{key}", body: body)
      |> call()

    assert conn.status == 200
    conn
  end

  defp list_v2(bucket, query) do
    SigV4Request.signed_conn(:get, "/#{bucket}", query: Map.put(query, "list-type", "2"))
    |> call()
  end

  defp list_v1(bucket, query) do
    SigV4Request.signed_conn(:get, "/#{bucket}", query: query)
    |> call()
  end

  defp get_object(bucket, key, headers) do
    SigV4Request.signed_conn(:get, "/#{bucket}/#{key}", headers: headers)
    |> call()
  end

  defp head_object(bucket, key, headers) do
    SigV4Request.signed_conn(:head, "/#{bucket}/#{key}", headers: headers)
    |> call()
  end

  defp assert_s3_error(conn, status, code) do
    assert conn.status == status
    assert conn.resp_body =~ "<Code>#{code}</Code>"
  end
end
