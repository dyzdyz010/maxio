defmodule Maxio.MetaReconcileTest do
  use ExUnit.Case, async: true
  alias Maxio.MetaReconcile

  # 构造一个带单版本的 v2 sidecar
  defp meta(vid, gen, etag) do
    entry = %{
      "version_id" => vid,
      "type" => "object",
      "is_latest" => true,
      "modtime" => 1_000 + gen,
      "generation" => gen,
      "size" => 3,
      "etag" => etag,
      "content_type" => "text/plain",
      "user_metadata" => %{},
      "tags" => %{},
      "sse" => nil,
      "acl_canned" => "private",
      "storage_class" => "STANDARD"
    }

    %{"format" => "maxio/2", "versions" => [entry]}
  end

  defp copy(i, m), do: %{node: :"n#{i}", drive: "d#{i}", meta: m}

  # 全排列（小列表用，验证结果与端点排列无关）
  defp permutations([]), do: [[]]

  defp permutations(list) do
    for h <- list, t <- permutations(list -- [h]), do: [h | t]
  end

  # N=6 K=4：read_quorum=4
  @rq 4

  test "全 6 副本一致 -> {:ok, entry, []}" do
    m = meta("v1", 1, "\"e1\"")
    copies = for i <- 1..6, do: copy(i, m)
    assert {:ok, canon, []} = MetaReconcile.reconcile(copies, @rq, :latest)
    assert canon["version_id"] == "v1"
  end

  test "4 一致 + 2 stale -> {:ok, 权威, [stale 索引]}" do
    good = meta("v1", 2, "\"e2\"")
    stale = meta("v1", 1, "\"e1\"")

    copies = [
      copy(1, good),
      copy(2, good),
      copy(3, good),
      copy(4, good),
      copy(5, stale),
      copy(6, stale)
    ]

    assert {:ok, canon, divergent} = MetaReconcile.reconcile(copies, @rq, :latest)
    assert canon["generation"] == 2
    assert Enum.sort(divergent) == [4, 5]
  end

  test "4 一致 + 1 missing + 1 corrupt -> {:ok, 权威, [missing+corrupt 索引]}" do
    good = meta("v1", 1, "\"e1\"")
    corrupt = meta("v1", 9, "\"DIFFERENT\"")

    copies = [
      copy(1, good),
      copy(2, good),
      copy(3, good),
      copy(4, good),
      :missing,
      copy(6, corrupt)
    ]

    assert {:ok, canon, divergent} = MetaReconcile.reconcile(copies, @rq, :latest)
    assert canon["etag"] == "\"e1\""
    assert Enum.sort(divergent) == [4, 5]
  end

  test "无组达 quorum（3 vs 3）-> {:error, :read_quorum}（绝不挑一个）" do
    a = meta("v1", 1, "\"a\"")
    b = meta("v1", 2, "\"b\"")
    copies = [copy(1, a), copy(2, a), copy(3, a), copy(4, b), copy(5, b), copy(6, b)]
    assert {:error, :read_quorum} = MetaReconcile.reconcile(copies, @rq, :latest)
  end

  test "全 missing -> {:error, :read_quorum}" do
    copies = List.duplicate(:missing, 6)
    assert {:error, :read_quorum} = MetaReconcile.reconcile(copies, @rq, :latest)
  end

  test "按 versionId 读：只一致那个版本，其余无此版本算 divergent" do
    e2 = %{
      "version_id" => "v2",
      "type" => "object",
      "modtime" => 5,
      "generation" => 0,
      "etag" => "\"x\"",
      "size" => 1
    }

    with_v2 = %{
      "format" => "maxio/2",
      "versions" => [hd(meta("v1", 1, "\"e1\"")["versions"]), e2]
    }

    only_v1 = meta("v1", 1, "\"e1\"")

    copies = [
      copy(1, with_v2),
      copy(2, with_v2),
      copy(3, with_v2),
      copy(4, with_v2),
      copy(5, only_v1),
      copy(6, only_v1)
    ]

    assert {:ok, canon, divergent} = MetaReconcile.reconcile(copies, @rq, {:version, "v2"})
    assert canon["version_id"] == "v2"
    assert Enum.sort(divergent) == [4, 5]
  end

  test "并列权威组（两组各达 quorum）-> 确定性选最新 modtime 组，绝不服务陈旧副本" do
    # N=4 K=2 read_quorum=2：一组 gen2/新 modtime（2 副本），另一组 gen1/旧 modtime（2 副本）。
    # 按基数两组并列；MinIO/S3 语义须按 modtime quorum 选最新者，绝不挑陈旧的 gen1。
    rq = 2
    newer = meta("v1", 2, "\"e2\"")
    older = meta("v1", 1, "\"e1\"")

    copies = [copy(1, newer), copy(2, newer), copy(3, older), copy(4, older)]

    assert {:ok, canon, divergent} = MetaReconcile.reconcile(copies, rq, :latest)
    # 必须选 gen2（更新的 modtime=1002），绝不退回 gen1（modtime=1001 陈旧）
    assert canon["generation"] == 2
    assert canon["etag"] == "\"e2\""
    # 陈旧组（gen1，端点索引 2、3）记为 divergent，供 heal 回写
    assert Enum.sort(divergent) == [2, 3]
  end

  test "并列权威组：与端点排列无关（确定性，绝不依赖 map 迭代顺序）" do
    # 对同一逻辑输入做多种 shuffle，canonical 必须恒为最新 modtime 组（gen2），结果可复现。
    rq = 2
    newer = meta("v1", 2, "\"e2\"")
    older = meta("v1", 1, "\"e1\"")

    base = [{:newer, newer}, {:newer, newer}, {:older, older}, {:older, older}]

    results =
      for perm <- permutations(base) do
        copies = Enum.with_index(perm, 1) |> Enum.map(fn {{_tag, m}, i} -> copy(i, m) end)
        {:ok, canon, _} = MetaReconcile.reconcile(copies, rq, :latest)
        {canon["generation"], canon["etag"]}
      end

    # 所有排列下 canonical 完全一致，且恒为更新的 gen2
    assert Enum.uniq(results) == [{2, "\"e2\""}]
  end

  test "更新组虽副本更少，只要达 quorum 即胜过陈旧的多数派（modtime-first）" do
    # N=5 K=2 read_quorum=2：新组 2 副本（gen2），陈旧组 3 副本（gen1）。
    # 按基数会错选陈旧 3 副本组；modtime-first 须选更新的 gen2 组（达 quorum 即可）。
    rq = 2
    newer = meta("v1", 2, "\"e2\"")
    older = meta("v1", 1, "\"e1\"")

    copies = [
      copy(1, newer),
      copy(2, newer),
      copy(3, older),
      copy(4, older),
      copy(5, older)
    ]

    assert {:ok, canon, divergent} = MetaReconcile.reconcile(copies, rq, :latest)
    assert canon["generation"] == 2
    assert Enum.sort(divergent) == [2, 3, 4]
  end

  test "latest 取 delete_marker（任意 type）" do
    # delete_marker 须是最新版本（max modtime）才是 S3 latest；obj.modtime=1001（meta gen1），故 dm 取 2000
    dm = %{"version_id" => "vdm", "type" => "delete_marker", "modtime" => 2000, "generation" => 1}
    obj = hd(meta("v1", 1, "\"e1\"")["versions"])
    m = %{"format" => "maxio/2", "versions" => [obj, dm]}
    copies = for i <- 1..5, do: copy(i, m)
    assert {:ok, canon, _} = MetaReconcile.reconcile(copies ++ [:missing], @rq, :latest)
    assert canon["type"] == "delete_marker"
  end
end
