defmodule Maxio.S3.PrometheusMetricsTest do
  use Maxio.DataCase, async: false

  import Plug.Conn
  import Plug.Test

  alias Maxio.Auth.CredentialStore
  alias Maxio.Buckets
  alias Maxio.Objects
  alias Maxio.Policy.Store
  alias Maxio.S3.Endpoint
  alias Maxio.S3.PrometheusToken

  @now ~U[2026-06-30 00:00:00Z]
  @root_ak "AKIAIOSFODNN7EXAMPLE"
  @root_secret "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
  @alice_ak "AKIAPROMADMIN0001"
  @alice_secret "prometheus-secret-0001"
  @alice_arn "arn:aws:iam:::user/#{@alice_ak}"

  setup do
    prev = Application.get_env(:maxio, :prometheus_metrics)
    Application.put_env(:maxio, :prometheus_metrics, public: true)

    on_exit(fn ->
      case prev do
        nil -> Application.delete_env(:maxio, :prometheus_metrics)
        value -> Application.put_env(:maxio, :prometheus_metrics, value)
      end
    end)

    :ok
  end

  test "cluster usage objects endpoint emits MinIO-style Prometheus text when explicitly public" do
    {:ok, _bucket} = Buckets.create("metrics-prom-a", "arn:aws:iam:::root")
    {:ok, _empty} = Buckets.create("metrics-prom-empty", "arn:aws:iam:::root")

    {:ok, _v1} =
      Objects.put_version_with_id("metrics-prom-a", "a.txt", "v1", %{
        size: 5,
        etag: "etag-v1"
      })

    {:ok, _v2} =
      Objects.put_version_with_id("metrics-prom-a", "a.txt", "v2", %{
        size: 7,
        etag: "etag-v2"
      })

    {:ok, _marker} = Objects.insert_delete_marker_with_id("metrics-prom-a", "gone.txt", "dm1")

    conn = call(:get, "/minio/metrics/v3/cluster/usage/objects")

    assert conn.status == 200
    assert content_type(conn) == "text/plain; version=0.0.4; charset=utf-8"
    assert conn.resp_body =~ "# HELP minio_cluster_usage_objects_count "
    assert conn.resp_body =~ "# TYPE minio_cluster_usage_objects_count gauge"
    assert conn.resp_body =~ "minio_cluster_usage_objects_count 1\n"
    assert conn.resp_body =~ "minio_cluster_usage_objects_versions_count 3\n"
    assert conn.resp_body =~ "minio_cluster_usage_objects_delete_markers_count 1\n"
    assert conn.resp_body =~ "minio_cluster_usage_objects_buckets_count 2\n"
    assert conn.resp_body =~ "minio_cluster_usage_objects_total_bytes 12\n"
    refute conn.resp_body =~ "minio_cluster_usage_buckets_objects_count"
  end

  test "cluster usage buckets endpoint emits one family per metric with bucket labels" do
    {:ok, _bucket} = Buckets.create("metrics-prom-b", "arn:aws:iam:::root")
    {:ok, _empty} = Buckets.create("metrics-prom-empty-b", "arn:aws:iam:::root")

    {:ok, _object} =
      Objects.put_version_with_id("metrics-prom-b", "object.txt", "null", %{
        size: 9,
        etag: "etag"
      })

    conn = call(:get, "/minio/metrics/v3/cluster/usage/buckets")

    assert conn.status == 200
    assert conn.resp_body =~ "minio_cluster_usage_buckets_since_last_update_seconds 0\n"

    assert conn.resp_body =~
             ~s(minio_cluster_usage_buckets_objects_count{bucket="metrics-prom-b"} 1\n)

    assert conn.resp_body =~
             ~s(minio_cluster_usage_buckets_total_bytes{bucket="metrics-prom-b"} 9\n)

    assert conn.resp_body =~
             ~s(minio_cluster_usage_buckets_objects_count{bucket="metrics-prom-empty-b"} 0\n)

    assert conn.resp_body =~
             ~s(minio_cluster_usage_buckets_total_bytes{bucket="metrics-prom-empty-b"} 0\n)

    assert conn.resp_body |> occurrences("# HELP minio_cluster_usage_buckets_objects_count ") == 1
    refute conn.resp_body =~ "minio_cluster_usage_objects_count"
  end

  test "base v3, cluster, and legacy v2 cluster endpoints emit combined usage families" do
    {:ok, _bucket} = Buckets.create("metrics-prom-combined", "arn:aws:iam:::root")

    base_v3 = call(:get, "/minio/metrics/v3")
    v3 = call(:get, "/minio/metrics/v3/cluster")
    v2 = call(:get, "/minio/v2/metrics/cluster")

    for conn <- [base_v3, v3, v2] do
      assert conn.status == 200
      assert conn.resp_body =~ "minio_cluster_usage_objects_buckets_count 1\n"
      assert conn.resp_body =~ "minio_cluster_usage_objects_count 0\n"

      assert conn.resp_body =~
               ~s(minio_cluster_usage_buckets_objects_count{bucket="metrics-prom-combined"} 0\n)
    end
  end

  test "metrics endpoint is not public unless explicitly configured" do
    Application.put_env(:maxio, :prometheus_metrics, public: false)

    conn = call(:get, "/minio/metrics/v3/cluster/usage/objects")

    assert conn.status == 403
    assert conn.resp_body == "prometheus metrics access denied\n"
  end

  test "root bearer token authorizes admin:Prometheus scrape when endpoint is not public" do
    Application.put_env(:maxio, :prometheus_metrics, public: false)
    {:ok, _bucket} = Buckets.create("metrics-prom-root-auth", "arn:aws:iam:::root")

    conn =
      call(:get, "/minio/metrics/v3/cluster/usage/objects",
        bearer_token: token(@root_ak, @root_secret)
      )

    assert conn.status == 200
    assert conn.resp_body =~ "minio_cluster_usage_objects_buckets_count 1\n"
  end

  test "iam user bearer token requires admin:Prometheus identity policy" do
    Application.put_env(:maxio, :prometheus_metrics, public: false)
    put_alice_key()

    denied =
      call(:get, "/minio/metrics/v3/cluster/usage/objects",
        bearer_token: token(@alice_ak, @alice_secret)
      )

    assert denied.status == 403

    assert :ok =
             Store.put_principal_policy(
               @alice_arn,
               "prometheus",
               ~s({"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"admin:Prometheus"}]})
             )

    allowed =
      call(:get, "/minio/metrics/v3/cluster/usage/objects",
        bearer_token: token(@alice_ak, @alice_secret)
      )

    assert allowed.status == 200
    assert allowed.resp_body =~ "minio_cluster_usage_objects_count "
  end

  test "explicit identity deny overrides admin:Prometheus allow" do
    Application.put_env(:maxio, :prometheus_metrics, public: false)
    put_alice_key()

    assert :ok =
             Store.put_principal_policy(
               @alice_arn,
               "prometheus",
               ~s({"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"admin:Prometheus"},{"Effect":"Deny","Action":"admin:Prometheus"}]})
             )

    conn =
      call(:get, "/minio/metrics/v3/cluster/usage/objects",
        bearer_token: token(@alice_ak, @alice_secret)
      )

    assert conn.status == 403
    assert conn.resp_body == "prometheus metrics access denied\n"
  end

  test "expired, malformed, and incorrectly signed bearer tokens are rejected" do
    Application.put_env(:maxio, :prometheus_metrics, public: false)

    expired =
      token(@root_ak, @root_secret, expires_at: DateTime.add(@now, -1, :second))

    wrong_secret = token(@root_ak, "not-the-root-secret")
    wrong_issuer = token(@root_ak, @root_secret, issuer: "other")
    wrong_audience = token(@root_ak, @root_secret, audience: "other")

    alternate_access_key_claim =
      raw_token(
        %{
          "iss" => "prometheus",
          "aud" => "prometheus",
          "accessKey" => @root_ak,
          "exp" => DateTime.to_unix(DateTime.add(@now, 60, :second))
        },
        @root_secret
      )

    for bearer <- [
          expired,
          wrong_secret,
          wrong_issuer,
          wrong_audience,
          alternate_access_key_claim,
          "not-a-jwt"
        ] do
      conn = call(:get, "/minio/metrics/v3/cluster/usage/objects", bearer_token: bearer)

      assert conn.status == 403
      assert conn.resp_body == "prometheus metrics access denied\n"
    end
  end

  test "metrics endpoint supports HEAD and rejects unknown paths and methods before S3 dispatch" do
    head = call(:head, "/minio/metrics/v3/cluster/usage/objects")
    assert head.status == 200
    assert head.resp_body == ""
    assert content_type(head) =~ "text/plain"

    unknown = call(:get, "/minio/metrics/v3/not-a-family")
    assert unknown.status == 404
    assert unknown.resp_body == "metrics endpoint not found\n"

    post = call(:post, "/minio/metrics/v3/cluster/usage/objects")
    assert post.status == 405
    assert get_resp_header(post, "allow") == ["GET, HEAD"]
    assert post.resp_body == "method not allowed\n"
  end

  test "similar non-metrics paths are not intercepted by the prometheus plug" do
    conn = call(:get, "/minio/v2/metricsfoobar")

    assert conn.status == 403
    assert conn.resp_body =~ "<Code>AccessDenied</Code>"
  end

  defp call(method, path, opts \\ []) do
    method
    |> conn(path)
    |> Map.put(:host, "localhost")
    |> put_private(:maxio_now, @now)
    |> maybe_put_bearer(Keyword.get(opts, :bearer_token))
    |> Endpoint.call(Endpoint.init([]))
  end

  defp maybe_put_bearer(conn, nil), do: conn

  defp maybe_put_bearer(conn, token),
    do: put_req_header(conn, "authorization", "Bearer " <> token)

  defp put_alice_key do
    :ok =
      CredentialStore.put_access_key(%{
        access_key: @alice_ak,
        secret_key: @alice_secret,
        principal: %{type: :iam_user, access_key: @alice_ak, arn: @alice_arn}
      })
  end

  defp token(access_key, secret_key, opts \\ []) do
    PrometheusToken.generate(access_key, secret_key, Keyword.put_new(opts, :now, @now))
  end

  defp raw_token(payload, secret_key) do
    header = %{"alg" => "HS512", "typ" => "JWT"}
    signing_input = b64(Jason.encode!(header)) <> "." <> b64(Jason.encode!(payload))
    signature = :crypto.mac(:hmac, :sha512, secret_key, signing_input) |> b64()
    signing_input <> "." <> signature
  end

  defp b64(binary), do: Base.url_encode64(binary, padding: false)

  defp content_type(conn), do: conn |> get_resp_header("content-type") |> List.first()

  defp occurrences(string, pattern) do
    string
    |> String.split(pattern)
    |> length()
    |> Kernel.-(1)
  end
end
