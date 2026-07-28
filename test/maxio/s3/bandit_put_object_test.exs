defmodule Maxio.S3.BanditPutObjectTest do
  use Maxio.DataCase, async: false

  import Plug.Conn, only: [read_body: 1]

  alias Maxio.Test.SigV4Request

  setup do
    data_dir =
      Path.join(
        System.tmp_dir!(),
        "maxio_bandit_put_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(data_dir)
    previous_s3 = Application.get_env(:maxio, :s3, [])
    Application.put_env(:maxio, :s3, Keyword.put(previous_s3, :data_dir, data_dir))

    bandit =
      start_supervised!(
        {Bandit,
         plug: Maxio.S3.Endpoint, scheme: :http, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)

    on_exit(fn ->
      Application.put_env(:maxio, :s3, previous_s3)
      File.rm_rf(data_dir)
    end)

    {:ok, port: port}
  end

  test "ordinary signed PutObject streams through real Bandit and persists exact bytes", %{
    port: port
  } do
    bucket = "banditordinary"
    key = "boto3-like.bin"
    body = :crypto.strong_rand_bytes(256 * 1024 + 17)

    assert %{status: 200} = signed_request(port, SigV4Request.signed_conn(:put, "/#{bucket}"))

    put =
      signed_request(
        port,
        SigV4Request.signed_conn(:put, "/#{bucket}/#{key}", body: body)
      )

    assert put.status == 200
    assert Req.Response.get_header(put, "etag") == [quoted_md5(body)]

    # TODO: diagnose the independent real-socket large GET/HEAD timeout. Plug.Test
    # read coverage remains elsewhere; this regression is specifically for the
    # Bandit request-body stream-owner boundary on PutObject.
    assert %{size: size, etag: etag} = Maxio.ObjectMeta.get(bucket, key, nil, [])
    assert size == byte_size(body)
    assert etag == md5(body)
    assert stored_body(bucket, key) == body
  end

  test "signed aws-chunked PutObject streams decoded bytes through real Bandit", %{port: port} do
    bucket = "banditchunked"
    key = "chunked.bin"
    body = :crypto.strong_rand_bytes(192 * 1024 + 31)

    assert %{status: 200} = signed_request(port, SigV4Request.signed_conn(:put, "/#{bucket}"))

    put =
      signed_request(
        port,
        SigV4Request.signed_chunked_conn(:put, "/#{bucket}/#{key}", body, chunk_size: 16_391)
      )

    assert put.status == 200
    assert Req.Response.get_header(put, "etag") == [quoted_md5(body)]

    assert %{size: size, etag: etag} = Maxio.ObjectMeta.get(bucket, key, nil, [])
    assert size == byte_size(body)
    assert etag == md5(body)
    assert stored_body(bucket, key) == body
  end

  test "bad checksum never publishes staged bytes over an existing object", %{port: port} do
    bucket = "banditchecksum"
    key = "stable.bin"
    old_body = "old committed body"
    new_body = "new body with a deliberately bad checksum"

    assert %{status: 200} = signed_request(port, SigV4Request.signed_conn(:put, "/#{bucket}"))

    assert %{status: 200} =
             signed_request(
               port,
               SigV4Request.signed_conn(:put, "/#{bucket}/#{key}", body: old_body)
             )

    bad_put =
      signed_request(
        port,
        SigV4Request.signed_conn(:put, "/#{bucket}/#{key}",
          body: new_body,
          headers: [
            {"x-amz-sdk-checksum-algorithm", "SHA256"},
            {"x-amz-checksum-sha256", Base.encode64(:crypto.hash(:sha256, "not the body"))}
          ]
        )
      )

    assert bad_put.status == 400
    assert bad_put.body =~ "<Code>BadDigest</Code>"

    assert stored_body(bucket, key) == old_body
  end

  defp signed_request(port, conn) do
    {:ok, body, _conn} = read_body(conn)
    method = conn.method |> String.downcase() |> String.to_existing_atom()

    path =
      case conn.query_string do
        "" -> conn.request_path
        query -> conn.request_path <> "?" <> query
      end

    Req.request!(
      method: method,
      url: "http://127.0.0.1:#{port}" <> path,
      headers: [{"host", "localhost"} | conn.req_headers],
      body: body,
      retry: false,
      receive_timeout: 15_000
    )
  end

  defp stored_body(bucket, key) do
    {:ok, stream} = Maxio.Storage.get(bucket, key, "null", nil)
    stream |> Enum.to_list() |> IO.iodata_to_binary()
  end

  defp md5(body), do: :crypto.hash(:md5, body) |> Base.encode16(case: :lower)

  defp quoted_md5(body) do
    ~s("#{md5(body)}")
  end
end
