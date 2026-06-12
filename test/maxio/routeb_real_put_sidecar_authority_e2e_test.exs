defmodule Maxio.RouteBRealPutSidecarAuthorityE2ETest do
  @moduledoc """
  ROUTE B B4-5 —— 真实写路径产出 maxio/2 版本化 sidecar 的端到端取证。

  与 `object_meta_read_authority_test.exs`（手搓盘上 sidecar）不同：本套件**驱动真实
  `Storage.put`**（distributed 后端 + InProcess transport + 注入 3 端点 topology），证 write→
  sidecar→read/list=:sidecar 集成临门一脚已闭合：

    * Case A（Unversioned）：真实 PUT → 解码盘上 sidecar 断言 `format=="maxio/2"` + `versions[0]`
      携带 version_id="null"/content_type/etag/size/tags；`ObjectMeta.get` read=:sidecar 返回
      `%Object{}`（**而非** `{:error, :read_quorum}`，关闭根因）；`ObjectMeta.list` list=:sidecar
      该 key 出现且 ETag 非空、Size 正确。
    * Case B（Versioned/Enabled）：真实 PUT 落 `.versions/<ULID>/` → latest（无 versionId）read=:sidecar
      返回对象（证 discover_current_version + maxio/2 reconcile 共同解析当前版本，关闭 code-review
      must_fix #2）；显式 versionId GET 也返回。
    * Case C（SSE）：真实 SSE PUT（object_meta.sse 置位）→ read=:sidecar GET 视图携带 sse_envelope
      且解密成功（绝无 unwrap_dek(nil) 炸 500）。

  **严禁手搓 sidecar** —— 全部经真实写路径取证。
  """
  use Maxio.DataCase, async: false

  alias Maxio.{ObjectMeta, Sidecar, Storage}
  alias Maxio.Cluster.{Paths, Transport.InProcess}
  alias Maxio.Crypto.SSE

  @bucket "rb"

  setup do
    InProcess.setup!()

    # 切到 distributed 后端，使 Storage.put 派发到 Maxio.Storage.Distributed（铁律 2：换后端只一行）。
    prev_backend = Application.get_env(:maxio, :storage_backend)
    Application.put_env(:maxio, :storage_backend, Maxio.Storage.Distributed)

    eps =
      for i <- 0..2,
          do:
            {:"rran#{i}",
             Path.join(System.tmp_dir!(), "rra_d#{i}_#{System.unique_integer([:positive])}")}

    # K=2 M=1 N=3 → read_quorum=2、write_quorum=3（M==div(N,2) 边界 → K+1），单 set。
    topo = %{
      data_shards: 2,
      parity_shards: 1,
      block_size: 1024,
      sets: %{0 => %{id: 0, endpoints: eps}},
      set_ids: [0]
    }

    on_exit(fn ->
      if prev_backend,
        do: Application.put_env(:maxio, :storage_backend, prev_backend),
        else: Application.delete_env(:maxio, :storage_backend)

      Enum.each(eps, fn {_n, d} -> File.rm_rf(d) end)
    end)

    {:ok, eps: eps, topo: topo}
  end

  # put 路径 opts（注入 transport + topology，使 Distributed 走进程内 3 端点）。
  defp put_opts(topo), do: [transport: InProcess, topology: topo]

  # read=:sidecar 读 opts。
  defp read_opts(topo),
    do: [transport: InProcess, topology: topo, authoritative_source: [read: :sidecar]]

  # list=:sidecar 列 opts。
  defp list_opts(topo),
    do: [transport: InProcess, topology: topo, authoritative_source: [list: :sidecar]]

  # 从任一解码盘读出落盘 sidecar（真实 PUT 写出的，绝不手搓）。
  defp read_disk_sidecar(eps, key, version_id) do
    {:ok, rel} = Paths.object_rel(@bucket, key, version_id)

    Enum.find_value(eps, fn {_n, d} ->
      path = Path.join([d, rel, "meta.json"])

      case File.read(path) do
        {:ok, bin} -> Sidecar.decode!(bin)
        {:error, _} -> nil
      end
    end)
  end

  describe "Case A — Unversioned 真实 PUT → maxio/2 sidecar → read/list=:sidecar" do
    test "落盘 sidecar 是 maxio/2 且 versions[0] 携带富字段", %{eps: eps, topo: topo} do
      body = "hello sidecar authority"

      om = %{
        content_type: "text/plain",
        tags: %{"env" => "prod"},
        sse: nil,
        acl_canned: "private",
        storage_class: "STANDARD",
        user_metadata: %{"foo" => "bar"}
      }

      assert {:ok, %{size: size, etag: etag}} =
               Storage.put(@bucket, "k", "null", [body], [object_meta: om] ++ put_opts(topo))

      assert size == byte_size(body)

      meta = read_disk_sidecar(eps, "k", "null")
      assert meta["format"] == "maxio/2"
      assert [entry] = meta["versions"]
      assert entry["version_id"] == "null"
      assert entry["content_type"] == "text/plain"
      assert entry["etag"] == etag
      assert entry["size"] == byte_size(body)
      assert entry["tags"] == %{"env" => "prod"}
      assert entry["user_metadata"] == %{"foo" => "bar"}
      # 耐久核心未被污染（仍在顶层）。
      assert meta["size"] == byte_size(body)
      assert meta["etag"] == etag
      assert is_list(meta["shards"])
    end

    test "ObjectMeta.get read=:sidecar 返回 %Object{}（非 read_quorum），富字段正确", %{topo: topo} do
      body = "authority get body"

      om = %{
        content_type: "application/json",
        tags: %{"team" => "core"},
        sse: nil,
        acl_canned: "private",
        storage_class: "STANDARD",
        user_metadata: %{}
      }

      {:ok, %{etag: etag}} =
        Storage.put(@bucket, "kget", "null", [body], [object_meta: om] ++ put_opts(topo))

      obj = ObjectMeta.get(@bucket, "kget", nil, read_opts(topo))

      assert %Maxio.Objects.Object{} = obj
      assert obj.version_id == "null"
      assert obj.etag == etag
      assert obj.content_type == "application/json"
      assert obj.size == byte_size(body)
      assert obj.tags == %{"team" => "core"}
    end

    test "ObjectMeta.list list=:sidecar 该 key 出现且 ETag 非空、Size 正确", %{topo: topo} do
      body = "list authority body"

      om = %{
        content_type: "text/plain",
        tags: %{},
        sse: nil,
        acl_canned: "private",
        storage_class: "STANDARD",
        user_metadata: %{}
      }

      {:ok, %{etag: etag}} =
        Storage.put(@bucket, "klist", "null", [body], [object_meta: om] ++ put_opts(topo))

      res = ObjectMeta.list(@bucket, %{}, list_opts(topo))

      obj = Enum.find(res.objects, fn o -> o.key == "klist" end)
      assert obj != nil
      assert obj.etag == etag
      assert obj.size == byte_size(body)
    end
  end

  describe "Case B — Versioned/Enabled 真实 PUT → .versions/<ULID>/ → latest read=:sidecar" do
    test "latest（无 versionId）read=:sidecar 解析当前版本并返回对象（关闭 must_fix #2）", %{topo: topo} do
      vid = Maxio.Versioning.VersionId.generate()
      body = "versioned current body"

      om = %{
        content_type: "text/plain",
        tags: %{},
        sse: nil,
        acl_canned: "private",
        storage_class: "STANDARD",
        user_metadata: %{}
      }

      {:ok, %{etag: etag}} =
        Storage.put(@bucket, "vk", vid, [body], [object_meta: om] ++ put_opts(topo))

      # 真实落 .versions 树（绝不写 null 路径）。
      assert read_disk_sidecar([Enum.at(topo.sets[0].endpoints, 0)], "vk", "null") == nil
      vmeta = read_disk_sidecar(topo.sets[0].endpoints, "vk", vid)
      assert vmeta["format"] == "maxio/2"
      assert [%{"version_id" => ^vid}] = vmeta["versions"]

      # latest（无 versionId）→ discover_current_version + maxio/2 reconcile 解析当前版本。
      latest = ObjectMeta.get(@bucket, "vk", nil, read_opts(topo))
      assert %Maxio.Objects.Object{} = latest
      assert latest.version_id == vid
      assert latest.etag == etag
      assert latest.size == byte_size(body)

      # 显式 versionId GET 也返回。
      explicit = ObjectMeta.get(@bucket, "vk", vid, read_opts(topo))
      assert %Maxio.Objects.Object{} = explicit
      assert explicit.version_id == vid
      assert explicit.etag == etag
    end
  end

  describe "Case C — SSE 真实 PUT → read=:sidecar GET sse_envelope 携带 + 解密成功" do
    test "sidecar 携带 sse 信封，读视图携带 sse_envelope，解密无 unwrap_dek(nil) 崩", %{
      eps: eps,
      topo: topo
    } do
      plaintext = "top secret sse-s3 payload " <> String.duplicate("x", 200)

      # 真实 SSE 写路径：明文经 Crypto.SSE.wrap_stream 加密为密文帧流 + 信封（与 handler do_put 一致）。
      {cipher_stream, envelope} = SSE.wrap_stream([plaintext])
      cipher_chunks = Enum.to_list(cipher_stream)

      om = %{
        content_type: "application/octet-stream",
        tags: %{},
        sse: %{"algo" => "AES256", "envelope" => envelope},
        acl_canned: "private",
        storage_class: "STANDARD",
        user_metadata: %{}
      }

      {:ok, _} =
        Storage.put(@bucket, "ksse", "null", cipher_chunks, [object_meta: om] ++ put_opts(topo))

      # 落盘 sidecar 携带 sse.algo + sse.envelope（JSON 往返后键为字符串）。
      meta = read_disk_sidecar(eps, "ksse", "null")
      [entry] = meta["versions"]
      assert entry["sse"]["algo"] == "AES256"
      assert is_map(entry["sse"]["envelope"])

      # read=:sidecar GET 视图：sse_algorithm + sse_envelope 都携带（绝不丢信封）。
      obj = ObjectMeta.get(@bucket, "ksse", nil, read_opts(topo))
      assert %Maxio.Objects.Object{} = obj
      assert obj.sse_algorithm == "AES256"
      assert is_map(obj.sse_envelope)

      # 用读视图携带的信封解密落盘密文 → 明文逐字还原（证 unwrap_dek 拿到非 nil 信封，不炸 500）。
      # Storage.get/4 门面不透传 opts，故直接调 distributed 后端 get/5（注入 transport/topology）。
      {:ok, raw_stream} =
        Maxio.Storage.Distributed.get(@bucket, "ksse", "null", nil, put_opts(topo))

      decrypted =
        SSE.unwrap_stream(raw_stream, obj.sse_envelope) |> Enum.to_list() |> IO.iodata_to_binary()

      assert decrypted == plaintext
    end
  end
end
