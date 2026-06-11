defmodule Maxio.Cluster.PathsTest do
  use ExUnit.Case, async: true
  alias Maxio.Cluster.Paths

  test "null 版本对象相对路径 = bucket/key" do
    assert {:ok, "b/k"} = Paths.object_rel("b", "k", "null")
    assert {:ok, "b/a/b/c"} = Paths.object_rel("b", "a/b/c", "null")
  end

  test "版本化对象相对路径 = .versions/bucket/key/version_id" do
    assert {:ok, ".versions/b/k/01ABC"} = Paths.object_rel("b", "k", "01ABC")
  end

  test "路径穿越/空 key 拒绝" do
    assert {:error, :invalid_key} = Paths.object_rel("b", "../x", "null")
    assert {:error, :invalid_key} = Paths.object_rel("b", "a/./b", "null")
    assert {:error, :invalid_key} = Paths.object_rel("b", "", "null")
  end

  test "part / upload 相对路径" do
    assert ".uploads/b/u1/2" = Paths.part_rel("b", "u1", 2)
    assert ".uploads/b/u1" = Paths.upload_rel("b", "u1")
  end

  # ── key ↔ 盘段编码（MinIO-fidelity：保留布局名/空段/尾斜杠 key 全部合法且无碰撞落盘）──

  describe "encode_key / decode_key（单射 + 精确互逆）" do
    # 覆盖全部编码分支与刁钻形态的代表集。
    @tricky_keys [
      "plain/key.txt",
      "data/meta.json",
      "part.0",
      "a/.versions/b",
      "a/.uploads/b",
      "a/.tmp/b",
      "dir/",
      "a/b/",
      "a//b",
      "/lead",
      "a//",
      "/",
      "x__MXESC__",
      "x__MXDIR__",
      "x__MXDIR__/",
      "__MXEMPTY__",
      "__MXEMPTY__/",
      "p/part.1/x",
      "p/metadata.json"
    ]

    test "round-trip：decode(encode(key)) == key（每个刁钻 key）" do
      for key <- @tricky_keys do
        assert {:ok, rel} = Paths.encode_key(key)
        assert Paths.decode_key(String.split(rel, "/")) == key, "round-trip failed for #{key}"
      end
    end

    test "单射：刁钻 key 集两两编码不同（含 'a//b' vs 'a/b'、'dir/' vs 'dir'）" do
      keys = @tricky_keys ++ ["a/b", "dir", "x", "a"]

      rels =
        Enum.map(keys, fn k ->
          {:ok, rel} = Paths.encode_key(k)
          rel
        end)

      assert length(Enum.uniq(rels)) == length(rels)
    end

    test "编码段永不等于盘上布局名/内部目录名（结构化无碰撞，对齐 MinIO 结构避碰）" do
      for key <- @tricky_keys,
          layout <- ["meta.json", "part.0", ".versions", ".uploads", ".tmp"] do
        {:ok, rel} = Paths.encode_key(key)

        refute layout in String.split(rel, "/"),
               "key #{key} encoded to #{rel} collides with layout name #{layout}"
      end
    end

    test "具体编码形态（盘上布局可读性锁定）" do
      assert {:ok, "a/meta.json__MXESC__/b"} = Paths.encode_key("a/meta.json/b")
      assert {:ok, "a/__MXEMPTY__/b"} = Paths.encode_key("a//b")
      assert {:ok, "dir__MXDIR__"} = Paths.encode_key("dir/")
      assert {:ok, "__MXEMPTY__/lead"} = Paths.encode_key("/lead")
      # 本身以标记结尾的用户段被 escape（与真实标记不混淆）。
      assert {:ok, "x__MXDIR____MXESC__"} = Paths.encode_key("x__MXDIR__")
    end

    test "object_rel 对保留名/空段/尾斜杠 key 不再拒绝（编码落盘）" do
      assert {:ok, "b/a/meta.json__MXESC__/b"} = Paths.object_rel("b", "a/meta.json/b", "null")
      assert {:ok, "b/a/__MXEMPTY__/b"} = Paths.object_rel("b", "a//b", "null")
      assert {:ok, "b/dir__MXDIR__"} = Paths.object_rel("b", "dir/", "null")
      assert {:ok, ".versions/b/dir__MXDIR__/01ABC"} = Paths.object_rel("b", "dir/", "01ABC")
    end
  end

  describe "validate_key（API 层守卫 = 仅 S3/MinIO 都拒的形态）" do
    test "保留布局名段是普通合法 key（MinIO/AWS 均接受）" do
      for key <- ["a/meta.json/b", "part.0", ".versions/x", ".uploads/x", "a/.tmp/b"] do
        assert :ok = Paths.validate_key(key), "#{key} must be a valid key"
      end
    end

    test "空 key / 点段拒绝（MinIO hasBadPathComponent 同语义）" do
      assert {:error, :invalid_key} = Paths.validate_key("")
      assert {:error, :invalid_key} = Paths.validate_key("a/./b")
      assert {:error, :invalid_key} = Paths.validate_key("a/../b")
      assert {:error, :invalid_key} = Paths.validate_key("..")
    end

    test "空段 key（folder marker / 连续 / 前导斜杠）放行（AWS 合法，编码无碰撞落盘）" do
      for key <- ["dir/", "a//b", "/lead", "/"] do
        assert :ok = Paths.validate_key(key), "#{key} must be a valid key"
      end
    end
  end
end
