defmodule Maxio.S3.MetricsE2ETest do
  use Maxio.DataCase, async: false

  import Plug.Conn

  alias Maxio.Auth.CredentialStore
  alias Maxio.BucketConfigs
  alias Maxio.Policy.Store
  alias Maxio.S3.Endpoint
  alias Maxio.Test.SigV4Request

  @data_dir Path.join(System.tmp_dir!(), "maxio_metrics_e2e")
  @alice_ak "AKIAMETRICS000001"
  @alice_secret "metricsmetrics123456789"
  @alice_arn "arn:aws:iam:::user/" <> @alice_ak

  @entire """
  <MetricsConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
    <Id>entire</Id>
  </MetricsConfiguration>
  """
  @prefix """
  <MetricsConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
    <Id>docs</Id>
    <Filter><Prefix>documents/</Prefix></Filter>
  </MetricsConfiguration>
  """
  @tagged """
  <MetricsConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
    <Id>tagged</Id>
    <Filter>
      <And>
        <Prefix>documents/</Prefix>
        <Tag><Key>class</Key><Value>blue</Value></Tag>
      </And>
    </Filter>
  </MetricsConfiguration>
  """

  setup do
    File.rm_rf(@data_dir)
    File.mkdir_p!(@data_dir)
    prev = Application.get_env(:maxio, :s3)
    Application.put_env(:maxio, :s3, Keyword.put(prev, :data_dir, @data_dir))

    :ok =
      CredentialStore.put_access_key(%{
        access_key: @alice_ak,
        secret_key: @alice_secret,
        principal: %{type: :iam_user, access_key: @alice_ak, arn: @alice_arn}
      })

    on_exit(fn ->
      Application.put_env(:maxio, :s3, prev)
      File.rm_rf(@data_dir)
    end)

    :ok
  end

  defp call(conn), do: Endpoint.call(conn, Endpoint.init([]))

  defp alice(method, path, opts) do
    SigV4Request.signed_conn(
      method,
      path,
      Keyword.merge([access_key: @alice_ak, secret: @alice_secret], opts)
    )
  end

  defp create_bucket(bucket), do: SigV4Request.signed_conn(:put, "/#{bucket}") |> call()

  defp put_metrics(bucket, id, body, opts \\ []) do
    SigV4Request.signed_conn(:put, "/#{bucket}",
      query: %{"metrics" => "", "id" => id},
      body: body,
      headers: Keyword.get(opts, :headers, [])
    )
    |> call()
  end

  defp get_metrics(bucket, id, opts \\ []) do
    SigV4Request.signed_conn(:get, "/#{bucket}",
      query: %{"metrics" => "", "id" => id},
      headers: Keyword.get(opts, :headers, [])
    )
    |> call()
  end

  defp delete_metrics(bucket, id, opts \\ []) do
    SigV4Request.signed_conn(:delete, "/#{bucket}",
      query: %{"metrics" => "", "id" => id},
      headers: Keyword.get(opts, :headers, [])
    )
    |> call()
  end

  test "put get list and delete metrics configurations by id" do
    assert create_bucket("metricscfg").status == 200

    missing = get_metrics("metricscfg", "entire")
    assert missing.status == 404
    assert missing.resp_body =~ "NoSuchConfiguration"

    put = put_metrics("metricscfg", "entire", @entire)
    assert put.status == 200
    assert put.resp_body == ""

    assert {:ok, %{"Configurations" => [%{"Id" => "entire"}]}} =
             BucketConfigs.get("metricscfg", :metrics)

    get = get_metrics("metricscfg", "entire")
    assert get.status == 200
    assert get_resp_header(get, "content-type") |> hd() =~ "application/xml"
    assert get.resp_body =~ "<MetricsConfiguration"
    assert get.resp_body =~ "<Id>entire</Id>"

    assert put_metrics("metricscfg", "docs", @prefix).status == 200

    list =
      SigV4Request.signed_conn(:get, "/metricscfg", query: %{"metrics" => ""})
      |> call()

    assert list.status == 200
    assert list.resp_body =~ "<ListMetricsConfigurationsResult"
    assert list.resp_body =~ "<Id>docs</Id>"
    assert list.resp_body =~ "<Id>entire</Id>"
    assert list.resp_body =~ "<IsTruncated>false</IsTruncated>"

    deleted = delete_metrics("metricscfg", "entire")
    assert deleted.status == 204

    assert {:ok, %{"Configurations" => [%{"Id" => "docs"}]}} =
             BucketConfigs.get("metricscfg", :metrics)

    assert get_metrics("metricscfg", "entire").status == 404
    assert get_metrics("metricscfg", "docs").status == 200
  end

  test "list paginates at 100 configurations with continuation token" do
    assert create_bucket("metricspage").status == 200

    configs =
      for n <- 1..101 do
        id = "cfg#{String.pad_leading(Integer.to_string(n), 3, "0")}"
        %{"Id" => id}
      end

    assert :ok = BucketConfigs.put("metricspage", :metrics, %{"Configurations" => configs})

    first =
      SigV4Request.signed_conn(:get, "/metricspage", query: %{"metrics" => ""})
      |> call()

    assert first.status == 200
    assert first.resp_body =~ "<IsTruncated>true</IsTruncated>"
    assert first.resp_body =~ "<NextContinuationToken>cfg100</NextContinuationToken>"
    refute first.resp_body =~ "<Id>cfg101</Id>"

    second =
      SigV4Request.signed_conn(:get, "/metricspage",
        query: %{"metrics" => "", "continuation-token" => "cfg100"}
      )
      |> call()

    assert second.status == 200
    assert second.resp_body =~ "<ContinuationToken>cfg100</ContinuationToken>"
    assert second.resp_body =~ "<Id>cfg101</Id>"
    assert second.resp_body =~ "<IsTruncated>false</IsTruncated>"

    invalid =
      SigV4Request.signed_conn(:get, "/metricspage",
        query: %{"metrics" => "", "continuation-token" => "missing"}
      )
      |> call()

    assert invalid.status == 400
    assert invalid.resp_body =~ "InvalidArgument"
  end

  test "missing id mismatched XML id malformed XML and checksums fail closed" do
    assert create_bucket("metricsbad").status == 200
    assert put_metrics("metricsbad", "entire", @entire).status == 200

    missing_id =
      SigV4Request.signed_conn(:put, "/metricsbad",
        query: %{"metrics" => ""},
        body: @entire
      )
      |> call()

    assert missing_id.status == 400
    assert missing_id.resp_body =~ "InvalidArgument"

    mismatch = put_metrics("metricsbad", "docs", @entire)
    assert mismatch.status == 400
    assert mismatch.resp_body =~ "MalformedXML"

    bad_xml =
      put_metrics(
        "metricsbad",
        "docs",
        "<MetricsConfiguration><Id>docs</Id><Bad /></MetricsConfiguration>"
      )

    assert bad_xml.status == 400
    assert bad_xml.resp_body =~ "MalformedXML"

    bad_checksum =
      put_metrics("metricsbad", "docs", @prefix,
        headers: [
          {"x-amz-sdk-checksum-algorithm", "SHA256"},
          {"x-amz-checksum-sha256", :crypto.hash(:sha256, "different") |> Base.encode64()}
        ]
      )

    assert bad_checksum.status == 400
    assert bad_checksum.resp_body =~ "BadDigest"

    bad_content_md5 =
      put_metrics("metricsbad", "docs", @prefix,
        headers: [{"content-md5", :crypto.hash(:md5, "different") |> Base.encode64()}]
      )

    assert bad_content_md5.status == 400
    assert bad_content_md5.resp_body =~ "BadDigest"

    assert {:ok, %{"Configurations" => [%{"Id" => "entire"}]}} =
             BucketConfigs.get("metricsbad", :metrics)
  end

  test "checksum trailers and aws-chunked XML bodies are validated" do
    assert create_bucket("metricschunked").status == 200

    plain_trailer =
      put_metrics("metricschunked", "entire", @entire,
        headers: [
          {"x-amz-sdk-checksum-algorithm", "SHA256"},
          {"x-amz-trailer", "x-amz-checksum-sha256"}
        ]
      )

    assert plain_trailer.status == 400
    assert plain_trailer.resp_body =~ "InvalidRequest"

    bad =
      SigV4Request.signed_chunked_conn(:put, "/metricschunked", @entire,
        query: %{"metrics" => "", "id" => "entire"},
        headers: [{"x-amz-sdk-checksum-algorithm", "SHA256"}],
        trailer_headers: [
          {"x-amz-checksum-sha256", :crypto.hash(:sha256, "different") |> Base.encode64()}
        ]
      )
      |> call()

    assert bad.status == 400
    assert bad.resp_body =~ "BadDigest"
    assert BucketConfigs.get("metricschunked", :metrics) == :none

    ok =
      SigV4Request.signed_chunked_conn(:put, "/metricschunked", @entire,
        query: %{"metrics" => "", "id" => "entire"},
        headers: [{"x-amz-sdk-checksum-algorithm", "SHA256"}],
        trailer_headers: [
          {"x-amz-checksum-sha256", :crypto.hash(:sha256, @entire) |> Base.encode64()}
        ]
      )
      |> call()

    assert ok.status == 200

    assert {:ok, %{"Configurations" => [%{"Id" => "entire"}]}} =
             BucketConfigs.get("metricschunked", :metrics)
  end

  test "expected bucket owner missing bucket and method boundaries are enforced" do
    assert create_bucket("metricsowner").status == 200
    assert put_metrics("metricsowner", "entire", @entire).status == 200

    wrong_get =
      get_metrics("metricsowner", "entire",
        headers: [{"x-amz-expected-bucket-owner", "999999999999"}]
      )

    assert wrong_get.status == 403
    assert wrong_get.resp_body =~ "AccessDenied"

    wrong_put =
      put_metrics("metricsowner", "docs", @prefix,
        headers: [{"x-amz-expected-bucket-owner", "999999999999"}]
      )

    assert wrong_put.status == 403

    wrong_delete =
      delete_metrics("metricsowner", "entire",
        headers: [{"x-amz-expected-bucket-owner", "999999999999"}]
      )

    assert wrong_delete.status == 403

    missing = put_metrics("missing-metrics", "entire", @entire)
    assert missing.status == 404
    assert missing.resp_body =~ "NoSuchBucket"

    object_get =
      SigV4Request.signed_conn(:get, "/metricsowner/object.txt", query: %{"metrics" => ""})
      |> call()

    assert object_get.status == 405
    assert object_get.resp_body =~ "MethodNotAllowed"

    post =
      SigV4Request.signed_conn(:post, "/metricsowner", query: %{"metrics" => ""})
      |> call()

    assert post.status == 405
  end

  test "metrics IAM actions and resource tag condition behavior match AWS action map" do
    assert create_bucket("metricsauthz").status == 200
    assert put_metrics("metricsauthz", "entire", @entire).status == 200

    get_policy =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:GetMetricsConfiguration","Resource":"arn:aws:s3:::metricsauthz"}})

    assert :ok = Store.put_principal_policy(@alice_arn, "get-metrics-only", get_policy)

    assert (alice(:get, "/metricsauthz", query: %{"metrics" => ""}) |> call()).status == 200

    assert (alice(:get, "/metricsauthz", query: %{"metrics" => "", "id" => "entire"})
            |> call()).status == 200

    denied_put =
      alice(:put, "/metricsauthz", query: %{"metrics" => "", "id" => "tagged"}, body: @tagged)
      |> call()

    assert denied_put.status == 403

    denied_delete =
      alice(:delete, "/metricsauthz", query: %{"metrics" => "", "id" => "entire"})
      |> call()

    assert denied_delete.status == 403

    put_policy =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:PutMetricsConfiguration","Resource":"arn:aws:s3:::metricsauthz"}})

    assert :ok = Store.put_principal_policy(@alice_arn, "put-metrics", put_policy)

    allowed_put =
      alice(:put, "/metricsauthz", query: %{"metrics" => "", "id" => "tagged"}, body: @tagged)
      |> call()

    assert allowed_put.status == 200

    allowed_delete =
      alice(:delete, "/metricsauthz", query: %{"metrics" => "", "id" => "tagged"})
      |> call()

    assert allowed_delete.status == 204

    tag_xml = "<Tagging><TagSet><Tag><Key>env</Key><Value>prod</Value></Tag></TagSet></Tagging>"

    assert (SigV4Request.signed_conn(:put, "/metricsauthz",
              query: %{"tagging" => ""},
              body: tag_xml
            )
            |> call()).status == 204

    assert :ok = Store.delete_principal_policy(@alice_arn, "get-metrics-only")
    assert :ok = Store.delete_principal_policy(@alice_arn, "put-metrics")

    resource_tag_policy =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:GetMetricsConfiguration","Resource":"arn:aws:s3:::metricsauthz","Condition":{"StringEquals":{"aws:ResourceTag/env":"prod"}}}})

    assert :ok =
             Store.put_principal_policy(
               @alice_arn,
               "get-metrics-resource-tag",
               resource_tag_policy
             )

    denied_by_tag_condition =
      alice(:get, "/metricsauthz", query: %{"metrics" => "", "id" => "entire"}) |> call()

    assert denied_by_tag_condition.status == 403
  end
end
