defmodule Maxio.S3.M4MatrixTest do
  @moduledoc "M4 跨特性端到端矩阵：versioning × tagging × sse × cors × authz 交叉。"
  use Maxio.DataCase, async: false
  import Plug.Conn
  alias Maxio.Test.SigV4Request
  alias Maxio.S3.Endpoint

  @data_dir Path.join(System.tmp_dir!(), "maxio_m4_matrix")

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

  test "版本化 + tagging：?tagging&versionId 作用于指定版本" do
    SigV4Request.signed_conn(:put, "/mxa") |> call()

    SigV4Request.signed_conn(:put, "/mxa",
      query: %{"versioning" => ""},
      body: ~s(<VersioningConfiguration><Status>Enabled</Status></VersioningConfiguration>)
    )
    |> call()

    p1 = SigV4Request.signed_conn(:put, "/mxa/k.txt", body: "v1") |> call()
    [vid1] = get_resp_header(p1, "x-amz-version-id")
    SigV4Request.signed_conn(:put, "/mxa/k.txt", body: "v2") |> call()

    tagging = ~s(<Tagging><TagSet><Tag><Key>v</Key><Value>one</Value></Tag></TagSet></Tagging>)

    put_t =
      SigV4Request.signed_conn(:put, "/mxa/k.txt",
        query: %{"tagging" => "", "versionId" => vid1},
        body: tagging
      )
      |> call()

    assert put_t.status == 200

    get_t =
      SigV4Request.signed_conn(:get, "/mxa/k.txt", query: %{"tagging" => "", "versionId" => vid1})
      |> call()

    assert get_t.resp_body =~ "<Value>one</Value>"

    # latest（v2）无该 tag
    get_latest =
      SigV4Request.signed_conn(:get, "/mxa/k.txt", query: %{"tagging" => ""}) |> call()

    refute get_latest.resp_body =~ "<Value>one</Value>"
  end

  test "版本化 + SSE：版本化桶里加密对象的多版本各自可解密" do
    SigV4Request.signed_conn(:put, "/mxa2") |> call()

    SigV4Request.signed_conn(:put, "/mxa2",
      query: %{"versioning" => ""},
      body: ~s(<VersioningConfiguration><Status>Enabled</Status></VersioningConfiguration>)
    )
    |> call()

    p1 =
      SigV4Request.signed_conn(:put, "/mxa2/s.txt",
        body: "secret-v1",
        headers: [{"x-amz-server-side-encryption", "AES256"}]
      )
      |> call()

    [vid1] = get_resp_header(p1, "x-amz-version-id")

    SigV4Request.signed_conn(:put, "/mxa2/s.txt",
      body: "secret-v2",
      headers: [{"x-amz-server-side-encryption", "AES256"}]
    )
    |> call()

    g_latest = SigV4Request.signed_conn(:get, "/mxa2/s.txt") |> call()
    assert g_latest.resp_body == "secret-v2"

    g_old = SigV4Request.signed_conn(:get, "/mxa2/s.txt", query: %{"versionId" => vid1}) |> call()
    assert g_old.resp_body == "secret-v1"
  end

  test "authz：匿名访问加 public-read policy 的版本化对象（最新版本）放行" do
    SigV4Request.signed_conn(:put, "/mxa3") |> call()

    SigV4Request.signed_conn(:put, "/mxa3",
      query: %{"versioning" => ""},
      body: ~s(<VersioningConfiguration><Status>Enabled</Status></VersioningConfiguration>)
    )
    |> call()

    SigV4Request.signed_conn(:put, "/mxa3/pub.txt", body: "open") |> call()

    pol =
      ~s({"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":"*","Action":"s3:GetObject","Resource":"arn:aws:s3:::mxa3/*"}]})

    SigV4Request.signed_conn(:put, "/mxa3",
      query: %{"policy" => ""},
      body: pol,
      headers: [{"content-type", "application/json"}]
    )
    |> call()

    anon = SigV4Request.anon_conn(:get, "/mxa3/pub.txt") |> call()
    assert anon.status == 200
    assert anon.resp_body == "open"
  end
end
