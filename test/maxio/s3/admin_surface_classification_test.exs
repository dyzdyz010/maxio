defmodule Maxio.S3.AdminSurfaceClassificationTest do
  use ExUnit.Case, async: true

  alias Maxio.S3.Plugs.{AccessLogDelivery, AddressStyle, RequestMetrics, SurfaceClassifier}
  alias Maxio.Test.SigV4Request

  test "path-style admin is classified as control-plane and skips both S3 observers" do
    conn =
      :get
      |> SigV4Request.anon_conn("/minio/admin/v3/info")
      |> classify_and_observe()

    assert conn.assigns.maxio_surface == :admin
    refute conn.private[:maxio_request_metrics_started_at]
    refute conn.private[:maxio_access_log_started_at]
    refute conn.private[:maxio_access_log_event_time]
  end

  test "ordinary path-style S3 requests remain observed" do
    conn =
      :get
      |> SigV4Request.anon_conn("/bucket/key")
      |> classify_and_observe()

    assert conn.assigns.maxio_surface == :s3
    assert is_integer(conn.private.maxio_request_metrics_started_at)
    assert is_integer(conn.private.maxio_access_log_started_at)
    assert %DateTime{} = conn.private.maxio_access_log_event_time
  end

  test "vhost object with the same path remains S3-observed" do
    conn =
      :get
      |> SigV4Request.anon_conn("/minio/admin/v3/info", host: "data.localhost")
      |> classify_and_observe()

    assert conn.assigns.maxio_surface == :s3
    assert is_integer(conn.private.maxio_request_metrics_started_at)
    assert is_integer(conn.private.maxio_access_log_started_at)
    assert %DateTime{} = conn.private.maxio_access_log_event_time
  end

  test "surface classifier mounted before address style fails loudly" do
    assert_raise Maxio.S3.PipelineOrderError, ~r/s3_address_style/, fn ->
      :get
      |> SigV4Request.anon_conn("/minio/admin/v3/info")
      |> SurfaceClassifier.call(SurfaceClassifier.init([]))
    end
  end

  defp classify_and_observe(conn) do
    conn
    |> AddressStyle.call(AddressStyle.init([]))
    |> SurfaceClassifier.call(SurfaceClassifier.init([]))
    |> RequestMetrics.call(RequestMetrics.init([]))
    |> AccessLogDelivery.call(AccessLogDelivery.init([]))
  end
end
