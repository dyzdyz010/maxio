defmodule Maxio.ObjectsLimitTest do
  @moduledoc """
  ROUTE B B1-3 SQL LIST 临时硬 LIMIT 闸回归。

  PG 权威期三处 LIST（list_objects_v2 / list_object_versions / Multipart.list_uploads）原本无界
  `Repo.all` —— 大桶 = 全表拉进内存 DoS。本单元给 SQL 加有界 `limit(min(sql_hard_limit, max_keys*4+1000))`。
  本测试临时把 `config :maxio, :listing, sql_hard_limit` 调到极小值，证明取数确实被封顶在 SQL 层
  （候选行数 <= hard_limit），而非应用层事后裁剪。

  `async: false`：临时改全局 `:maxio, :listing` app env（进程全局），不与并发 async 模块的列举共享脏读。
  """
  use Maxio.DataCase, async: false

  alias Maxio.{Buckets, Multipart, Objects}

  setup do
    {:ok, _} = Buckets.create("limit-test", "arn:aws:iam:::root")

    prev = Application.get_env(:maxio, :listing)
    on_exit(fn -> restore_listing(prev) end)
    :ok
  end

  defp restore_listing(nil), do: Application.delete_env(:maxio, :listing)
  defp restore_listing(prev), do: Application.put_env(:maxio, :listing, prev)

  defp pad(i), do: String.pad_leading(Integer.to_string(i), 4, "0")

  defp put(key),
    do: Objects.put_metadata("limit-test", key, %{size: 1, etag: "e", content_type: "text/plain"})

  test "list_objects_v2：sql_hard_limit 封顶 SQL 取数行数（< max_keys 也只取到 hard_limit）" do
    Application.put_env(:maxio, :listing, sql_hard_limit: 10)

    for i <- 1..30, do: put("obj/" <> pad(i))

    # max_keys=20 -> fetch_limit = min(10, 20*4+1000) = 10；SQL 只取 10 行，折叠后 <= 10。
    res = Objects.list_objects_v2("limit-test", %{prefix: "obj/", max_keys: 20})
    assert length(res.objects) == 10
  end

  test "list_object_versions：sql_hard_limit 封顶 SQL 取数行数" do
    Application.put_env(:maxio, :listing, sql_hard_limit: 10)

    for i <- 1..30, do: put("ver/" <> pad(i))

    res = Objects.list_object_versions("limit-test", %{prefix: "ver/", max_keys: 20})
    assert length(res.versions) == 10
  end

  test "Multipart.list_uploads：sql_hard_limit 封顶 SQL 取数行数" do
    Application.put_env(:maxio, :listing, sql_hard_limit: 10)

    for i <- 1..30, do: {:ok, _} = Multipart.initiate("limit-test", "mpu/" <> pad(i))

    res = Multipart.list_uploads("limit-test", %{prefix: "mpu/", max_uploads: 20})
    assert length(res.uploads) == 10
  end

  test "默认 sql_hard_limit 下大量行仍正确截断（行为对客户端不变）" do
    # 不改 env，用默认 100_000。300 行同 prefix，max_keys=50 -> fetch_limit=1200，足以折叠/截断。
    for i <- 1..300, do: put("big/" <> pad(i))

    res = Objects.list_objects_v2("limit-test", %{prefix: "big/", max_keys: 50})
    assert length(res.objects) == 50
    assert res.is_truncated == true
    assert res.next_continuation_token == "big/0050"
  end

  # ── 静默欠截断回归（保真）：SQL fetch_limit 在攒满 max_keys 前截断候选时，
  # 绝不能宣称 is_truncated=false（AWS/MinIO 保证：还有更多 key 时必 IsTruncated=true + 续点）。
  # 这是修复前的核心 bug：候选被 LIMIT 裁断却返回 is_truncated=false + nil token，
  # 分页客户端误以为列举完整而停止，导致整段 key 被静默吞掉（数据完整性违规）。

  test "list_objects_v2：候选被 fetch_limit 裁断且未达 max_keys → is_truncated=true + 续点（非静默 false）" do
    Application.put_env(:maxio, :listing, sql_hard_limit: 10)

    # 30 个对象，max_keys=20，fetch_limit=10 < 20。SQL 只取前 10 行（obj/0001..obj/0010），
    # 折叠后 distinct 结果=10 < 20，候选耗尽——修复前误报 is_truncated=false 吞掉 0011..0030。
    for i <- 1..30, do: put("obj/" <> pad(i))

    res = Objects.list_objects_v2("limit-test", %{prefix: "obj/", max_keys: 20})
    assert length(res.objects) == 10
    assert res.is_truncated == true
    # 续点指向最后扫描到的对象，客户端据此 o.key > token 续查剩余。
    assert res.next_continuation_token == "obj/0010"
  end

  test "list_objects_v2：delimiter 折叠吃掉大量行也不静默 false（一个公共前缀吸收任意多 key）" do
    Application.put_env(:maxio, :listing, sql_hard_limit: 20)

    # 50 个前缀，每个 10 个 key（共 500 行），delimiter="/"，max_keys=5。
    # fetch_limit=min(20, 5*4+1000)=20。SQL 只取前 20 行 = p00/* + p01/*，折叠成 2 个公共前缀，
    # 候选耗尽 distinct=2 < 5——修复前误报 is_truncated=false，客户端以为全桶仅 2 个前缀而停止。
    for p <- 0..49, i <- 0..9 do
      put("p#{pad(p)}/" <> pad(i))
    end

    res = Objects.list_objects_v2("limit-test", %{prefix: "", delimiter: "/", max_keys: 5})
    assert res.common_prefixes == ["p0000/", "p0001/"]
    assert res.is_truncated == true
    assert res.next_continuation_token == "p0001/"
  end

  test "list_object_versions：候选被裁断且未达 max_keys → is_truncated=true + 二维续点" do
    Application.put_env(:maxio, :listing, sql_hard_limit: 10)

    for i <- 1..30, do: put("ver/" <> pad(i))

    res = Objects.list_object_versions("limit-test", %{prefix: "ver/", max_keys: 20})
    assert length(res.versions) == 10
    assert res.is_truncated == true
    assert res.next_key_marker == "ver/0010"
    assert res.next_version_id_marker == "null"
  end

  test "Multipart.list_uploads：候选被裁断且未达 max → is_truncated=true + 续点" do
    Application.put_env(:maxio, :listing, sql_hard_limit: 10)

    for i <- 1..30, do: {:ok, _} = Multipart.initiate("limit-test", "mpu/" <> pad(i))

    res = Multipart.list_uploads("limit-test", %{prefix: "mpu/", max_uploads: 20})
    assert length(res.uploads) == 10
    assert res.is_truncated == true
    assert res.next_key_marker == "mpu/0010"
  end

  test "候选未达 fetch_limit（真正扫到 keyspace 末尾）→ is_truncated=false（不误报截断）" do
    Application.put_env(:maxio, :listing, sql_hard_limit: 100)

    # 只有 5 个对象，候选数 5 < fetch_limit=100，确属完整列举 → 不能误报 true。
    for i <- 1..5, do: put("done/" <> pad(i))

    res = Objects.list_objects_v2("limit-test", %{prefix: "done/", max_keys: 20})
    assert length(res.objects) == 5
    assert res.is_truncated == false
    assert res.next_continuation_token == nil
  end
end
