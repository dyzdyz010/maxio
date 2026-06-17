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

  test "Transition Date 不会被回放为 Expiration Date" do
    SigV4Request.signed_conn(:put, "/lcb3") |> call()

    xml =
      ~s(<LifecycleConfiguration><Rule><ID>transition-only</ID><Status>Enabled</Status><Filter><Prefix>cold/</Prefix></Filter><Transition><Date>2026-12-31T00:00:00Z</Date><StorageClass>GLACIER</StorageClass></Transition></Rule></LifecycleConfiguration>)

    put =
      SigV4Request.signed_conn(:put, "/lcb3", query: %{"lifecycle" => ""}, body: xml) |> call()

    assert put.status == 200

    get = SigV4Request.signed_conn(:get, "/lcb3", query: %{"lifecycle" => ""}) |> call()
    assert get.status == 200
    assert get.resp_body =~ "<Transition>"
    assert get.resp_body =~ "<Date>2026-12-31T00:00:00Z</Date>"
    refute get.resp_body =~ "<Expiration>"
  end

  test "非法 Transition storage class → 400，不能存成不可执行规则" do
    SigV4Request.signed_conn(:put, "/lcb3bad") |> call()

    bad =
      ~s(<LifecycleConfiguration><Rule><Status>Enabled</Status><Filter></Filter><Transition><Days>1</Days><StorageClass>STANDARD</StorageClass></Transition></Rule></LifecycleConfiguration>)

    res =
      SigV4Request.signed_conn(:put, "/lcb3bad", query: %{"lifecycle" => ""}, body: bad)
      |> call()

    assert res.status == 400
  end

  test "Transition Days=0 对 Glacier 目标合法但对 IA 目标需满足最小天数" do
    SigV4Request.signed_conn(:put, "/lcb3days") |> call()

    ok =
      ~s(<LifecycleConfiguration><Rule><Status>Enabled</Status><Filter></Filter><Transition><Days>0</Days><StorageClass>GLACIER</StorageClass></Transition></Rule></LifecycleConfiguration>)

    assert (SigV4Request.signed_conn(:put, "/lcb3days", query: %{"lifecycle" => ""}, body: ok)
            |> call()).status == 200

    bad =
      ~s(<LifecycleConfiguration><Rule><Status>Enabled</Status><Filter></Filter><Transition><Days>1</Days><StorageClass>STANDARD_IA</StorageClass></Transition></Rule></LifecycleConfiguration>)

    assert (SigV4Request.signed_conn(:put, "/lcb3days", query: %{"lifecycle" => ""}, body: bad)
            |> call()).status == 400
  end

  test "非法对象大小 filter → 400，不能静默放宽删除选择器" do
    SigV4Request.signed_conn(:put, "/lcb4") |> call()

    bad =
      ~s(<LifecycleConfiguration><Rule><Status>Enabled</Status><Filter><ObjectSizeGreaterThan>100MB</ObjectSizeGreaterThan></Filter><Expiration><Days>1</Days></Expiration></Rule></LifecycleConfiguration>)

    res =
      SigV4Request.signed_conn(:put, "/lcb4", query: %{"lifecycle" => ""}, body: bad) |> call()

    assert res.status == 400
  end

  test "不完整 tag filter → 400，不能静默丢弃 tag 约束" do
    SigV4Request.signed_conn(:put, "/lcb5") |> call()

    bad =
      ~s(<LifecycleConfiguration><Rule><Status>Enabled</Status><Filter><Tag><Key>class</Key></Tag></Filter><Expiration><Days>1</Days></Expiration></Rule></LifecycleConfiguration>)

    res =
      SigV4Request.signed_conn(:put, "/lcb5", query: %{"lifecycle" => ""}, body: bad) |> call()

    assert res.status == 400
  end

  test "NewerNoncurrentVersions 无 Filter → 400（AWS 要求显式 Filter）" do
    SigV4Request.signed_conn(:put, "/lcb6") |> call()

    bad =
      ~s(<LifecycleConfiguration><Rule><Status>Enabled</Status><NoncurrentVersionExpiration><NoncurrentDays>30</NoncurrentDays><NewerNoncurrentVersions>5</NewerNoncurrentVersions></NoncurrentVersionExpiration></Rule></LifecycleConfiguration>)

    res =
      SigV4Request.signed_conn(:put, "/lcb6", query: %{"lifecycle" => ""}, body: bad) |> call()

    assert res.status == 400
  end

  test "NewerNoncurrentVersions 不能用 legacy Prefix 代替 Filter" do
    SigV4Request.signed_conn(:put, "/lcb9") |> call()

    bad =
      ~s(<LifecycleConfiguration><Rule><Status>Enabled</Status><Prefix>logs/</Prefix><NoncurrentVersionExpiration><NoncurrentDays>30</NoncurrentDays><NewerNoncurrentVersions>5</NewerNoncurrentVersions></NoncurrentVersionExpiration></Rule></LifecycleConfiguration>)

    res =
      SigV4Request.signed_conn(:put, "/lcb9", query: %{"lifecycle" => ""}, body: bad) |> call()

    assert res.status == 400
  end

  test "NewerNoncurrentVersions 超过 100 → 400" do
    SigV4Request.signed_conn(:put, "/lcb7") |> call()

    bad =
      ~s(<LifecycleConfiguration><Rule><Status>Enabled</Status><Filter></Filter><NoncurrentVersionExpiration><NoncurrentDays>30</NoncurrentDays><NewerNoncurrentVersions>101</NewerNoncurrentVersions></NoncurrentVersionExpiration></Rule></LifecycleConfiguration>)

    res =
      SigV4Request.signed_conn(:put, "/lcb7", query: %{"lifecycle" => ""}, body: bad) |> call()

    assert res.status == 400
  end

  test "NewerNoncurrentVersions 带 Filter 且 1..100 → 200" do
    SigV4Request.signed_conn(:put, "/lcb8") |> call()

    xml =
      ~s(<LifecycleConfiguration><Rule><Status>Enabled</Status><Filter></Filter><NoncurrentVersionExpiration><NoncurrentDays>30</NoncurrentDays><NewerNoncurrentVersions>100</NewerNoncurrentVersions></NoncurrentVersionExpiration></Rule></LifecycleConfiguration>)

    res =
      SigV4Request.signed_conn(:put, "/lcb8", query: %{"lifecycle" => ""}, body: xml) |> call()

    assert res.status == 200
  end

  test "NoncurrentVersionTransition NewerNoncurrentVersions 同样要求 Filter" do
    SigV4Request.signed_conn(:put, "/lcb10") |> call()

    bad =
      ~s(<LifecycleConfiguration><Rule><Status>Enabled</Status><NoncurrentVersionTransition><NoncurrentDays>30</NoncurrentDays><NewerNoncurrentVersions>5</NewerNoncurrentVersions><StorageClass>GLACIER</StorageClass></NoncurrentVersionTransition></Rule></LifecycleConfiguration>)

    res =
      SigV4Request.signed_conn(:put, "/lcb10", query: %{"lifecycle" => ""}, body: bad) |> call()

    assert res.status == 400
  end

  test "NoncurrentVersionTransition NewerNoncurrentVersions 不能缺 NoncurrentDays" do
    SigV4Request.signed_conn(:put, "/lcb10days") |> call()

    bad =
      ~s(<LifecycleConfiguration><Rule><Status>Enabled</Status><Filter></Filter><NoncurrentVersionTransition><NewerNoncurrentVersions>5</NewerNoncurrentVersions><StorageClass>GLACIER</StorageClass></NoncurrentVersionTransition></Rule></LifecycleConfiguration>)

    res =
      SigV4Request.signed_conn(:put, "/lcb10days", query: %{"lifecycle" => ""}, body: bad)
      |> call()

    assert res.status == 400
  end

  test "NoncurrentVersionTransition NewerNoncurrentVersions 回放仍留在 transition 下" do
    SigV4Request.signed_conn(:put, "/lcb11") |> call()

    xml =
      ~s(<LifecycleConfiguration><Rule><Status>Enabled</Status><Filter></Filter><NoncurrentVersionTransition><NoncurrentDays>30</NoncurrentDays><NewerNoncurrentVersions>5</NewerNoncurrentVersions><StorageClass>GLACIER</StorageClass></NoncurrentVersionTransition></Rule></LifecycleConfiguration>)

    put =
      SigV4Request.signed_conn(:put, "/lcb11", query: %{"lifecycle" => ""}, body: xml) |> call()

    assert put.status == 200

    get = SigV4Request.signed_conn(:get, "/lcb11", query: %{"lifecycle" => ""}) |> call()
    assert get.status == 200
    assert get.resp_body =~ "<NoncurrentVersionTransition>"
    assert get.resp_body =~ "<NewerNoncurrentVersions>5</NewerNoncurrentVersions>"
    refute get.resp_body =~ "<NoncurrentVersionExpiration>"
  end
end
