defmodule Maxio.S3.EncodingTypeE2ETest do
  use Maxio.DataCase, async: false
  alias Maxio.Test.SigV4Request
  alias Maxio.S3.Endpoint

  @data_dir Path.join(System.tmp_dir!(), "maxio_encoding_type")

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

  test "ListObjectsV2 encoding-type=url → MinIO s3URLEncode：保留 key 内字面 '/'，空格→'+'，括号→%XX" do
    SigV4Request.signed_conn(:put, "/enc1") |> call()
    # key 含嵌套斜杠/空格/括号：sub a/test file(3).png（key 内字面 '/' 必须保留，不得编为 %2F）
    SigV4Request.signed_conn(:put, "/enc1/sub%20a/test%20file%283%29.png", body: "x") |> call()

    res =
      SigV4Request.signed_conn(:get, "/enc1", query: %{"encoding-type" => "url"}) |> call()

    assert res.status == 200
    assert res.resp_body =~ "<EncodingType>url</EncodingType>"
    # 全 <Key> 断言：key 内 '/' 保留字面，空格→'+'，括号→%28/%29（对齐 AWS/MinIO 线上字节，非 %2F）。
    assert res.resp_body =~ "<Key>sub+a/test+file%283%29.png</Key>"
    refute res.resp_body =~ "%2F"
  end

  test "ListObjectsV2 encoding-type=url + delimiter='/' → <Delimiter>/</Delimiter> 且 CommonPrefixes 保留 '/'" do
    SigV4Request.signed_conn(:put, "/enc3") |> call()
    # 伪目录：sub dir/leaf.txt —— delimiter '/' 应原样、CommonPrefixes 前缀末 '/' 应原样、空格→'+'。
    SigV4Request.signed_conn(:put, "/enc3/sub%20dir/leaf.txt", body: "x") |> call()

    res =
      SigV4Request.signed_conn(:get, "/enc3",
        query: %{"encoding-type" => "url", "delimiter" => "/"}
      )
      |> call()

    assert res.status == 200
    assert res.resp_body =~ "<EncodingType>url</EncodingType>"
    # Delimiter 必须是字面 '/'，绝非 %2F（否则破坏客户端伪目录语义）。
    assert res.resp_body =~ "<Delimiter>/</Delimiter>"
    # CommonPrefixes 内的末尾 '/' 保留字面，空格→'+'。
    assert res.resp_body =~ "<CommonPrefixes><Prefix>sub+dir/</Prefix></CommonPrefixes>"
    refute res.resp_body =~ "%2F"
  end

  test "ListObjectsV2 无 encoding-type → 不发 <EncodingType>，Key 原样" do
    SigV4Request.signed_conn(:put, "/enc2") |> call()
    SigV4Request.signed_conn(:put, "/enc2/plain.txt", body: "x") |> call()

    res = SigV4Request.signed_conn(:get, "/enc2") |> call()
    refute res.resp_body =~ "<EncodingType>"
    assert res.resp_body =~ "<Key>plain.txt</Key>"
  end

  test "ListObjectVersions encoding-type=url → <EncodingType>url</EncodingType> 且 Key percent-encode" do
    SigV4Request.signed_conn(:put, "/encv1") |> call()
    body = ~s(<VersioningConfiguration><Status>Enabled</Status></VersioningConfiguration>)
    SigV4Request.signed_conn(:put, "/encv1", query: %{"versioning" => ""}, body: body) |> call()
    SigV4Request.signed_conn(:put, "/encv1/sub%20v/test%20v%283%29.png", body: "x") |> call()

    res =
      SigV4Request.signed_conn(:get, "/encv1",
        query: %{"versions" => "", "encoding-type" => "url"}
      )
      |> call()

    assert res.status == 200
    assert res.resp_body =~ "<EncodingType>url</EncodingType>"
    # 全 <Key> 断言：key 内字面 '/' 保留，空格→'+'，括号→%XX（对齐 AWS/MinIO，非 %2F）。
    assert res.resp_body =~ "<Key>sub+v/test+v%283%29.png</Key>"
    refute res.resp_body =~ "%2F"
  end

  test "ListObjectVersions 无 encoding-type → 不发 <EncodingType>，Key 原样" do
    SigV4Request.signed_conn(:put, "/encv2") |> call()
    body = ~s(<VersioningConfiguration><Status>Enabled</Status></VersioningConfiguration>)
    SigV4Request.signed_conn(:put, "/encv2", query: %{"versioning" => ""}, body: body) |> call()
    SigV4Request.signed_conn(:put, "/encv2/plain.txt", body: "x") |> call()

    res = SigV4Request.signed_conn(:get, "/encv2", query: %{"versions" => ""}) |> call()
    assert res.status == 200
    refute res.resp_body =~ "<EncodingType>"
    assert res.resp_body =~ "<Key>plain.txt</Key>"
  end
end
