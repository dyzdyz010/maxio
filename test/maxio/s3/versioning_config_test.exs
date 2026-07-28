defmodule Maxio.S3.VersioningConfigTest do
  use Maxio.DataCase, async: false
  alias Maxio.Test.SigV4Request
  alias Maxio.S3.Endpoint

  defp call(conn), do: Endpoint.call(conn, Endpoint.init([]))

  defp versioning_xml(status) do
    ~s(<VersioningConfiguration><Status>#{status}</Status></VersioningConfiguration>)
  end

  defp checksum_b64(algorithm, body), do: :crypto.hash(algorithm, body) |> Base.encode64()

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

  test "Put/GetBucketVersioning validate Content-MD5, checksum trailers, and expected owner" do
    bucket = "cfgchecksum"
    enabled = versioning_xml("Enabled")
    suspended = versioning_xml("Suspended")

    SigV4Request.signed_conn(:put, "/#{bucket}") |> call()

    missing_md5 =
      SigV4Request.signed_conn(:put, "/#{bucket}",
        query: %{"versioning" => ""},
        body: enabled,
        auto_content_md5: false
      )
      |> call()

    assert missing_md5.status == 400
    assert missing_md5.resp_body =~ "<Code>MissingSecurityHeader</Code>"

    get_empty =
      SigV4Request.signed_conn(:get, "/#{bucket}", query: %{"versioning" => ""}) |> call()

    assert get_empty.status == 200
    refute get_empty.resp_body =~ "<Status>"

    bad_md5 =
      SigV4Request.signed_conn(:put, "/#{bucket}",
        query: %{"versioning" => ""},
        body: enabled,
        headers: [{"content-md5", checksum_b64(:md5, "different")}]
      )
      |> call()

    assert bad_md5.status == 400
    assert bad_md5.resp_body =~ "<Code>BadDigest</Code>"

    good_auto_md5 =
      SigV4Request.signed_conn(:put, "/#{bucket}",
        query: %{"versioning" => ""},
        body: enabled
      )
      |> call()

    assert good_auto_md5.status == 200

    assert (SigV4Request.signed_conn(:get, "/#{bucket}", query: %{"versioning" => ""})
            |> call()).resp_body =~ "<Status>Enabled</Status>"

    bad_trailer =
      SigV4Request.signed_chunked_conn(:put, "/#{bucket}", suspended,
        query: %{"versioning" => ""},
        headers: [
          {"content-md5", checksum_b64(:md5, suspended)},
          {"x-amz-sdk-checksum-algorithm", "SHA256"}
        ],
        trailer_headers: [{"x-amz-checksum-sha256", checksum_b64(:sha256, "different")}]
      )
      |> call()

    assert bad_trailer.status == 400
    assert bad_trailer.resp_body =~ "<Code>BadDigest</Code>"

    assert (SigV4Request.signed_conn(:get, "/#{bucket}", query: %{"versioning" => ""})
            |> call()).resp_body =~ "<Status>Enabled</Status>"

    ok_trailer =
      SigV4Request.signed_chunked_conn(:put, "/#{bucket}", suspended,
        query: %{"versioning" => ""},
        headers: [
          {"content-md5", checksum_b64(:md5, suspended)},
          {"x-amz-sdk-checksum-algorithm", "SHA256"}
        ],
        trailer_headers: [{"x-amz-checksum-sha256", checksum_b64(:sha256, suspended)}]
      )
      |> call()

    assert ok_trailer.status == 200

    assert (SigV4Request.signed_conn(:get, "/#{bucket}", query: %{"versioning" => ""})
            |> call()).resp_body =~ "<Status>Suspended</Status>"

    wrong_put =
      SigV4Request.signed_conn(:put, "/#{bucket}",
        query: %{"versioning" => ""},
        body: enabled,
        headers: [{"x-amz-expected-bucket-owner", "111111111111"}]
      )
      |> call()

    assert wrong_put.status == 403

    assert (SigV4Request.signed_conn(:get, "/#{bucket}", query: %{"versioning" => ""})
            |> call()).resp_body =~ "<Status>Suspended</Status>"

    wrong_get =
      SigV4Request.signed_conn(:get, "/#{bucket}",
        query: %{"versioning" => ""},
        headers: [{"x-amz-expected-bucket-owner", "111111111111"}]
      )
      |> call()

    assert wrong_get.status == 403
  end

  test "malformed strict versioning XML does not overwrite existing state" do
    bucket = "cfgstrict"
    enabled = versioning_xml("Enabled")

    SigV4Request.signed_conn(:put, "/#{bucket}") |> call()

    assert (SigV4Request.signed_conn(:put, "/#{bucket}",
              query: %{"versioning" => ""},
              body: enabled
            )
            |> call()).status == 200

    bad_unknown =
      SigV4Request.signed_conn(:put, "/#{bucket}",
        query: %{"versioning" => ""},
        body: ~s(<VersioningConfiguration><Unknown>Suspended</Unknown></VersioningConfiguration>)
      )
      |> call()

    assert bad_unknown.status == 400
    assert bad_unknown.resp_body =~ "<Code>MalformedXML</Code>"

    get_enabled =
      SigV4Request.signed_conn(:get, "/#{bucket}", query: %{"versioning" => ""}) |> call()

    assert get_enabled.status == 200
    assert get_enabled.resp_body =~ "<Status>Enabled</Status>"

    bad_duplicate =
      SigV4Request.signed_conn(:put, "/#{bucket}",
        query: %{"versioning" => ""},
        body:
          ~s(<VersioningConfiguration><Status>Suspended</Status><Status>Enabled</Status></VersioningConfiguration>)
      )
      |> call()

    assert bad_duplicate.status == 400
    assert bad_duplicate.resp_body =~ "<Code>MalformedXML</Code>"

    get_still_enabled =
      SigV4Request.signed_conn(:get, "/#{bucket}", query: %{"versioning" => ""}) |> call()

    assert get_still_enabled.status == 200
    assert get_still_enabled.resp_body =~ "<Status>Enabled</Status>"
  end
end
