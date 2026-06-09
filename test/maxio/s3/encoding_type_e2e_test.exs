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

  test "ListObjectsV2 encoding-type=url → 含 <EncodingType>url</EncodingType> 且 Key percent-encode" do
    SigV4Request.signed_conn(:put, "/enc1") |> call()
    # key 含括号/空格：test file(3).png
    SigV4Request.signed_conn(:put, "/enc1/test%20file%283%29.png", body: "x") |> call()

    res =
      SigV4Request.signed_conn(:get, "/enc1", query: %{"encoding-type" => "url"}) |> call()

    assert res.status == 200
    assert res.resp_body =~ "<EncodingType>url</EncodingType>"
    assert res.resp_body =~ "test%20file%283%29.png"
  end

  test "ListObjectsV2 无 encoding-type → 不发 <EncodingType>，Key 原样" do
    SigV4Request.signed_conn(:put, "/enc2") |> call()
    SigV4Request.signed_conn(:put, "/enc2/plain.txt", body: "x") |> call()

    res = SigV4Request.signed_conn(:get, "/enc2") |> call()
    refute res.resp_body =~ "<EncodingType>"
    assert res.resp_body =~ "<Key>plain.txt</Key>"
  end
end
