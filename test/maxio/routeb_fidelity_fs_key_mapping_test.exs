defmodule Maxio.RouteBFidelityFsKeyMappingTest do
  @moduledoc """
  ROUTE B fidelity 回归 —— FS obj-dir 布局的 key→盘路径单射性与段长硬限（vs MinIO/AWS S3）。

    * Windows 禁用文件名字节（`\\ : * ? " < > |` + 控制字节）曾**裸落盘**：PUT `a:b.txt`
      在 NTFS 上被吞成流/盘符语义 → 与 PUT `b.txt` 静默别名同一盘路径 = 跨 key 字节覆写。
      MinIO 在 Windows 上 400 拒绝这些字符（cmd/object-api-utils.go
      checkObjectNameForLengthAndSlash）；AWS 接受并忠实存储。maxio 取 AWS 上界：
      `Paths.encode_segment` 字节级 `%XX` escape，任何 UTF-8 key 在任何 OS 上单射、可逆落盘。
    * 合法 ≤1024 字节 key 但单段（编码后）>255 字节（NAME_MAX/NTFS 单组件硬限）曾 500
      InternalError 且 `<Message>` 泄露服务器绝对 data_dir 路径。MinIO checkPathLength
      （cmd/xl-storage.go）在触 OS 前返回 errFileNameTooLong → 400 KeyTooLongError。
      maxio 同构：`Paths.validate_key` 段长闸（入口 400）+ ShardServer.commit 结构化
      {:error, reason}（绝不 raise 泄路径）+ dispatch 兜底不再把异常 message 发给客户端。

  `async: false`：setup 切换全局 :s3 data_dir（FS 默认后端 + :pg 默认权威）。
  """
  use Maxio.DataCase, async: false

  alias Maxio.Cluster.{Paths, ShardServer}
  alias Maxio.S3.Endpoint
  alias Maxio.Storage.FS
  alias Maxio.Test.SigV4Request

  defp call(conn), do: Endpoint.call(conn, Endpoint.init([]))

  setup do
    data_dir =
      Path.join(System.tmp_dir!(), "maxio_fid_keymap_#{System.unique_integer([:positive])}")

    File.rm_rf(data_dir)
    File.mkdir_p!(data_dir)
    prev_s3 = Application.get_env(:maxio, :s3)
    Application.put_env(:maxio, :s3, Keyword.put(prev_s3, :data_dir, data_dir))

    on_exit(fn ->
      Application.put_env(:maxio, :s3, prev_s3)
      File.rm_rf(data_dir)
    end)

    {:ok, data_dir: data_dir}
  end

  # ── 单元面：Paths 字节级 escape（单射 + 精确互逆 + 盘上无禁用字节）──

  # Windows/NTFS 禁用文件名字节 + escape 引导符 + 控制字节的代表集。
  @special_keys [
    "a:b.txt",
    "b.txt",
    "back\\slash.bin",
    "wild*card",
    "ques?tion",
    ~S(quo"te),
    "le<ss",
    "gr>eat",
    "pi|pe",
    "50%off",
    "%3A",
    "%25",
    "tab\tsep",
    "ctrl\x01byte",
    "mix:a\\b*c?d\"e<f>g|h%i",
    "seg:colon/nested\\seg",
    "汉:字.txt"
  ]

  test "round-trip：decode(encode(key)) == key（每个禁用字节 key）" do
    for key <- @special_keys do
      assert {:ok, rel} = Paths.encode_key(key)

      assert Paths.decode_key(String.split(rel, "/")) == key,
             "round-trip failed for #{inspect(key)}"
    end
  end

  test "单射：禁用字节 key 与其裸形态两两编码不同（a:b.txt 绝不与 b.txt 同路径）" do
    keys = @special_keys ++ ["ab.txt", "backslash.bin", "wildcard", "50off", "3A", "25"]

    rels =
      Enum.map(keys, fn k ->
        {:ok, rel} = Paths.encode_key(k)
        rel
      end)

    assert length(Enum.uniq(rels)) == length(rels)
  end

  test "编码输出绝不含 Windows 禁用字节/控制字节（任何 OS 上可建且无 NTFS 路径语义）" do
    forbidden = [?\\, ?:, ?*, ??, ?", ?<, ?>, ?|]

    for key <- @special_keys do
      {:ok, rel} = Paths.encode_key(key)

      for <<b <- rel>> do
        assert b > 0x1F and b not in forbidden,
               "encoded #{inspect(rel)} for key #{inspect(key)} contains forbidden byte #{b}"
      end
    end
  end

  test "具体编码形态锁定（%XX 大写十六进制；% 自身 escape 保单射）" do
    assert {:ok, "a%3Ab.txt"} = Paths.encode_key("a:b.txt")
    assert {:ok, "back%5Cslash"} = Paths.encode_key("back\\slash")
    assert {:ok, "50%25off"} = Paths.encode_key("50%off")

    # 用户 key 字面 "%3A" → "%253A"（与 "a:b.txt" 编码产物的 "%3A" 子串绝不混淆）。
    assert {:ok, "%253A"} = Paths.encode_key("%3A")
  end

  # ── 后端面：FS obj-dir 落盘单射（曾静默别名覆写）──

  test "FS：PUT a:b.txt 后 PUT b.txt 绝不共享盘上字节", %{data_dir: dir} do
    assert {:ok, _} = FS.put("aliasbkt", "a:b.txt", "null", ["COLON-A"], data_dir: dir)
    assert {:ok, _} = FS.put("aliasbkt", "b.txt", "null", ["BARE-B"], data_dir: dir)

    assert read_fs(dir, "aliasbkt", "a:b.txt") == "COLON-A"
    assert read_fs(dir, "aliasbkt", "b.txt") == "BARE-B"

    # 盘上落点是 escape 后的目录名（具体形态锁定：a%3Ab.txt 与 b.txt 是兄弟目录）。
    assert File.regular?(Path.join([dir, "aliasbkt", "a%3Ab.txt", "part.0"]))
    assert File.regular?(Path.join([dir, "aliasbkt", "b.txt", "part.0"]))

    # 删其一不伤其二。
    assert :ok = FS.delete("aliasbkt", "b.txt", "null", data_dir: dir)
    assert read_fs(dir, "aliasbkt", "a:b.txt") == "COLON-A"
  end

  test "FS：全部禁用字节 key 落盘/读回字节忠实（AWS 忠实存储语义）", %{data_dir: dir} do
    for {key, i} <- Enum.with_index(@special_keys) do
      body = "payload-#{i}"
      assert {:ok, _} = FS.put("charsbkt", key, "null", [body], data_dir: dir)
      assert read_fs(dir, "charsbkt", key) == body, "bytes diverged for key #{inspect(key)}"
    end
  end

  defp read_fs(dir, bucket, key) do
    {:ok, stream} = FS.get(bucket, key, "null", nil, data_dir: dir)
    stream |> Enum.to_list() |> IO.iodata_to_binary()
  end

  # ── 端点面：a:b.txt 与 b.txt 端到端互不串扰（审计的活体回归）──

  test "端点：PUT a:b.txt + PUT b.txt → 各自 GET 各自字节；DELETE 其一不伤其二" do
    assert SigV4Request.signed_conn(:put, "/rbfidalias") |> call() |> Map.fetch!(:status) == 200

    put1 = SigV4Request.signed_conn(:put, "/rbfidalias/a:b.txt", body: "COLON-A") |> call()
    assert put1.status == 200

    put2 = SigV4Request.signed_conn(:put, "/rbfidalias/b.txt", body: "BARE-B") |> call()
    assert put2.status == 200

    get1 = SigV4Request.signed_conn(:get, "/rbfidalias/a:b.txt") |> call()
    assert get1.status == 200
    assert get1.resp_body == "COLON-A"

    get2 = SigV4Request.signed_conn(:get, "/rbfidalias/b.txt") |> call()
    assert get2.status == 200
    assert get2.resp_body == "BARE-B"

    del = SigV4Request.signed_conn(:delete, "/rbfidalias/b.txt") |> call()
    assert del.status == 204

    survivor = SigV4Request.signed_conn(:get, "/rbfidalias/a:b.txt") |> call()
    assert survivor.status == 200
    assert survivor.resp_body == "COLON-A"
  end

  # ── 端点面：单段 >255 字节 → 400 KeyTooLongError（曾 500 + 泄露 data_dir 绝对路径）──

  test "端点：合法 ≤1024B key 但单段 >255B → 全入口 400 KeyTooLongError，绝不 500/泄路径" do
    assert SigV4Request.signed_conn(:put, "/rbfidlong") |> call() |> Map.fetch!(:status) == 200
    key = String.duplicate("a", 300)

    put = SigV4Request.signed_conn(:put, "/rbfidlong/#{key}", body: "x") |> call()
    assert put.status == 400
    assert put.resp_body =~ "<Code>KeyTooLongError</Code>"
    assert put.resp_body =~ "Your key is too long"
    refute put.resp_body =~ "InternalError"

    # 服务器盘上绝对路径绝不泄露（曾随 File.mkdir_p! 异常 message 序列化给客户端）。
    refute put.resp_body =~ "maxio_fid_keymap"
    refute put.resp_body =~ "could not make directory"

    get = SigV4Request.signed_conn(:get, "/rbfidlong/#{key}") |> call()
    assert get.status == 400
    assert get.resp_body =~ "<Code>KeyTooLongError</Code>"

    head = SigV4Request.signed_conn(:head, "/rbfidlong/#{key}") |> call()
    assert head.status == 400
    assert head.resp_body == ""

    del = SigV4Request.signed_conn(:delete, "/rbfidlong/#{key}") |> call()
    assert del.status == 400
    assert del.resp_body =~ "<Code>KeyTooLongError</Code>"

    init =
      SigV4Request.signed_conn(:post, "/rbfidlong/#{key}", query: %{"uploads" => ""}) |> call()

    assert init.status == 400
    assert init.resp_body =~ "<Code>KeyTooLongError</Code>"
    assert Maxio.Multipart.list_uploads("rbfidlong", %{}).uploads == []
  end

  test "端点：escape 膨胀后单段 >255B 同样 400 KeyTooLongError（段长对盘上字节计量）" do
    assert SigV4Request.signed_conn(:put, "/rbfidinfl") |> call() |> Map.fetch!(:status) == 200

    # 90 个 ":" → 编码后 270 字节段（>255）；原始仅 90 字节（远低于 1024 总长闸）。
    key = String.duplicate(":", 90)

    put = SigV4Request.signed_conn(:put, "/rbfidinfl/#{key}", body: "x") |> call()
    assert put.status == 400
    assert put.resp_body =~ "<Code>KeyTooLongError</Code>"
    refute put.resp_body =~ "InternalError"
  end

  # ── 原语面：ShardServer.commit 对不可建 final dir 返回结构化错误，绝不 raise ──

  test "ShardServer.commit：mkdir 失败 → {:error, reason} 结构化返回（异常 message 曾内嵌盘路径）",
       %{data_dir: dir} do
    {:ok, tmp} = ShardServer.begin_tmp(dir)
    File.write!(Path.join(tmp, "part.0"), "bytes")
    File.write!(Path.join(tmp, "meta.json"), "{}")

    # 单组件 300 字节超 NAME_MAX/NTFS 硬限：mkdir_p 必失败（Windows 报 :enoent，
    # Linux 报 :enametoolong——入口段长闸保证客户端 key 永远到不了这里，这是原语兜底）。
    final = Path.join([dir, "bkt", String.duplicate("z", 300)])
    assert {:error, reason} = ShardServer.commit(tmp, final, fsync: false)
    assert is_atom(reason)
  end
end
