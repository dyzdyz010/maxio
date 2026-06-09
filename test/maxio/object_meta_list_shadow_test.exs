defmodule Maxio.ObjectMetaListShadowTest do
  use Maxio.DataCase, async: false
  import ExUnit.CaptureLog
  alias Maxio.{ObjectMeta, Objects, Buckets}
  alias Maxio.Cluster.Transport.InProcess

  setup do
    InProcess.setup!()

    eps =
      for i <- 0..2,
          do:
            {:"lsn#{i}",
             Path.join(System.tmp_dir!(), "ls_d#{i}_#{System.unique_integer([:positive])}")}

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
      Enum.each(eps, fn {_n, d} -> File.rm_rf(d) end)
    end)

    {:ok, _} = Buckets.create("lsb", "arn:aws:iam:::root")
    {:ok, topo: topo, eps: eps}
  end

  # 在所有端点为 bucket/key 写一个对象目录（含 meta.json），模拟 drive 上确有该对象。
  defp put_drive(eps, bucket, key) do
    Enum.each(eps, fn {_n, drive} ->
      dir = Path.join([drive, bucket, key])
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "meta.json"), "{}")
    end)
  end

  test "authoritative_source(:list) 默认 :pg" do
    assert ObjectMeta.authoritative_source(:list) == :pg
  end

  test "list_shadow 返回 :ok 且不抛（PG 与 drive-walk 一致时无分歧日志）", %{topo: topo, eps: eps} do
    put_drive(eps, "lsb", "k.txt")
    {:ok, _} = Objects.put_version_with_id("lsb", "k.txt", "null", %{size: 1, etag: "\"e\""})
    pg = Objects.list_objects_v2("lsb", %{max_keys: 100})

    log =
      capture_log(fn ->
        assert :ok =
                 ObjectMeta.list_shadow("lsb", %{max_keys: 100},
                   pg: pg,
                   transport: InProcess,
                   topology: topo
                 )
      end)

    refute log =~ "divergence"
  end

  test "PG 有 key 而 drive-walk 缺 -> 记分歧日志，仍 :ok（不破坏列举）", %{topo: topo} do
    {:ok, _} = Objects.put_version_with_id("lsb", "ghost.txt", "null", %{size: 1, etag: "\"g\""})
    pg = Objects.list_objects_v2("lsb", %{max_keys: 100})

    log =
      capture_log(fn ->
        assert :ok =
                 ObjectMeta.list_shadow("lsb", %{max_keys: 100},
                   pg: pg,
                   transport: InProcess,
                   topology: topo
                 )
      end)

    assert log =~ "list divergence" or log =~ "divergence"
  end

  test "drive-walk 有 key 而 PG 缺 -> 记分歧日志，仍 :ok", %{topo: topo, eps: eps} do
    put_drive(eps, "lsb", "orphan.txt")
    pg = Objects.list_objects_v2("lsb", %{max_keys: 100})

    log =
      capture_log(fn ->
        assert :ok =
                 ObjectMeta.list_shadow("lsb", %{max_keys: 100},
                   pg: pg,
                   transport: InProcess,
                   topology: topo
                 )
      end)

    assert log =~ "divergence"
  end

  # 回归（review must-fix）：分页第 2 页 shadow 端到端零伪分歧。
  # 权威 PG 路径与 drive-walk 由同一 handler 喂同一份 client-echoed list_opts；权威发出的
  # next_continuation_token 是【裸 key】（如 "b"，objects.ex），客户端原样回传。修复前 shadow
  # 把裸 key 当 base64 解码成乱码/:error -> 回落 start_after=nil 走全桶 -> 第 2 页走盘从头列举，
  # 与 PG 第 2 页不一致 -> 每个分页请求伪报 "list divergence"。修复后续点原文直通，零分歧。
  test "多页：权威续点（裸 key）端到端续接，第 2/3 页 shadow 零伪分歧", %{topo: topo, eps: eps} do
    for k <- ~w(a b c d e) do
      put_drive(eps, "lsb", k)
      {:ok, _} = Objects.put_version_with_id("lsb", k, "null", %{size: 1, etag: "\"#{k}\""})
    end

    # 第 1 页（权威 PG）：max_keys=2，续点 = 裸 key "b"。
    pg1 = Objects.list_objects_v2("lsb", %{max_keys: 2})
    assert Enum.map(pg1.objects, & &1.key) == ["a", "b"]
    assert pg1.is_truncated == true
    assert pg1.next_continuation_token == "b"

    # 第 2 页：用权威发的裸 key 续点回传，PG 与 shadow 同喂这份 list_opts。
    page2_opts = %{max_keys: 2, continuation_token: pg1.next_continuation_token}
    pg2 = Objects.list_objects_v2("lsb", page2_opts)
    assert Enum.map(pg2.objects, & &1.key) == ["c", "d"]

    log2 =
      capture_log(fn ->
        assert :ok =
                 ObjectMeta.list_shadow("lsb", page2_opts,
                   pg: pg2,
                   transport: InProcess,
                   topology: topo
                 )
      end)

    refute log2 =~ "divergence"

    # 第 3 页（末页）续点 = "d"，同样裸 key 直通，零分歧。
    page3_opts = %{max_keys: 2, continuation_token: pg2.next_continuation_token}
    pg3 = Objects.list_objects_v2("lsb", page3_opts)
    assert Enum.map(pg3.objects, & &1.key) == ["e"]
    assert pg3.is_truncated == false

    log3 =
      capture_log(fn ->
        assert :ok =
                 ObjectMeta.list_shadow("lsb", page3_opts,
                   pg: pg3,
                   transport: InProcess,
                   topology: topo
                 )
      end)

    refute log3 =~ "divergence"
  end

  # 门控：versioned/suspended 桶上 list shadow 短路（不跑 drive-walk、不比对、不记分歧）。
  # 即使 PG 与 drive-walk 在该桶上必然不一致（纯 PG delete marker 在盘上无痕迹），也绝不记伪分歧。
  test "Enabled 桶 list shadow 门控短路：不记分歧（盘上有 key、PG 无）", %{topo: topo, eps: eps} do
    # drive 上有 key（旧版本字节残留），PG 空（当前版本是纯 PG delete marker）-> 修复前会伪报分歧。
    put_drive(eps, "lsb", "deleted.txt")

    pg = %{
      objects: [],
      common_prefixes: [],
      is_truncated: false,
      next_continuation_token: nil,
      key_count: 0
    }

    log =
      capture_log(fn ->
        assert :ok =
                 ObjectMeta.list_shadow("lsb", %{max_keys: 100},
                   pg: pg,
                   transport: InProcess,
                   topology: topo,
                   bucket_versioning: "Enabled"
                 )
      end)

    refute log =~ "divergence"
  end

  test "Suspended 桶 list shadow 同样门控短路：不记分歧", %{topo: topo, eps: eps} do
    put_drive(eps, "lsb", "stale-null.txt")

    pg = %{
      objects: [],
      common_prefixes: [],
      is_truncated: false,
      next_continuation_token: nil,
      key_count: 0
    }

    log =
      capture_log(fn ->
        assert :ok =
                 ObjectMeta.list_shadow("lsb", %{max_keys: 100},
                   pg: pg,
                   transport: InProcess,
                   topology: topo,
                   bucket_versioning: "Suspended"
                 )
      end)

    refute log =~ "divergence"
  end

  # Unversioned 桶（默认）仍跑 shadow：drive-walk 多出 key -> 记分歧（门控不误伤未版本化桶）。
  test "Unversioned 桶门控放行：drive-walk 独有 key 仍记分歧", %{topo: topo, eps: eps} do
    put_drive(eps, "lsb", "orphan.txt")
    pg = Objects.list_objects_v2("lsb", %{max_keys: 100})

    log =
      capture_log(fn ->
        assert :ok =
                 ObjectMeta.list_shadow("lsb", %{max_keys: 100},
                   pg: pg,
                   transport: InProcess,
                   topology: topo,
                   bucket_versioning: "Unversioned"
                 )
      end)

    assert log =~ "divergence"
  end

  test "list_shadow 自吞异常绝不破坏列举（坏 transport -> :ok）", %{topo: topo} do
    pg = Objects.list_objects_v2("lsb", %{max_keys: 100})

    assert :ok =
             ObjectMeta.list_shadow("lsb", %{max_keys: 100},
               pg: pg,
               transport: Maxio.Cluster.Transport.InProcess,
               topology: %{topo | sets: %{0 => %{id: 0, endpoints: :not_a_list}}}
             )
  end
end
