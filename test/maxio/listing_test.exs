defmodule Maxio.ListingTest do
  use ExUnit.Case, async: true
  alias Maxio.Listing
  alias Maxio.Cluster.Transport.InProcess

  # 单 set N=3（K=2 M=1）InProcess topology；3 端点同写 sidecar 模拟对象
  setup do
    InProcess.setup!()

    root = fn i ->
      Path.join(System.tmp_dir!(), "lst_d#{i}_#{System.unique_integer([:positive])}")
    end

    eps = for i <- 0..2, do: {:"ln#{i}", root.(i)}

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

    {:ok, topo: topo, eps: eps}
  end

  # 在所有端点为 bucket/key 写一个对象目录（含 meta.json）
  defp put(eps, bucket, key) do
    Enum.each(eps, fn {_n, drive} ->
      dir = Path.join([drive, bucket, key])
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "meta.json"), "{}")
    end)
  end

  defp opts(topo), do: [transport: InProcess, topology: topo]

  test "列举所有对象，key 升序", %{topo: topo, eps: eps} do
    put(eps, "b", "a.txt")
    put(eps, "b", "m.txt")
    put(eps, "b", "z.txt")
    r = Listing.list_objects_v2("b", %{max_keys: 100}, opts(topo))
    assert Enum.map(r.objects, & &1.key) == ["a.txt", "m.txt", "z.txt"]
    assert r.is_truncated == false
    assert r.key_count == 3
  end

  test "prefix 过滤", %{topo: topo, eps: eps} do
    put(eps, "b", "photos/1.jpg")
    put(eps, "b", "photos/2.jpg")
    put(eps, "b", "docs/a.txt")
    r = Listing.list_objects_v2("b", %{prefix: "photos/", max_keys: 100}, opts(topo))
    assert Enum.map(r.objects, & &1.key) == ["photos/1.jpg", "photos/2.jpg"]
  end

  test "delimiter 折叠 common_prefixes", %{topo: topo, eps: eps} do
    put(eps, "b", "photos/2006/a.jpg")
    put(eps, "b", "photos/2007/b.jpg")
    put(eps, "b", "root.txt")

    r =
      Listing.list_objects_v2(
        "b",
        %{prefix: "photos/", delimiter: "/", max_keys: 100},
        opts(topo)
      )

    assert r.common_prefixes == ["photos/2006/", "photos/2007/"]
    assert r.objects == []
  end

  test "max_keys 截断 + 续点可续", %{topo: topo, eps: eps} do
    for k <- ~w(a b c d e), do: put(eps, "b", k)
    r1 = Listing.list_objects_v2("b", %{max_keys: 2}, opts(topo))
    assert Enum.map(r1.objects, & &1.key) == ["a", "b"]
    assert r1.is_truncated == true
    assert is_binary(r1.next_continuation_token)

    r2 =
      Listing.list_objects_v2(
        "b",
        %{max_keys: 2, continuation_token: r1.next_continuation_token},
        opts(topo)
      )

    assert Enum.map(r2.objects, & &1.key) == ["c", "d"]
    assert r2.is_truncated == true

    r3 =
      Listing.list_objects_v2(
        "b",
        %{max_keys: 2, continuation_token: r2.next_continuation_token},
        opts(topo)
      )

    assert Enum.map(r3.objects, & &1.key) == ["e"]
    assert r3.is_truncated == false
  end

  test "start-after", %{topo: topo, eps: eps} do
    for k <- ~w(a b c), do: put(eps, "b", k)
    r = Listing.list_objects_v2("b", %{max_keys: 100, start_after: "a"}, opts(topo))
    assert Enum.map(r.objects, & &1.key) == ["b", "c"]
  end

  test "Continuation encode/decode round-trip", %{} do
    tok = Maxio.Listing.Continuation.encode("photos/x.jpg")
    assert {:ok, "photos/x.jpg"} = Maxio.Listing.Continuation.decode(tok)
    assert :error = Maxio.Listing.Continuation.decode("!!!notbase64!!!")
  end

  # 跨 set 全端点递归走盘：两个 set 各 3 端点；对象按 key 分散到不同 set（同 key 必同 set），
  # 走盘须 fan-out 全 set 收集去重、k-way 归并按 key 升序、跨 set 不重不漏。
  test "跨 set 全端点递归走盘收集去重 + 升序归并" do
    InProcess.setup!()

    root = fn tag, i ->
      Path.join(System.tmp_dir!(), "lst_#{tag}#{i}_#{System.unique_integer([:positive])}")
    end

    eps0 = for i <- 0..2, do: {:"s0n#{i}", root.("s0", i)}
    eps1 = for i <- 0..2, do: {:"s1n#{i}", root.("s1", i)}

    topo = %{
      data_shards: 2,
      parity_shards: 1,
      block_size: 1024,
      sets: %{0 => %{id: 0, endpoints: eps0}, 1 => %{id: 1, endpoints: eps1}},
      set_ids: [0, 1]
    }

    :persistent_term.put({Maxio.Cluster.Topology, :topology}, topo)

    on_exit(fn ->
      :persistent_term.erase({Maxio.Cluster.Topology, :topology})
      Enum.each(eps0 ++ eps1, fn {_n, d} -> File.rm_rf(d) end)
    end)

    # set0 持有 a/m；set1 持有 d/z（每个对象在该 set 的 3 端点都有 sidecar）
    put(eps0, "b", "a.txt")
    put(eps0, "b", "m.txt")
    put(eps1, "b", "d.txt")
    put(eps1, "b", "z.txt")

    r = Listing.list_objects_v2("b", %{max_keys: 100}, opts(topo))
    assert Enum.map(r.objects, & &1.key) == ["a.txt", "d.txt", "m.txt", "z.txt"]
    assert r.is_truncated == false
    assert r.key_count == 4
  end
end
