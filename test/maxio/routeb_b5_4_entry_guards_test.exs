defmodule Maxio.RouteBB5_4EntryGuardsTest do
  @moduledoc """
  ROUTE B B5-4 —— 对象 key/versionId 入口守卫收口取证（计划 2026-06-11-routeB-phase6 §B5-4）。

    * KeyTooLongError（medium）：**原始 key**（编码前）超 1024 字节 → 400 `KeyTooLongError`
      （对齐 MinIO ErrKeyTooLongError / AWS 同 Code）；恰 1024 字节为合法 key 完整 round-trip。
      PUT/GET/HEAD/DELETE/CreateMultipartUpload 同门；与点段 key 的 `XMinioInvalidObjectName`
      分流。单一来源 = `Paths.validate_key/1`（encode_key 层折叠为 :invalid_key 仅作后端 backstop）。
    * ?versionId 守卫（安全）：客户端 versionId 曾不经校验直进 `Paths.object_rel` 盘路径
      （`../..` 路径穿越面）。单一来源 = `Maxio.Versioning.VersionId.valid?/1`（"null" 或
      26 位 Crockford base32 ULID）；GET/HEAD/DELETE/DeleteObjects/Copy 源统一入口校验，
      非法 → 400 `InvalidArgument` "Invalid version id specified"（对齐 AWS/MinIO
      ErrInvalidVersionID）。合法形状但查无此版本仍走既有 404 语义；合法 ULID/"null" 不受影响。

  `async: false`：setup 切换全局 :s3 data_dir（FS 默认后端 + :pg 默认权威，默认配置行为取证）。
  """
  use Maxio.DataCase, async: false

  import Plug.Conn

  alias Maxio.Cluster.Paths
  alias Maxio.S3.Endpoint
  alias Maxio.Test.SigV4Request
  alias Maxio.Versioning.VersionId

  defp call(conn), do: Endpoint.call(conn, Endpoint.init([]))

  defp set_versioning(bucket, status) do
    body = ~s(<VersioningConfiguration><Status>#{status}</Status></VersioningConfiguration>)

    SigV4Request.signed_conn(:put, "/#{bucket}", query: %{"versioning" => ""}, body: body)
    |> call()
  end

  setup do
    data_dir =
      Path.join(System.tmp_dir!(), "maxio_b54_guard_#{System.unique_integer([:positive])}")

    File.rm_rf(data_dir)
    File.mkdir_p!(data_dir)
    prev_s3 = Application.get_env(:maxio, :s3)
    Application.put_env(:maxio, :s3, Keyword.put(prev_s3, :data_dir, data_dir))

    on_exit(fn ->
      Application.put_env(:maxio, :s3, prev_s3)
      File.rm_rf(data_dir)
    end)

    :ok
  end

  # ── 单元面：Paths.validate_key 长度闸（对原始 key 字节计量）──

  describe "Paths.validate_key — 1024 字节长度闸（单一来源）" do
    # 多段构造恰 N 字节 key（每段 ≤255 字节，不触段长闸——段长闸单测见下个 describe）。
    defp multiseg_key_1024 do
      key =
        Enum.map_join(1..4, "/", fn _ -> String.duplicate("a", 204) end) <>
          "/" <> String.duplicate("b", 204)

      assert byte_size(key) == 1024
      key
    end

    test "恰 1024 字节 :ok；超 1024 字节 {:error, :key_too_long}（与 :invalid_key 分流）" do
      assert :ok = Paths.validate_key(multiseg_key_1024())
      assert {:error, :key_too_long} = Paths.validate_key(multiseg_key_1024() <> "/x")

      # 单段超长 key（1025×"a"）同样 :key_too_long（raw 长度闸先于段长闸命中）。
      assert {:error, :key_too_long} = Paths.validate_key(String.duplicate("a", 1025))
      # 点段 key 仍 :invalid_key（两类错误分流，handler 映射不同 Code）。
      assert {:error, :invalid_key} = Paths.validate_key("a/../b")
    end

    test "对原始 key 的 UTF-8 字节计量（非字符数）" do
      # 85 个三字节汉字 = 255 字节/段（恰 NAME_MAX）：4 段 + 分隔 = 1023 字节 → 合法。
      assert :ok =
               Paths.validate_key(Enum.map_join(1..4, "/", fn _ -> String.duplicate("汉", 85) end))

      # 342 个汉字单段 = 1026 字节 → raw 超限。
      assert {:error, :key_too_long} = Paths.validate_key(String.duplicate("汉", 342))

      # 段编码（__MXESC__ 追加）可能使盘上路径总长超 1024——总长闸只对原始 key 计量：
      # 1019 字节原始 key 即使全段是保留名（编码后膨胀）也合法（每段编码后 18B ≤ 255）。
      long_reserved = Enum.map_join(1..102, "/", fn _ -> "meta.json" end)
      assert byte_size(long_reserved) == 1019
      assert :ok = Paths.validate_key(long_reserved)
    end

    test "encode_key 对超长 key 折叠为 {:error, :invalid_key}（后端 backstop 契约不变）" do
      assert {:error, :invalid_key} = Paths.encode_key(String.duplicate("a", 1025))
      assert {:ok, _rel} = Paths.encode_key(multiseg_key_1024())
    end
  end

  # ── 单元面：盘段 255 字节硬限（MinIO checkPathLength：errFileNameTooLong → 400 KeyTooLongError）──

  describe "Paths.validate_key — 编码后单段 255 字节硬限（对齐 MinIO checkPathLength）" do
    test "单段 255 字节 :ok；256 字节 {:error, :key_too_long}（合法总长也拦）" do
      assert :ok = Paths.validate_key(String.duplicate("a", 255))
      assert {:error, :key_too_long} = Paths.validate_key(String.duplicate("a", 256))

      # 总长 ≤1024 但含超长段：同样 :key_too_long（曾 500 InternalError 并泄露盘路径）。
      assert {:error, :key_too_long} = Paths.validate_key("ok/" <> String.duplicate("a", 300))
    end

    test "段长对编码后字节计量（escape 膨胀 / __MXESC__ 追加后仍 ≤255 才放行）" do
      # ":" escape 为 "%3A"（3 字节）：85 个 ":" = 编码后 255 → :ok；86 个 = 258 → 超限。
      assert :ok = Paths.validate_key(String.duplicate(":", 85))
      assert {:error, :key_too_long} = Paths.validate_key(String.duplicate(":", 86))

      # 250×"a" + "__MXDIR__"（9B）段本身以标记结尾 → 编码追加 __MXESC__（9B）后 268 → 超限。
      assert {:error, :key_too_long} =
               Paths.validate_key(String.duplicate("a", 250) <> "__MXDIR__")
    end
  end

  # ── 单元面：VersionId.valid?（客户端 versionId 形状校验单一来源）──

  describe "VersionId.valid? — \"null\" 或 26 位 Crockford base32 ULID" do
    test "generate/0 产出与 \"null\" 合法" do
      assert VersionId.valid?(VersionId.generate())
      assert VersionId.valid?("null")
      assert VersionId.valid?(VersionId.null_sentinel())
    end

    test "空串/点段/路径段/畸形/错长度/非 Crockford 字符一律 false（绝不抛）" do
      refute VersionId.valid?("")
      refute VersionId.valid?("..")
      refute VersionId.valid?("../x")
      refute VersionId.valid?("../../etc/passwd")
      refute VersionId.valid?("not-a-valid-ulid")
      # 错长度（25/27）。
      refute VersionId.valid?(String.duplicate("0", 25))
      refute VersionId.valid?(String.duplicate("0", 27))
      # 26 位但含 Crockford 排除字符（I L O U）/ 小写 / 非 ASCII 字节。
      refute VersionId.valid?(String.duplicate("I", 26))
      refute VersionId.valid?(String.duplicate("U", 26))
      refute VersionId.valid?(String.downcase(VersionId.generate()))
      refute VersionId.valid?(:binary.copy(<<0xFF>>, 26))
      refute VersionId.valid?(nil)
    end
  end

  # ── 端点级：KeyTooLongError（FS 默认后端 + :pg 默认权威）──

  describe "KeyTooLongError — >1024B key 全入口 400；恰 1024B 完整 round-trip" do
    setup do
      assert SigV4Request.signed_conn(:put, "/rb54key") |> call() |> Map.fetch!(:status) == 200
      :ok
    end

    test "恰 1024 字节 key：PUT/GET/HEAD/DELETE 完整 round-trip" do
      # 多段构造（每段 ≤ 255 字节）：NTFS/posix 对单个路径组件有 255 字节硬限——超限段由
      # validate_key 的段长闸结构化拒绝为同 Code 400 KeyTooLongError（对齐 MinIO
      # errFileNameTooLong，端点级取证见 routeb_fidelity_fs_key_mapping_test.exs）。
      key =
        Enum.map_join(1..5, "/", fn _ -> String.duplicate("a", 200) end) <>
          "/" <> "bbbbbbbbbbbbbbbbbbb"

      assert byte_size(key) == 1024

      put = SigV4Request.signed_conn(:put, "/rb54key/#{key}", body: "exactly 1024") |> call()
      assert put.status == 200

      get = SigV4Request.signed_conn(:get, "/rb54key/#{key}") |> call()
      assert get.status == 200
      assert get.resp_body == "exactly 1024"

      head = SigV4Request.signed_conn(:head, "/rb54key/#{key}") |> call()
      assert head.status == 200

      # 自拷贝（REPLACE）：临时 key 取码点安全前缀（B5-4），近上限 key 自拷贝绝不因
      # tmp_key 超 1024 字节守卫而 500。
      self_cp =
        SigV4Request.signed_conn(:put, "/rb54key/#{key}",
          headers: [
            {"x-amz-copy-source", "/rb54key/#{key}"},
            {"x-amz-metadata-directive", "REPLACE"},
            {"content-type", "text/plain"}
          ]
        )
        |> call()

      assert self_cp.status == 200

      get2 = SigV4Request.signed_conn(:get, "/rb54key/#{key}") |> call()
      assert get2.status == 200
      assert get2.resp_body == "exactly 1024"

      del = SigV4Request.signed_conn(:delete, "/rb54key/#{key}") |> call()
      assert del.status == 204
    end

    test "1025 字节 key：PUT/GET/DELETE → 400 <Code>KeyTooLongError</Code>（绝不 500）" do
      key = String.duplicate("a", 1025)

      put = SigV4Request.signed_conn(:put, "/rb54key/#{key}", body: "too long") |> call()
      assert put.status == 400
      assert put.resp_body =~ "<Code>KeyTooLongError</Code>"
      assert put.resp_body =~ "Your key is too long"
      refute put.resp_body =~ "InternalError"

      get = SigV4Request.signed_conn(:get, "/rb54key/#{key}") |> call()
      assert get.status == 400
      assert get.resp_body =~ "<Code>KeyTooLongError</Code>"

      del = SigV4Request.signed_conn(:delete, "/rb54key/#{key}") |> call()
      assert del.status == 400
      assert del.resp_body =~ "<Code>KeyTooLongError</Code>"
    end

    test "1025 字节 key：HEAD → 400 仅状态码（HEAD 无 body）" do
      key = String.duplicate("h", 1025)
      head = SigV4Request.signed_conn(:head, "/rb54key/#{key}") |> call()
      assert head.status == 400
      assert head.resp_body == ""
    end

    test "1025 字节 key：CreateMultipartUpload → 400 KeyTooLongError 零孤儿会话（可建即可达同门）" do
      key = String.duplicate("m", 1025)

      init =
        SigV4Request.signed_conn(:post, "/rb54key/#{key}", query: %{"uploads" => ""}) |> call()

      assert init.status == 400
      assert init.resp_body =~ "<Code>KeyTooLongError</Code>"
      assert Maxio.Multipart.list_uploads("rb54key", %{}).uploads == []
    end

    test "点段 key 仍 400 XMinioInvalidObjectName（两类 Code 分流不串扰）" do
      put = SigV4Request.signed_conn(:put, "/rb54key/a/../b", body: "x") |> call()
      assert put.status == 400
      assert put.resp_body =~ "<Code>XMinioInvalidObjectName</Code>"
      refute put.resp_body =~ "KeyTooLongError"
    end
  end

  # ── 端点级：?versionId 形状守卫（GET/HEAD/DELETE/DeleteObjects/Copy 源统一）──

  describe "?versionId 守卫 — 非法形状 → 400 InvalidArgument（先于任何查找/盘路径构造）" do
    @bad_version_ids ["../x", "..", "", "not-a-valid-ulid", String.duplicate("I", 26)]

    setup do
      assert SigV4Request.signed_conn(:put, "/rb54vid") |> call() |> Map.fetch!(:status) == 200

      put = SigV4Request.signed_conn(:put, "/rb54vid/doc.txt", body: "vid guard body") |> call()
      assert put.status == 200
      :ok
    end

    test "GET ?versionId 非法 → 400 <Code>InvalidArgument</Code> \"Invalid version id specified\"" do
      for bad <- @bad_version_ids do
        get =
          SigV4Request.signed_conn(:get, "/rb54vid/doc.txt", query: %{"versionId" => bad})
          |> call()

        assert get.status == 400, "versionId #{inspect(bad)} must be rejected"
        assert get.resp_body =~ "<Code>InvalidArgument</Code>"
        assert get.resp_body =~ "Invalid version id specified"
        refute get.resp_body =~ "InternalError"
      end
    end

    test "HEAD ?versionId 非法 → 400 仅状态码（HEAD 无 body）" do
      for bad <- @bad_version_ids do
        head =
          SigV4Request.signed_conn(:head, "/rb54vid/doc.txt", query: %{"versionId" => bad})
          |> call()

        assert head.status == 400, "versionId #{inspect(bad)} must be rejected"
        assert head.resp_body == ""
      end
    end

    test "DELETE ?versionId 非法 → 400 InvalidArgument（绝不触盘路径）" do
      for bad <- @bad_version_ids do
        del =
          SigV4Request.signed_conn(:delete, "/rb54vid/doc.txt", query: %{"versionId" => bad})
          |> call()

        assert del.status == 400, "versionId #{inspect(bad)} must be rejected"
        assert del.resp_body =~ "<Code>InvalidArgument</Code>"
        assert del.resp_body =~ "Invalid version id specified"
      end

      # 守卫未破坏对象本体：原文仍可读。
      get = SigV4Request.signed_conn(:get, "/rb54vid/doc.txt") |> call()
      assert get.status == 200
      assert get.resp_body == "vid guard body"
    end

    test "Copy 源 versionId 非法 → 400 InvalidArgument（拷贝零字节写出）" do
      for bad <- ["../x", "..", "not-a-valid-ulid"] do
        cp =
          SigV4Request.signed_conn(:put, "/rb54vid/dest.txt",
            headers: [{"x-amz-copy-source", "/rb54vid/doc.txt?versionId=#{bad}"}]
          )
          |> call()

        assert cp.status == 400, "copy-source versionId #{inspect(bad)} must be rejected"
        assert cp.resp_body =~ "<Code>InvalidArgument</Code>"
        assert cp.resp_body =~ "Invalid version id specified"
      end

      # 目标未被写出。
      miss = SigV4Request.signed_conn(:get, "/rb54vid/dest.txt") |> call()
      assert miss.status == 404
    end

    test "DeleteObjects per-key VersionId 非法 → 该 key <Error>InvalidArgument</Error>，其余 key 正常删（per-key 隔离）" do
      put = SigV4Request.signed_conn(:put, "/rb54vid/ok.txt", body: "deletable") |> call()
      assert put.status == 200

      xml =
        "<Delete>" <>
          "<Object><Key>doc.txt</Key><VersionId>../x</VersionId></Object>" <>
          "<Object><Key>ok.txt</Key></Object>" <>
          "</Delete>"

      resp =
        SigV4Request.signed_conn(:post, "/rb54vid", query: %{"delete" => ""}, body: xml)
        |> call()

      assert resp.status == 200
      assert resp.resp_body =~ "<Code>InvalidArgument</Code>"
      assert resp.resp_body =~ "Invalid version id specified"
      # 同批合法 key 正常删除（per-key 失败绝不连坐）。
      assert resp.resp_body =~ "<Deleted><Key>ok.txt</Key></Deleted>"

      gone = SigV4Request.signed_conn(:get, "/rb54vid/ok.txt") |> call()
      assert gone.status == 404
      # 非法 versionId 的 key 未被删除。
      still = SigV4Request.signed_conn(:get, "/rb54vid/doc.txt") |> call()
      assert still.status == 200
    end

    test "合法 \"null\"：未版本化对象 GET/HEAD ?versionId=null → 200 不受影响" do
      get =
        SigV4Request.signed_conn(:get, "/rb54vid/doc.txt", query: %{"versionId" => "null"})
        |> call()

      assert get.status == 200
      assert get.resp_body == "vid guard body"

      head =
        SigV4Request.signed_conn(:head, "/rb54vid/doc.txt", query: %{"versionId" => "null"})
        |> call()

      assert head.status == 200
    end

    test "合法 ULID：Enabled 桶真实版本 GET 200；合法形状但查无此版本 → 既有 404 语义不变" do
      bucket = "rb54viden"
      assert SigV4Request.signed_conn(:put, "/" <> bucket) |> call() |> Map.fetch!(:status) == 200
      assert set_versioning(bucket, "Enabled").status == 200

      put = SigV4Request.signed_conn(:put, "/#{bucket}/v.txt", body: "versioned body") |> call()
      assert put.status == 200
      [vid] = get_resp_header(put, "x-amz-version-id")
      assert VersionId.valid?(vid)

      get =
        SigV4Request.signed_conn(:get, "/#{bucket}/v.txt", query: %{"versionId" => vid})
        |> call()

      assert get.status == 200
      assert get.resp_body == "versioned body"

      # 合法形状（新生成 ULID）但查无此版本 → 404（绝不 400，语义不变）。
      ghost = VersionId.generate()

      miss =
        SigV4Request.signed_conn(:get, "/#{bucket}/v.txt", query: %{"versionId" => ghost})
        |> call()

      assert miss.status == 404
      assert miss.resp_body =~ "<Code>NoSuchKey</Code>"

      # 删除真实版本（合法 ULID 经守卫放行）→ 204。
      del =
        SigV4Request.signed_conn(:delete, "/#{bucket}/v.txt", query: %{"versionId" => vid})
        |> call()

      assert del.status == 204
    end
  end
end
