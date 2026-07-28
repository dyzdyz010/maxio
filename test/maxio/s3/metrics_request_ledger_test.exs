defmodule Maxio.S3.MetricsRequestLedgerTest do
  use Maxio.DataCase, async: false

  alias Maxio.BucketConfigs
  alias Maxio.Buckets
  alias Maxio.Auth.SigV4.PostPolicy
  alias Maxio.S3.Endpoint
  alias Maxio.S3.Metrics.RequestMetric
  alias Maxio.S3.Metrics.RequestMetrics
  alias Maxio.Test.SigV4Request

  @access_key "AKIAIOSFODNN7EXAMPLE"
  @secret "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
  @data_dir Path.join(System.tmp_dir!(), "maxio_metrics_request_ledger")

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

    on_exit(fn ->
      Application.put_env(:maxio, :s3, prev)
      File.rm_rf(@data_dir)
    end)

    :ok
  end

  test "direct ledger upsert accumulates count bytes and latency min max" do
    assert {:ok, _bucket} = Buckets.create("metricsagg", "arn:aws:iam:::root")

    assert :ok =
             BucketConfigs.put("metricsagg", :metrics, %{
               "Configurations" => [%{"Id" => "entire"}]
             })

    event = %{
      bucket: "metricsagg",
      key: "documents/a.txt",
      operation: "get_object",
      metric_family: "get",
      status_code: 200,
      status_class: "2xx",
      window_started_at: ~U[2026-06-30 01:23:00.000000Z],
      latency_ms: 7,
      bytes_uploaded: 0,
      bytes_downloaded: 5,
      tags: %{}
    }

    assert :ok = RequestMetrics.record_event(event)
    assert :ok = RequestMetrics.record_event(%{event | latency_ms: 2, bytes_downloaded: 3})

    row = metric!("metricsagg", "entire", "get_object", 200)
    assert row.request_count == 2
    assert row.bytes_downloaded_sum == 8
    assert row.latency_ms_sum == 9
    assert row.latency_ms_min == 2
    assert row.latency_ms_max == 7
  end

  test "direct ledger upsert is atomic for same dimension under concurrency" do
    assert {:ok, _bucket} = Buckets.create("metricsrace", "arn:aws:iam:::root")

    assert :ok =
             BucketConfigs.put("metricsrace", :metrics, %{
               "Configurations" => [%{"Id" => "entire"}]
             })

    event = %{
      bucket: "metricsrace",
      key: "documents/race.txt",
      operation: "put_object",
      metric_family: "put",
      status_code: 200,
      status_class: "2xx",
      window_started_at: ~U[2026-06-30 01:25:00.000000Z],
      latency_ms: 3,
      bytes_uploaded: 11,
      bytes_downloaded: 0,
      tags: %{}
    }

    1..20
    |> Task.async_stream(fn _ -> RequestMetrics.record_event(event) end,
      max_concurrency: 8,
      timeout: :infinity
    )
    |> Enum.each(fn result -> assert result == {:ok, :ok} end)

    row = metric!("metricsrace", "entire", "put_object", 200)
    assert row.request_count == 20
    assert row.bytes_uploaded_sum == 220
    assert row.latency_ms_sum == 60
    assert row.latency_ms_min == 3
    assert row.latency_ms_max == 3
  end

  test "streams groups recent bucket filter streams without merging filter ids" do
    insert_metric!(
      bucket: "metricsdash",
      filter_id: "entire",
      window_started_at: ~U[2026-06-30 02:01:00.000000Z],
      operation: "get_object",
      request_count: 2,
      last_seen_at: ~U[2026-06-30 02:01:05.000000Z]
    )

    insert_metric!(
      bucket: "metricsdash",
      filter_id: "entire",
      window_started_at: ~U[2026-06-30 02:02:00.000000Z],
      operation: "put_object",
      request_count: 3,
      last_seen_at: ~U[2026-06-30 02:02:05.000000Z]
    )

    insert_metric!(
      bucket: "metricsdash",
      filter_id: "docs",
      window_started_at: ~U[2026-06-30 02:03:00.000000Z],
      operation: "get_object",
      request_count: 7,
      last_seen_at: ~U[2026-06-30 02:03:05.000000Z]
    )

    streams = RequestMetrics.streams(limit: 10)

    assert Enum.map(streams, &{&1.bucket, &1.filter_id, &1.request_count}) == [
             {"metricsdash", "docs", 7},
             {"metricsdash", "entire", 5}
           ]
  end

  test "timeseries fills empty minutes and isolates the selected filter id" do
    insert_metric!(
      bucket: "metricsts",
      filter_id: "entire",
      window_started_at: ~U[2026-06-30 02:02:00.000000Z],
      operation: "get_object",
      status_code: 200,
      status_class: "2xx",
      request_count: 2,
      bytes_downloaded_sum: 12,
      latency_ms_sum: 10,
      latency_ms_max: 7
    )

    insert_metric!(
      bucket: "metricsts",
      filter_id: "entire",
      window_started_at: ~U[2026-06-30 02:02:00.000000Z],
      operation: "get_object",
      status_code: 500,
      status_class: "5xx",
      request_count: 1,
      bytes_uploaded_sum: 4,
      latency_ms_sum: 20,
      latency_ms_max: 20
    )

    insert_metric!(
      bucket: "metricsts",
      filter_id: "docs",
      window_started_at: ~U[2026-06-30 02:02:00.000000Z],
      operation: "get_object",
      status_code: 200,
      request_count: 9,
      bytes_downloaded_sum: 90,
      latency_ms_sum: 90
    )

    series =
      RequestMetrics.timeseries(
        bucket: "metricsts",
        filter_id: "entire",
        minutes: 3,
        now: ~U[2026-06-30 02:03:45.000000Z]
      )

    assert series.selected == %{bucket: "metricsts", filter_id: "entire"}
    assert series.from == ~U[2026-06-30 02:01:00.000000Z]
    assert series.until == ~U[2026-06-30 02:03:00.000000Z]
    assert length(series.points) == 3

    [empty, hit, current] = series.points
    assert empty.request_count == 0
    assert current.request_count == 0

    assert hit.window_started_at == ~U[2026-06-30 02:02:00.000000Z]
    assert hit.request_count == 3
    assert hit.error_count == 1
    assert hit.status_counts["2xx"] == 2
    assert hit.status_counts["5xx"] == 1
    assert hit.status_counts["4xx"] == 0
    assert hit.bytes_uploaded_sum == 4
    assert hit.bytes_downloaded_sum == 12
    assert hit.bytes_total == 16
    assert hit.latency_ms_avg == 10.0
    assert hit.latency_ms_max == 20

    assert series.totals.request_count == 3
    assert series.totals.error_count == 1
    assert series.totals.bytes_uploaded_sum == 4
    assert series.totals.bytes_downloaded_sum == 12
    assert series.totals.latency_ms_avg == 10.0
    assert series.totals.latency_ms_max == 20
  end

  test "access point metrics filter is explicit no-match until access points exist" do
    assert {:ok, _bucket} = Buckets.create("metricsap", "arn:aws:iam:::root")

    assert :ok =
             BucketConfigs.put("metricsap", :metrics, %{
               "Configurations" => [
                 %{
                   "Id" => "ap",
                   "Filter" => %{
                     "AccessPointArn" => "arn:aws:s3:us-east-1:000000000000:accesspoint/photos"
                   }
                 }
               ]
             })

    assert :ok =
             RequestMetrics.record_event(%{
               bucket: "metricsap",
               key: "documents/a.txt",
               operation: "get_object",
               metric_family: "get",
               status_code: 200,
               status_class: "2xx",
               window_started_at: ~U[2026-06-30 01:24:00.000000Z],
               latency_ms: 1,
               bytes_uploaded: 0,
               bytes_downloaded: 5,
               tags: %{}
             })

    refute metric("metricsap", "ap", "get_object", 200)
  end

  test "records whole-bucket object list and error requests while skipping metrics control API" do
    assert create_bucket("metricsledger").status == 200
    assert put_metrics("metricsledger", "entire", @entire).status == 200
    assert Repo.aggregate(RequestMetric, :count) == 0

    assert put_object("metricsledger", "documents/a.txt", "hello").status == 200
    assert get_object("metricsledger", "documents/a.txt").status == 200
    assert head_object("metricsledger", "documents/a.txt").status == 200
    assert list_v2("metricsledger").status == 200
    assert get_object("metricsledger", "missing.txt").status == 404

    put = metric!("metricsledger", "entire", "put_object", 200)
    assert put.metric_family == "put"
    assert put.request_count == 1
    assert put.bytes_uploaded_sum == 5

    get = metric!("metricsledger", "entire", "get_object", 200)
    assert get.metric_family == "get"
    assert get.request_count == 1
    assert get.bytes_downloaded_sum == 5

    assert metric!("metricsledger", "entire", "head_object", 200).request_count == 1
    assert metric!("metricsledger", "entire", "list_objects_v2", 200).metric_family == "list"

    miss = metric!("metricsledger", "entire", "get_object", 404)
    assert miss.status_class == "4xx"
    assert miss.request_count == 1
    assert miss.bytes_downloaded_sum == 0
  end

  test "POST Object validation errors are recorded as post_object requests" do
    assert create_bucket("metricspost").status == 200
    assert put_metrics("metricspost", "entire", @entire).status == 200

    post = post_object_bad_query("metricspost")

    assert post.status == 400
    assert post.resp_body =~ "<Code>InvalidRequest</Code>"

    row = metric!("metricspost", "entire", "post_object", 400)
    assert row.status_class == "4xx"
    assert row.request_count == 1
  end

  test "POST Object downstream failures retain prepared key and tags for filtered metrics" do
    bucket = "metricsposttag"
    key = "documents/post.txt"

    assert create_bucket(bucket).status == 200
    assert put_metrics(bucket, "tagged", @tagged).status == 200

    tagging =
      ~s(<Tagging><TagSet><Tag><Key>class</Key><Value>blue</Value></Tag></TagSet></Tagging>)

    assert {:ok, form} =
             PostPolicy.build_form(
               "http://localhost:9900",
               bucket,
               key,
               %{access_key: @access_key, secret_key: @secret},
               region: "us-east-1",
               fields: [
                 {"Content-MD5", md5_b64("different bytes")},
                 {"tagging", tagging}
               ],
               success_action_status: "204"
             )

    post = post_object_form(bucket, form.fields, "real body")

    assert post.status == 400
    assert post.resp_body =~ "<Code>BadDigest</Code>"
    assert metric!("metricsposttag", "tagged", "post_object", 400).request_count == 1
  end

  test "prefix and tag filters match only authoritative single-object requests" do
    assert create_bucket("metricsfilter").status == 200
    assert put_metrics("metricsfilter", "entire", @entire).status == 200
    assert put_metrics("metricsfilter", "docs", @prefix).status == 200
    assert put_metrics("metricsfilter", "tagged", @tagged).status == 200

    assert put_object("metricsfilter", "documents/blue.txt", "blue",
             headers: [{"x-amz-tagging", "class=blue"}]
           ).status == 200

    assert put_object("metricsfilter", "other/blue.txt", "blue",
             headers: [{"x-amz-tagging", "class=blue"}]
           ).status == 200

    assert put_object("metricsfilter", "documents/red.txt", "red",
             headers: [{"x-amz-tagging", "class=red"}]
           ).status == 200

    assert list_v2("metricsfilter", %{"list-type" => "2", "prefix" => "documents/"}).status == 200

    assert metric!("metricsfilter", "entire", "put_object", 200).request_count == 3
    assert metric!("metricsfilter", "entire", "list_objects_v2", 200).request_count == 1
    assert metric!("metricsfilter", "docs", "put_object", 200).request_count == 2
    assert metric!("metricsfilter", "tagged", "put_object", 200).request_count == 1

    refute metric("metricsfilter", "docs", "list_objects_v2", 200)
    refute metric("metricsfilter", "tagged", "list_objects_v2", 200)
  end

  test "delete object uses pre-delete tags for tag-filtered metrics" do
    assert create_bucket("metricsdelete").status == 200
    assert put_metrics("metricsdelete", "tagged", @tagged).status == 200

    assert put_object("metricsdelete", "documents/delete-me.txt", "body",
             headers: [{"x-amz-tagging", "class=blue"}]
           ).status == 200

    assert delete_object("metricsdelete", "documents/delete-me.txt").status == 204

    assert metric!("metricsdelete", "tagged", "put_object", 200).request_count == 1
    assert metric!("metricsdelete", "tagged", "delete_object", 204).request_count == 1
  end

  test "multipart metrics use upload session tags instead of stale object tags" do
    bucket = "metricsmpu"

    assert create_bucket(bucket).status == 200
    assert put_metrics(bucket, "tagged", @tagged).status == 200

    assert put_object(bucket, "documents/body.bin", "old",
             headers: [{"x-amz-tagging", "class=blue"}]
           ).status == 200

    assert put_object(bucket, "documents/copy.bin", "old",
             headers: [{"x-amz-tagging", "class=blue"}]
           ).status == 200

    assert put_object(bucket, "source.bin", "copy source").status == 200
    Repo.delete_all(RequestMetric)

    red_body_upload =
      create_multipart_upload(bucket, "documents/body.bin", [{"x-amz-tagging", "class=red"}])

    assert red_body_upload.status == 200
    red_body_upload_id = upload_id(red_body_upload.resp_body)
    assert upload_part(bucket, "documents/body.bin", red_body_upload_id, "red").status == 200

    red_copy_upload =
      create_multipart_upload(bucket, "documents/copy.bin", [{"x-amz-tagging", "class=red"}])

    assert red_copy_upload.status == 200
    red_copy_upload_id = upload_id(red_copy_upload.resp_body)

    assert upload_part_copy(
             bucket,
             "documents/copy.bin",
             red_copy_upload_id,
             bucket,
             "source.bin"
           ).status ==
             200

    blue_upload =
      create_multipart_upload(bucket, "documents/blue.bin", [{"x-amz-tagging", "class=blue"}])

    assert blue_upload.status == 200
    blue_upload_id = upload_id(blue_upload.resp_body)
    assert upload_part(bucket, "documents/blue.bin", blue_upload_id, "blue").status == 200

    assert metric!("metricsmpu", "tagged", "create_multipart_upload", 200).request_count == 1
    assert metric!("metricsmpu", "tagged", "upload_part", 200).request_count == 1
    refute metric("metricsmpu", "tagged", "upload_part_copy", 200)
  end

  defp call(conn), do: Endpoint.call(conn, Endpoint.init([]))

  defp create_bucket(bucket), do: SigV4Request.signed_conn(:put, "/#{bucket}") |> call()

  defp put_metrics(bucket, id, body) do
    SigV4Request.signed_conn(:put, "/#{bucket}",
      query: %{"metrics" => "", "id" => id},
      body: body
    )
    |> call()
  end

  defp put_object(bucket, key, body, opts \\ []) do
    SigV4Request.signed_conn(:put, "/#{bucket}/#{key}",
      body: body,
      headers: Keyword.get(opts, :headers, [])
    )
    |> call()
  end

  defp get_object(bucket, key) do
    SigV4Request.signed_conn(:get, "/#{bucket}/#{key}") |> call()
  end

  defp head_object(bucket, key) do
    SigV4Request.signed_conn(:head, "/#{bucket}/#{key}") |> call()
  end

  defp delete_object(bucket, key) do
    SigV4Request.signed_conn(:delete, "/#{bucket}/#{key}") |> call()
  end

  defp post_object_bad_query(bucket) do
    boundary = "----maxio-metrics-post"
    body = "--#{boundary}--\r\n"

    SigV4Request.anon_conn(:post, "/#{bucket}",
      query: %{"unexpected" => "1"},
      body: body,
      headers: [
        {"content-type", "multipart/form-data; boundary=#{boundary}"},
        {"content-length", Integer.to_string(byte_size(body))}
      ]
    )
    |> call()
  end

  defp post_object_form(bucket, fields, file_body) do
    boundary = "----maxio-metrics-post-#{System.unique_integer([:positive])}"
    body = multipart_body(boundary, fields, file_body)

    SigV4Request.anon_conn(:post, "/#{bucket}",
      body: body,
      headers: [
        {"content-type", "multipart/form-data; boundary=#{boundary}"},
        {"content-length", Integer.to_string(byte_size(body))}
      ]
    )
    |> call()
  end

  defp multipart_body(boundary, fields, file_body) do
    fields =
      Enum.map(fields, fn {name, value} ->
        [
          "--",
          boundary,
          "\r\ncontent-disposition: form-data; name=\"",
          name,
          "\"\r\n\r\n",
          value,
          "\r\n"
        ]
      end)

    file = [
      "--",
      boundary,
      "\r\ncontent-disposition: form-data; name=\"file\"; filename=\"upload.txt\"\r\n",
      "content-type: application/octet-stream\r\n\r\n",
      file_body,
      "\r\n--",
      boundary,
      "--\r\n"
    ]

    IO.iodata_to_binary([fields, file])
  end

  defp create_multipart_upload(bucket, key, headers) do
    SigV4Request.signed_conn(:post, "/#{bucket}/#{key}",
      query: %{"uploads" => ""},
      headers: headers
    )
    |> call()
  end

  defp upload_part(bucket, key, upload_id, body) do
    SigV4Request.signed_conn(:put, "/#{bucket}/#{key}",
      query: %{"partNumber" => "1", "uploadId" => upload_id},
      body: body
    )
    |> call()
  end

  defp upload_part_copy(bucket, key, upload_id, source_bucket, source_key) do
    SigV4Request.signed_conn(:put, "/#{bucket}/#{key}",
      query: %{"partNumber" => "1", "uploadId" => upload_id},
      headers: [{"x-amz-copy-source", "/#{source_bucket}/#{source_key}"}]
    )
    |> call()
  end

  defp upload_id(xml) do
    [_, rest] = String.split(xml, "<UploadId>")
    [id, _] = String.split(rest, "</UploadId>")
    id
  end

  defp md5_b64(body), do: :crypto.hash(:md5, body) |> Base.encode64()

  defp list_v2(bucket, query \\ %{"list-type" => "2"}) do
    SigV4Request.signed_conn(:get, "/#{bucket}", query: query) |> call()
  end

  defp metric!(bucket, filter_id, operation, status_code) do
    Repo.get_by!(RequestMetric,
      bucket: bucket,
      filter_id: filter_id,
      operation: operation,
      status_code: status_code
    )
  end

  defp metric(bucket, filter_id, operation, status_code) do
    Repo.get_by(RequestMetric,
      bucket: bucket,
      filter_id: filter_id,
      operation: operation,
      status_code: status_code
    )
  end

  defp insert_metric!(attrs) do
    window = Keyword.fetch!(attrs, :window_started_at)
    request_count = Keyword.get(attrs, :request_count, 1)
    latency_ms_sum = Keyword.get(attrs, :latency_ms_sum, 0)
    latency_ms_max = Keyword.get(attrs, :latency_ms_max, latency_ms_sum)
    now = Keyword.get(attrs, :last_seen_at, window)

    Repo.insert!(%RequestMetric{
      bucket: Keyword.fetch!(attrs, :bucket),
      filter_id: Keyword.fetch!(attrs, :filter_id),
      window_started_at: window,
      operation: Keyword.get(attrs, :operation, "get_object"),
      metric_family: Keyword.get(attrs, :metric_family, "get"),
      status_code: Keyword.get(attrs, :status_code, 200),
      status_class: Keyword.get(attrs, :status_class, "2xx"),
      request_count: request_count,
      bytes_uploaded_sum: Keyword.get(attrs, :bytes_uploaded_sum, 0),
      bytes_downloaded_sum: Keyword.get(attrs, :bytes_downloaded_sum, 0),
      latency_ms_sum: latency_ms_sum,
      latency_ms_min: Keyword.get(attrs, :latency_ms_min, 0),
      latency_ms_max: latency_ms_max,
      first_seen_at: Keyword.get(attrs, :first_seen_at, window),
      last_seen_at: now
    })
  end
end
