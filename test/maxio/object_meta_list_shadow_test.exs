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
