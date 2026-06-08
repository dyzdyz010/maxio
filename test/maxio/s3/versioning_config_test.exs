defmodule Maxio.S3.VersioningConfigTest do
  use Maxio.DataCase, async: false
  alias Maxio.Test.SigV4Request
  alias Maxio.S3.Endpoint

  defp call(conn), do: Endpoint.call(conn, Endpoint.init([]))

  test "never-set → GetBucketVersioning 返回空自闭元素（无 Status）" do
    SigV4Request.signed_conn(:put, "/cfgb") |> call()
    get = SigV4Request.signed_conn(:get, "/cfgb", query: %{"versioning" => ""}) |> call()
    assert get.status == 200
    refute get.resp_body =~ "<Status>"
    assert get.resp_body =~ "VersioningConfiguration"
  end

  test "Enable 后 Get 返回 Enabled；Suspend 后返回 Suspended" do
    SigV4Request.signed_conn(:put, "/cfgb2") |> call()

    SigV4Request.signed_conn(:put, "/cfgb2",
      query: %{"versioning" => ""},
      body: ~s(<VersioningConfiguration><Status>Enabled</Status></VersioningConfiguration>)
    )
    |> call()

    g1 = SigV4Request.signed_conn(:get, "/cfgb2", query: %{"versioning" => ""}) |> call()
    assert g1.resp_body =~ "<Status>Enabled</Status>"

    SigV4Request.signed_conn(:put, "/cfgb2",
      query: %{"versioning" => ""},
      body: ~s(<VersioningConfiguration><Status>Suspended</Status></VersioningConfiguration>)
    )
    |> call()

    g2 = SigV4Request.signed_conn(:get, "/cfgb2", query: %{"versioning" => ""}) |> call()
    assert g2.resp_body =~ "<Status>Suspended</Status>"
  end
end
