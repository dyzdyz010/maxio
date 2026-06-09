defmodule Maxio.S3.SseSidecarReadE2ETest do
  @moduledoc """
  Review must-fix 回归（铁律 3）—— SSE-S3 对象在 **read 权威 = :sidecar** 下整链 GET 不崩。

  根因：`Maxio.ObjectMeta.view_or_not_found/4` 曾硬编码 `sse_envelope: nil`，却从
  `Sidecar.to_view/3` 透传 `sse_algorithm: "AES256"` —— sidecar 读视图对加密对象「有算法、无信封」。
  GET 走 handlers/object.ex 的 AES256 分支调 `Crypto.SSE.unwrap_stream(stream, nil)` →
  `unwrap_dek(nil)` → FunctionClauseError → 500。

  本测试用项目自己的 SSE 加密真把明文封成密文帧 + 信封，把密文写进 FS 后端（GET 读字节处），
  把携带该信封的 maxio/2 sidecar 写进拓扑各端点（read=:sidecar 的权威来源），再经完整
  SigV4 → Endpoint → handler 链发 GET，断言 200 + 透明解密还原明文 + 回显 SSE 头（端到端活体取证）。
  """
  use Maxio.DataCase, async: false
  import Plug.Conn
  alias Maxio.Test.SigV4Request
  alias Maxio.S3.Endpoint
  alias Maxio.Sidecar
  alias Maxio.Crypto.SSE
  alias Maxio.Cluster.{ShardServer, Paths}
  alias Maxio.Cluster.Transport.InProcess

  @data_dir Path.join(System.tmp_dir!(), "maxio_sse_sidecar_read")

  setup do
    InProcess.setup!()

    File.rm_rf(@data_dir)
    File.mkdir_p!(@data_dir)
    prev_s3 = Application.get_env(:maxio, :s3)
    Application.put_env(:maxio, :s3, Keyword.put(prev_s3, :data_dir, @data_dir))

    # 翻 read 权威到 :sidecar，并把分片传输设为 InProcess（合成 node atom 路由到本地 ShardServer）。
    prev_auth = Application.get_env(:maxio, :authoritative_source)
    Application.put_env(:maxio, :authoritative_source, read: :sidecar, list: :pg, write: :pg)
    prev_tx = Application.get_env(:maxio, :shard_transport)
    Application.put_env(:maxio, :shard_transport, InProcess)

    # handler 经 ObjectMeta.get 不传 topology -> read_quorum 取自全局 :erasure 配置；
    # 对齐本测试 N=3（K=2 M=1）拓扑，覆盖全局 :erasure 为 K=2 使 quorum=2（3 副本可达）。
    prev_ec = Application.get_env(:maxio, :erasure)
    Application.put_env(:maxio, :erasure, data_shards: 2, parity_shards: 1, block_size: 1024)

    # 单 set N=3（K=2 M=1）：3 端点同写 sidecar（达 read_quorum=2）。
    eps =
      for i <- 0..2,
          do:
            {:"ssen#{i}",
             Path.join(System.tmp_dir!(), "sse_d#{i}_#{System.unique_integer([:positive])}")}

    topo = %{
      data_shards: 2,
      parity_shards: 1,
      block_size: 1024,
      sets: %{0 => %{id: 0, endpoints: eps}},
      set_ids: [0]
    }

    :persistent_term.put({Maxio.Cluster.Topology, :topology}, topo)

    on_exit(fn ->
      :persistent_term.erase({Maxio.Cluster.Topology, :topology})
      Application.put_env(:maxio, :s3, prev_s3)

      if prev_auth,
        do: Application.put_env(:maxio, :authoritative_source, prev_auth),
        else: Application.delete_env(:maxio, :authoritative_source)

      if prev_tx,
        do: Application.put_env(:maxio, :shard_transport, prev_tx),
        else: Application.delete_env(:maxio, :shard_transport)

      if prev_ec,
        do: Application.put_env(:maxio, :erasure, prev_ec),
        else: Application.delete_env(:maxio, :erasure)

      Enum.each(eps, fn {_n, d} -> File.rm_rf(d) end)
      File.rm_rf(@data_dir)
    end)

    {:ok, eps: eps, topo: topo}
  end

  defp call(conn), do: Endpoint.call(conn, Endpoint.init([]))

  test "read=:sidecar 下 SSE-S3 对象 GET 透明解密（信封随 sidecar 视图携带，绝不 500）", %{
    eps: eps
  } do
    bucket = "sseb"
    key = "secret.txt"
    plain = "encrypt me under read=:sidecar with AES-256-GCM SSE-S3"

    # 建桶（ensure_bucket! 走 PG Buckets；GET 的 bucket 存在校验需要它）。
    SigV4Request.signed_conn(:put, "/" <> bucket) |> call()

    # 用项目自己的 SSE 把明文真加密成密文帧流 + 信封头。
    {cipher_stream, envelope} = SSE.wrap_stream([plain])
    ciphertext = cipher_stream |> Enum.to_list() |> IO.iodata_to_binary()

    # 密文写进 FS 后端的 null 版本路径（handler GET 经 Storage.get 在此读字节）。
    obj_path = Path.join([@data_dir, bucket, key])
    File.mkdir_p!(Path.dirname(obj_path))
    File.write!(obj_path, ciphertext)

    # 信封以 jsonb 落盘语义存（string-key；Crypto.SSE.unwrap_dek 兼容 string/atom key）。
    sse_block = %{
      "algo" => "AES256",
      "envelope" => %{
        "wrapped_dek_b64" => envelope.wrapped_dek_b64,
        "dek_iv_b64" => envelope.dek_iv_b64,
        "dek_tag_b64" => envelope.dek_tag_b64
      }
    }

    meta = %{
      "format" => "maxio/2",
      "versions" => [
        %{
          "version_id" => "null",
          "type" => "object",
          "is_latest" => true,
          "modtime" => 5,
          "generation" => 0,
          "etag" => "\"deadbeef\"",
          "size" => byte_size(plain),
          "content_type" => "text/plain",
          "sse" => sse_block
        }
      ]
    }

    # 把携带信封的 sidecar 写进各端点（null 版本路径），达 read_quorum=2。
    {:ok, rel} = Paths.object_rel(bucket, key, "null")
    Enum.each(eps, fn {_n, drive} -> ShardServer.put_sidecar(Path.join(drive, rel), meta) end)

    # 旁证：sidecar 读视图确携带信封（修复前此处 sse_envelope==nil）。
    view = Sidecar.to_view(bucket, key, hd(meta["versions"]))
    assert view.sse_algorithm == "AES256"
    assert view.sse_envelope == sse_block["envelope"]

    # 整链 GET：SigV4 → Endpoint → handler AES256 分支 → Crypto.SSE.unwrap_stream(envelope)。
    get = SigV4Request.signed_conn(:get, "/#{bucket}/#{key}") |> call()

    assert get.status == 200
    assert get.resp_body == plain
    assert get_resp_header(get, "x-amz-server-side-encryption") == ["AES256"]
  end
end
