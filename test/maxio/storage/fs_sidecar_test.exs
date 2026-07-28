defmodule Maxio.Storage.FSSidecarTest do
  @moduledoc """
  ROUTE B B6-1 —— FS obj-dir 布局 + maxio/2 sidecar + delete marker（写侧）盘上取证。

  计划 `docs/superpowers/plans/2026-06-11-routeB-phase6-fs-shared-nothing.md` B6-1 条目 5：

    * FS put → 盘上断言 obj-dir（part.0 + meta.json）+ maxio/2 sidecar versions[0] 富字段
      （content_type/tags/sse/user_metadata 来自 opts[:object_meta]，FS 不再忽略 object_meta）；
    * 旧单文件布局手工放置 → GET/HEAD/DELETE 仍工作 + `legacy_layout_read` 结构化日志（绝不静默）；
      put 覆盖旧布局 → `legacy_layout_replace` 日志 + obj-dir 落定；
    * put_delete_marker e2e：marker sidecar 落盘（quorum=1）+ Suspended null「替换」语义
      （meta_only 提交后被替换 null 版本的孤儿 part.0 被 GC）。
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Maxio.Sidecar
  alias Maxio.Storage.FS

  setup do
    dir = Path.join(System.tmp_dir!(), "maxio_fs_sidecar_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    :ok = FS.put_bucket("b", data_dir: dir)
    {:ok, dir: dir}
  end

  defp opts(dir), do: [data_dir: dir]

  defp tmp_empty?(dir) do
    tmp = Path.join(dir, ".tmp")
    not File.dir?(tmp) or File.ls!(tmp) == []
  end

  defp rich_object_meta do
    %{
      content_type: "text/plain",
      tags: %{"env" => "prod"},
      sse: %{"algo" => "AES256", "envelope" => %{"v" => 1}},
      acl_canned: "private",
      storage_class: "STANDARD",
      user_metadata: %{"foo" => "bar"}
    }
  end

  defp read_sidecar!(meta_path), do: meta_path |> File.read!() |> Sidecar.decode!()

  describe "put → obj-dir + maxio/2 sidecar（versions[0] 富字段）" do
    test "null 版本：part.0 字节 + meta.json 携 object_meta 富字段", %{dir: dir} do
      body = "fs sidecar body"

      {:ok, %{size: size, etag: etag, sha256: sha256}} =
        FS.put("b", "k.txt", "null", [body], [object_meta: rich_object_meta()] ++ opts(dir))

      obj_dir = Path.join([dir, "b", "k.txt"])
      assert File.read!(Path.join(obj_dir, "part.0")) == body

      meta = read_sidecar!(Path.join(obj_dir, "meta.json"))
      assert meta["format"] == "maxio/2"
      # v1 耐久核心保留在顶层（FS 无 ec/shards——合法）。
      assert meta["size"] == size
      assert meta["etag"] == etag
      assert meta["sha256"] == sha256

      assert [entry] = meta["versions"]
      assert entry["version_id"] == "null"
      assert entry["type"] == "object"
      assert entry["is_latest"] == true
      assert is_integer(entry["modtime"])
      assert entry["size"] == byte_size(body)
      assert entry["etag"] == etag
      # 富字段来自 object_meta（FS 从此不再忽略 object_meta，B6-1 条目 2）。
      assert entry["content_type"] == "text/plain"
      assert entry["tags"] == %{"env" => "prod"}
      assert entry["user_metadata"] == %{"foo" => "bar"}
      assert entry["sse"]["algo"] == "AES256"
      assert entry["sse"]["envelope"] == %{"v" => 1}
      assert entry["acl_canned"] == "private"
      assert entry["storage_class"] == "STANDARD"
    end

    test "版本化：obj-dir 落 .versions 路径，sidecar version_id/data_dir 对应", %{dir: dir} do
      vid = "01JXFSSIDECARTESTVERSION01"

      {:ok, _} =
        FS.put("b", "vk", vid, ["versioned"], [object_meta: rich_object_meta()] ++ opts(dir))

      obj_dir = Path.join([dir, ".versions", "b", "vk", vid])
      assert File.read!(Path.join(obj_dir, "part.0")) == "versioned"

      meta = read_sidecar!(Path.join(obj_dir, "meta.json"))
      assert meta["format"] == "maxio/2"
      assert [entry] = meta["versions"]
      assert entry["version_id"] == vid
      assert entry["data_dir"] == vid
    end
  end

  describe "旧单文件布局读回退（pre-B6-1 数据；P7 backfill 收尾）" do
    test "手工放置旧布局文件 → GET/HEAD 工作且记 legacy_layout_read 日志", %{dir: dir} do
      legacy = Path.join([dir, "b", "legacy.txt"])
      File.write!(legacy, "old single-file bytes")

      log =
        capture_log(fn ->
          assert {:ok, %{size: 21}} = FS.stat("b", "legacy.txt", "null", opts(dir))

          {:ok, stream} = FS.get("b", "legacy.txt", "null", nil, opts(dir))
          assert IO.iodata_to_binary(Enum.to_list(stream)) == "old single-file bytes"

          # Range 读同样经回退路径。
          {:ok, ranged} = FS.get("b", "legacy.txt", "null", {0, 2}, opts(dir))
          assert IO.iodata_to_binary(Enum.to_list(ranged)) == "old"
        end)

      assert log =~ "legacy single-file layout read"
    end

    test "DELETE 清理旧布局文件（幂等）", %{dir: dir} do
      legacy = Path.join([dir, "b", "legacy-del.txt"])
      File.write!(legacy, "doomed")

      assert :ok = FS.delete("b", "legacy-del.txt", "null", opts(dir))
      refute File.exists?(legacy)
      # 幂等：再删仍 :ok。
      assert :ok = FS.delete("b", "legacy-del.txt", "null", opts(dir))
      assert {:error, :enoent} = FS.get("b", "legacy-del.txt", "null", nil, opts(dir))
    end

    test "put 覆盖旧布局对象 → legacy_layout_replace 日志 + obj-dir 落定", %{dir: dir} do
      legacy = Path.join([dir, "b", "replace-me"])
      File.write!(legacy, "old bytes")

      log =
        capture_log(fn ->
          assert {:ok, _} = FS.put("b", "replace-me", "null", ["new bytes"], opts(dir))
        end)

      assert log =~ "legacy single-file layout object replaced"
      assert length(Regex.scan(~r/legacy single-file layout object replaced/, log)) == 1
      assert File.dir?(legacy)
      assert File.read!(Path.join(legacy, "part.0")) == "new bytes"
      assert File.regular?(Path.join(legacy, "meta.json"))

      {:ok, stream} = FS.get("b", "replace-me", "null", nil, opts(dir))
      assert IO.iodata_to_binary(Enum.to_list(stream)) == "new bytes"
    end

    test "put 覆盖旧布局对象 commit 失败 → 恢复旧单文件字节", %{dir: dir} do
      legacy = Path.join([dir, "b", "replace-fail"])
      File.write!(legacy, "old bytes stay")
      fail_rename = fn _src, _dst -> {:error, :erofs} end

      log =
        capture_log(fn ->
          assert {:error, :erofs} =
                   FS.put(
                     "b",
                     "replace-fail",
                     "null",
                     ["new bytes"],
                     opts(dir) ++ [rename_fun: fail_rename]
                   )
        end)

      assert log =~ "legacy single-file layout object replaced"
      assert length(Regex.scan(~r/legacy single-file layout object replaced/, log)) == 1
      assert log =~ "legacy single-file layout restored"
      assert File.regular?(legacy)
      assert File.read!(legacy) == "old bytes stay"
      assert tmp_empty?(dir)

      {:ok, stream} = FS.get("b", "replace-fail", "null", nil, opts(dir))
      assert IO.iodata_to_binary(Enum.to_list(stream)) == "old bytes stay"
    end

    test "put 新对象不误报 legacy_layout_replace 日志", %{dir: dir} do
      log =
        capture_log(fn ->
          assert {:ok, _} = FS.put("b", "brand-new", "null", ["new bytes"], opts(dir))
        end)

      refute log =~ "legacy single-file layout object replaced"
    end
  end

  describe "FS stat 错误语义（真实 IO 错误绝不折叠成 404）" do
    test "part.0 stat 真实 IO 错误经 GET/HEAD 透传并结构化记录", %{dir: dir} do
      {:ok, _} = FS.put("b", "io-fail", "null", ["bytes"], opts(dir))

      fault_opts =
        opts(dir) ++
          [
            stat_fun: fn path ->
              if Path.basename(path) == "part.0" and String.contains?(path, "io-fail") do
                {:error, :eacces}
              else
                File.stat(path)
              end
            end
          ]

      log =
        capture_log(fn ->
          assert {:error, :eacces} = FS.stat("b", "io-fail", "null", fault_opts)
          assert {:error, :eacces} = FS.get("b", "io-fail", "null", nil, fault_opts)
        end)

      assert log =~ "fs object stat failed"
      assert log =~ "io-fail"
      assert log =~ "eacces"
    end

    test "旧单文件布局回退仍限于 part.0 missing/not-directory 探测", %{dir: dir} do
      legacy = Path.join([dir, "b", "legacy-enotdir"])
      File.write!(legacy, "legacy bytes")

      fault_opts =
        opts(dir) ++
          [
            stat_fun: fn path ->
              if Path.basename(path) == "part.0" and String.contains?(path, "legacy-enotdir") do
                {:error, :enotdir}
              else
                File.stat(path)
              end
            end
          ]

      assert {:ok, %{size: 12}} = FS.stat("b", "legacy-enotdir", "null", fault_opts)
      {:ok, stream} = FS.get("b", "legacy-enotdir", "null", nil, fault_opts)
      assert IO.iodata_to_binary(Enum.to_list(stream)) == "legacy bytes"
    end

    test "legacy path 真实 stat 错误也透传并保留结构化原因映射", %{dir: dir} do
      fault_opts =
        opts(dir) ++
          [
            stat_fun: fn path ->
              cond do
                Path.basename(path) == "part.0" and String.contains?(path, "legacy-stat-fail") ->
                  {:error, :enoent}

                String.contains?(path, "legacy-stat-fail") ->
                  {:error, :enametoolong}

                true ->
                  File.stat(path)
              end
            end
          ]

      log =
        capture_log(fn ->
          assert {:error, :key_too_long} = FS.stat("b", "legacy-stat-fail", "null", fault_opts)

          assert {:error, :key_too_long} =
                   FS.get("b", "legacy-stat-fail", "null", nil, fault_opts)
        end)

      assert log =~ "legacy_stat_object"
      assert log =~ "legacy-stat-fail"
      assert log =~ "enametoolong"
    end
  end

  describe "put_delete_marker e2e（B6-1 条目 3：quorum=1 + Suspended null 替换）" do
    test "Suspended null 替换：marker sidecar 覆盖 null 版本且孤儿 part.0 被 GC", %{dir: dir} do
      {:ok, _} =
        FS.put(
          "b",
          "susp",
          "null",
          ["live bytes"],
          [object_meta: rich_object_meta()] ++ opts(dir)
        )

      obj_dir = Path.join([dir, "b", "susp"])
      assert File.regular?(Path.join(obj_dir, "part.0"))

      assert :ok = FS.put_delete_marker("b", "susp", "null", [], opts(dir))

      # marker sidecar 落盘：versions = [delete_marker]，无耐久 core。
      meta = read_sidecar!(Path.join(obj_dir, "meta.json"))
      assert meta["format"] == "maxio/2"
      assert [entry] = meta["versions"]
      assert entry["type"] == "delete_marker"
      assert entry["version_id"] == "null"
      assert entry["is_latest"] == true

      # 被替换 null 版本的孤儿 part.0 已 GC（delete marker 无字节）。
      refute File.exists?(Path.join(obj_dir, "part.0"))
      # 字节读不可达（marker obj-dir 无 part.0，也绝不回退到目录本身）。
      assert {:error, :enoent} = FS.get("b", "susp", "null", nil, opts(dir))
    end

    test "版本化 marker：sidecar 落 .versions 路径", %{dir: dir} do
      vid = "01JXFSSIDECARMARKERVERSN01"
      assert :ok = FS.put_delete_marker("b", "vmk", vid, [], opts(dir))

      meta = read_sidecar!(Path.join([dir, ".versions", "b", "vmk", vid, "meta.json"]))
      assert [entry] = meta["versions"]
      assert entry["type"] == "delete_marker"
      assert entry["version_id"] == vid
    end

    test "marker 落点被旧布局文件占据 → backup 后替换（legacy_layout_replace 日志）", %{dir: dir} do
      legacy = Path.join([dir, "b", "legacy-marker"])
      File.write!(legacy, "pre-B6-1 null bytes")

      log =
        capture_log(fn ->
          assert :ok = FS.put_delete_marker("b", "legacy-marker", "null", [], opts(dir))
        end)

      assert log =~ "legacy single-file layout object replaced"
      meta = read_sidecar!(Path.join(legacy, "meta.json"))
      assert [%{"type" => "delete_marker"}] = meta["versions"]
    end

    test "marker 覆盖旧布局对象 commit 失败 → 恢复旧单文件字节", %{dir: dir} do
      legacy = Path.join([dir, "b", "legacy-marker-fail"])
      File.write!(legacy, "old marker bytes")
      fail_rename = fn _src, _dst -> {:error, :erofs} end

      log =
        capture_log(fn ->
          assert {:error, :erofs} =
                   FS.put_delete_marker(
                     "b",
                     "legacy-marker-fail",
                     "null",
                     [],
                     opts(dir) ++ [rename_fun: fail_rename]
                   )
        end)

      assert log =~ "legacy single-file layout object replaced"
      assert log =~ "legacy single-file layout restored"
      assert File.regular?(legacy)
      assert File.read!(legacy) == "old marker bytes"
      assert tmp_empty?(dir)

      {:ok, stream} = FS.get("b", "legacy-marker-fail", "null", nil, opts(dir))
      assert IO.iodata_to_binary(Enum.to_list(stream)) == "old marker bytes"
    end
  end
end
