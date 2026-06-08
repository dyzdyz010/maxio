defmodule Maxio.S3.LifecycleE2ETest do
  use Maxio.DataCase, async: false
  alias Maxio.Test.SigV4Request
  alias Maxio.S3.Endpoint

  @lc ~s(<LifecycleConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Rule><ID>expire-tmp</ID><Filter><Prefix>tmp/</Prefix></Filter><Status>Enabled</Status><Expiration><Days>7</Days></Expiration></Rule></LifecycleConfiguration>)

  defp call(conn), do: Endpoint.call(conn, Endpoint.init([]))

  test "Put 200 → Get 回放（含 Prefix/Days/Status）→ Delete 204 → Get 404" do
    SigV4Request.signed_conn(:put, "/lcb") |> call()
    put = SigV4Request.signed_conn(:put, "/lcb", query: %{"lifecycle" => ""}, body: @lc) |> call()
    assert put.status == 200

    get = SigV4Request.signed_conn(:get, "/lcb", query: %{"lifecycle" => ""}) |> call()
    assert get.status == 200
    assert get.resp_body =~ "expire-tmp"
    assert get.resp_body =~ "<Prefix>tmp/</Prefix>"
    assert get.resp_body =~ "<Days>7</Days>"
    assert get.resp_body =~ "<Status>Enabled</Status>"

    del = SigV4Request.signed_conn(:delete, "/lcb", query: %{"lifecycle" => ""}) |> call()
    assert del.status == 204

    g2 = SigV4Request.signed_conn(:get, "/lcb", query: %{"lifecycle" => ""}) |> call()
    assert g2.status == 404
    assert g2.resp_body =~ "NoSuchLifecycleConfiguration"
  end

  test "Expiration 同时 Days+Date → 400" do
    SigV4Request.signed_conn(:put, "/lcb2") |> call()

    bad =
      ~s(<LifecycleConfiguration><Rule><Status>Enabled</Status><Filter></Filter><Expiration><Days>7</Days><Date>2026-01-01T00:00:00.000Z</Date></Expiration></Rule></LifecycleConfiguration>)

    res =
      SigV4Request.signed_conn(:put, "/lcb2", query: %{"lifecycle" => ""}, body: bad) |> call()

    assert res.status == 400
  end
end
