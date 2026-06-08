defmodule Maxio.S3.ListVersionsE2ETest do
  use Maxio.DataCase, async: false
  alias Maxio.Test.SigV4Request
  alias Maxio.S3.Endpoint

  @data_dir Path.join(System.tmp_dir!(), "maxio_listversions_e2e")

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

  test "Enabled 桶：PUT×2 + DELETE → ?versions 列出 2 Version + 1 DeleteMarker" do
    SigV4Request.signed_conn(:put, "/lvb") |> call()

    SigV4Request.signed_conn(:put, "/lvb",
      query: %{"versioning" => ""},
      body: ~s(<VersioningConfiguration><Status>Enabled</Status></VersioningConfiguration>)
    )
    |> call()

    SigV4Request.signed_conn(:put, "/lvb/k.txt", body: "v1") |> call()
    SigV4Request.signed_conn(:put, "/lvb/k.txt", body: "v2") |> call()
    SigV4Request.signed_conn(:delete, "/lvb/k.txt") |> call()

    lv = SigV4Request.signed_conn(:get, "/lvb", query: %{"versions" => ""}) |> call()
    assert lv.status == 200
    assert lv.resp_body =~ "ListVersionsResult"
    # 1 个 DeleteMarker（当前 latest）+ 2 个 Version
    assert lv.resp_body |> String.split("<DeleteMarker>") |> length() == 2
    assert lv.resp_body |> String.split("<Version>") |> length() == 3

    # ListObjectsV2 不返回 delete-marker 当前的对象
    lo = SigV4Request.signed_conn(:get, "/lvb") |> call()
    refute lo.resp_body =~ "<Key>k.txt</Key>"
  end
end
