defmodule Maxio.S3.SlowDownQuorumTest do
  @moduledoc """
  ROUTE B B1-2 写路径新错误的 HTTP 状态映射保真回归（对齐 MinIO / AWS S3）。

  B1-2 让存储后端在写 quorum 不足时返回 `{:error, :write_quorum}`，FS 在原子 rename 争用
  有界重试耗尽时返回 `{:error, :rename_busy}`。这两者都是**瞬时写限流**，MinIO
  （cmd/api-errors.go: errErasureWriteQuorum -> ErrSlowDownWrite{Code:"SlowDownWrite",503}）
  映射为可重试的 503，SDK 据此指数退避自愈；绝不能退化成 500 InternalError（被多数客户端当硬失败）。

  本测试用桩后端把 PutObject / CompleteMultipartUpload 的字节写驱动成这两个错误，
  经真实端点管线断言 HTTP 503 + `<Code>SlowDownWrite</Code>`（handler 状态映射此前无覆盖）。

  `async: false`：临时改全局 `:maxio, :storage_backend` 与桩注错 app env。
  """
  use Maxio.DataCase, async: false

  import Plug.Conn
  alias Maxio.Test.SigV4Request
  alias Maxio.S3.Endpoint

  @data_dir Path.join(System.tmp_dir!(), "maxio_slowdown_test")

  # 桩后端：除 put/assemble 外全部委派给 FS（CreateBucket / Initiate 等正常工作）；
  # put 与 assemble 返回 `:maxio, :slow_down_inject` 注入的错误原子。
  defmodule FailingBackend do
    @behaviour Maxio.Storage.Backend

    defp inject, do: Application.fetch_env!(:maxio, :slow_down_inject)

    @impl true
    def put(_bucket, _key, _vid, chunks, _opts) do
      # 消费完 body（管线会先流式读 body；不消费会让上游 body reader 阻塞/报错）。
      _ = Enum.to_list(chunks)
      {:error, inject()}
    end

    @impl true
    def assemble(_bucket, _key, _upload_id, _part_numbers, _opts), do: {:error, inject()}

    @impl true
    def get(b, k, v, r), do: Maxio.Storage.FS.get(b, k, v, r)
    @impl true
    def stat(b, k, v), do: Maxio.Storage.FS.stat(b, k, v)
    @impl true
    def delete(b, k, v), do: Maxio.Storage.FS.delete(b, k, v)
    @impl true
    def put_bucket(b), do: Maxio.Storage.FS.put_bucket(b)
    @impl true
    def delete_bucket(b), do: Maxio.Storage.FS.delete_bucket(b)
    @impl true
    def put_part(b, k, u, n, c, o), do: Maxio.Storage.FS.put_part(b, k, u, n, c, o)
    @impl true
    def get_part_stream(b, k, u, n, o), do: Maxio.Storage.FS.get_part_stream(b, k, u, n, o)
    @impl true
    def abort_upload(b, k, u, o), do: Maxio.Storage.FS.abort_upload(b, k, u, o)
    @impl true
    def put_delete_marker(b, k, v, eo, o), do: Maxio.Storage.FS.put_delete_marker(b, k, v, eo, o)
  end

  setup do
    File.rm_rf(@data_dir)
    File.mkdir_p!(@data_dir)
    prev_s3 = Application.get_env(:maxio, :s3)
    Application.put_env(:maxio, :s3, Keyword.put(prev_s3, :data_dir, @data_dir))

    prev_backend = Application.get_env(:maxio, :storage_backend)

    on_exit(fn ->
      Application.put_env(:maxio, :s3, prev_s3)
      Application.put_env(:maxio, :storage_backend, prev_backend)
      Application.delete_env(:maxio, :slow_down_inject)
      File.rm_rf(@data_dir)
    end)

    :ok
  end

  defp call(conn), do: Endpoint.call(conn, Endpoint.init([]))

  defp use_failing_backend(reason) do
    Application.put_env(:maxio, :slow_down_inject, reason)
    Application.put_env(:maxio, :storage_backend, FailingBackend)
  end

  describe "PutObject 写路径错误 → 503 SlowDownWrite" do
    test "write_quorum → 503 + Code SlowDownWrite" do
      # 用真实 FS 建桶（此时还没切桩），再切桩让 put 失败。
      SigV4Request.signed_conn(:put, "/sd-bucket") |> call()
      use_failing_backend(:write_quorum)

      conn =
        SigV4Request.signed_conn(:put, "/sd-bucket/obj.txt", body: "hello")
        |> call()

      assert conn.status == 503
      assert conn.resp_body =~ "<Code>SlowDownWrite</Code>"
    end

    test "rename_busy → 503 + Code SlowDownWrite" do
      SigV4Request.signed_conn(:put, "/sd-bucket2") |> call()
      use_failing_backend(:rename_busy)

      conn =
        SigV4Request.signed_conn(:put, "/sd-bucket2/obj.txt", body: "hi")
        |> call()

      assert conn.status == 503
      assert conn.resp_body =~ "<Code>SlowDownWrite</Code>"
    end

    test "未知原因仍 500 InternalError（兜底不变）" do
      SigV4Request.signed_conn(:put, "/sd-bucket3") |> call()
      use_failing_backend(:some_unknown_reason)

      conn =
        SigV4Request.signed_conn(:put, "/sd-bucket3/obj.txt", body: "x")
        |> call()

      assert conn.status == 500
      assert conn.resp_body =~ "<Code>InternalError</Code>"
    end
  end

  describe "CompleteMultipartUpload 组装错误 → 503 SlowDownWrite" do
    test "assemble write_quorum → 503 + Code SlowDownWrite" do
      bucket = "sd-mpu"
      key = "big.bin"
      SigV4Request.signed_conn(:put, "/#{bucket}") |> call()

      # 真实 FS 发起 + 上传 1 个 part（拿到合法 ETag）。
      init =
        SigV4Request.signed_conn(:post, "/#{bucket}/#{key}", query: %{"uploads" => ""})
        |> call()

      assert init.status == 200
      [_, upload_id] = Regex.run(~r{<UploadId>([^<]+)</UploadId>}, init.resp_body)

      part_body = "abcdef"

      part =
        SigV4Request.signed_conn(:put, "/#{bucket}/#{key}",
          query: %{"partNumber" => "1", "uploadId" => upload_id},
          body: part_body
        )
        |> call()

      assert part.status == 200
      [etag] = get_resp_header(part, "etag")

      complete_xml =
        "<CompleteMultipartUpload><Part><PartNumber>1</PartNumber>" <>
          "<ETag>#{etag}</ETag></Part></CompleteMultipartUpload>"

      # 切桩让 assemble 返回 write_quorum。
      use_failing_backend(:write_quorum)

      conn =
        SigV4Request.signed_conn(:post, "/#{bucket}/#{key}",
          query: %{"uploadId" => upload_id},
          body: complete_xml,
          headers: [{"content-type", "application/xml"}]
        )
        |> call()

      assert conn.status == 503
      assert conn.resp_body =~ "<Code>SlowDownWrite</Code>"
    end
  end
end
